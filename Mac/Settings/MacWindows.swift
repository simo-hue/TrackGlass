import AppKit
import Observation
import ServiceManagement
import SwiftUI
import TrackglassKit

/// `SMAppService.mainApp`, injectable so the Welcome / Settings logic is testable without touching login items.
struct LoginItemService: Sendable {
    var status: @MainActor @Sendable () -> SMAppService.Status
    var register: @MainActor @Sendable () throws -> Void
    var unregister: @MainActor @Sendable () throws -> Void

    static let mainApp = LoginItemService(status: { SMAppService.mainApp.status },
                                          register: { try SMAppService.mainApp.register() },
                                          unregister: { try SMAppService.mainApp.unregister() })
}

enum LoginItemState: Equatable, Sendable {
    case enabled, disabled
    /// Registered, but the user has to allow it in System Settings → General → Login Items (or turned it off there).
    case requiresApproval

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        default: self = .disabled
        }
    }
}

@MainActor @Observable
final class MacSettingsModel {
    private(set) var loginState: LoginItemState
    var loginEnabled: Bool { loginState != .disabled }
    var isRecording = false
    /// One message per place it belongs to (Welcome / General, Devices, Advanced).
    var loginError: String?
    var devicesError: String?
    var advancedError: String?
    private let loginItems: LoginItemService

    init(loginItems: LoginItemService = .mainApp) {
        self.loginItems = loginItems
        loginState = LoginItemState(loginItems.status())
    }

    /// The user may change it in System Settings at any time: re-read when a window shows or the app activates.
    func refreshLoginState() { loginState = LoginItemState(loginItems.status()) }

    /// Returns whether the requested setting is now in effect; Welcome stays open when it is not.
    @discardableResult
    func setLoginEnabled(_ enabled: Bool) -> Bool {
        refreshLoginState()
        do {
            if enabled, loginState != .enabled { try loginItems.register() }
            if !enabled, loginState != .disabled { try loginItems.unregister() }
            loginError = nil
        } catch {
            loginError = (enabled ? "Could not turn on start at login: " : "Could not turn off start at login: ")
                + error.localizedDescription
        }
        refreshLoginState()
        // Waiting for approval has its own row and button; the raw error would only repeat it.
        if loginState == .requiresApproval { loginError = nil }
        return enabled ? loginState == .enabled : loginState == .disabled
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// A copy run from the disk image (or translocated by Gatekeeper) cannot start at login and is gone after eject.
    nonisolated static func isRunningFromTemporaryLocation(_ bundlePath: String = Bundle.main.bundlePath) -> Bool {
        bundlePath.hasPrefix("/Volumes/") || bundlePath.contains("/AppTranslocation/")
    }

    /// Where `ReplayRecorder` writes `.tgrec` files.
    nonisolated static func recordingsDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Trackglass/Recordings", isDirectory: true)
    }

    func revealRecordings() {
        do {
            let directory = try Self.recordingsDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
            advancedError = nil
        } catch {
            advancedError = "Cannot open the Recordings folder: \(error.localizedDescription)"
        }
    }
}

/// Device actions shared by the menu bar menu and Settings → Devices (§6.1).
@MainActor
enum DeviceActions {
    /// Asks first; returns an error message when forgetting failed, nil when done or cancelled.
    static func forget(_ peer: PairedPeer, control: ControlListener, pairing: PairingService) -> String? {
        let alert = NSAlert()
        alert.messageText = "Forget “\(peer.name)”?"
        alert.informativeText = "It will no longer be able to control this Mac until you pair it again."
        alert.addButton(withTitle: "Forget").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        do {
            try control.forget(peer.peerID)
            pairing.refreshPeers()
            return nil
        } catch {
            return "Cannot forget “\(peer.name)”: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class MacWindowCoordinator {
    let model: MacSettingsModel
    /// Opens the pairing window (set by the app, which owns it).
    var showPairing: (() -> Void)?
    private var welcome: NSWindow?
    private var settings: NSWindow?
    private let permission: AccessibilityPermission
    private let pairing: PairingService
    private let control: ControlListener
    private let input: InputListener
    private let updates: UpdateController
    private var activationObserver: NSObjectProtocol?

    init(permission: AccessibilityPermission, pairing: PairingService, control: ControlListener, input: InputListener,
         updates: UpdateController, model: MacSettingsModel = MacSettingsModel()) {
        self.permission = permission; self.pairing = pairing; self.control = control; self.input = input; self.updates = updates
        self.model = model
        // The button label follows the pipeline's real state (a session end also ends the recording).
        input.onRecordingChanged = { [weak model] recording in
            Task { @MainActor in model?.isRecording = recording }
        }
        // Back from System Settings (Login Items approval): show the setting as it is now.
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { model?.refreshLoginState() }
        }
    }

    static var welcomeCompleted: Bool { UserDefaults.standard.bool(forKey: "welcomeCompleted") }

    /// Opening the app again (Finder, Launchpad, Spotlight, a second copy): a menu-bar app has no window to bring
    /// back, so show the one that helps — Welcome until it is set up, pairing until a device is paired, else Settings.
    func showForReopen() {
        if !Self.welcomeCompleted || !permission.isTrusted {
            showWelcomeIfNeeded(force: Self.welcomeCompleted)
        } else if pairing.pairedPeers.isEmpty, let showPairing {
            showPairing()
        } else {
            showSettings()
        }
    }

    func showWelcomeIfNeeded(force: Bool = false) {
        let completed = Self.welcomeCompleted
        guard force || !completed else { return }
        model.refreshLoginState()
        // A forced re-show (Accessibility revoked) is rebuilt so its login toggle shows the current setting: only the
        // very first Welcome proposes "start at login" on; afterwards the user's own choice is kept.
        if force { welcome?.close(); welcome = nil }
        if welcome == nil {
            welcome = window(title: "Welcome to Trackglass", size: NSSize(width: 480, height: 470),
                content: WelcomeContent(permission: permission, model: model, startAtLogin: completed ? model.loginEnabled : true,
                    finish: { [weak self] pair in
                        UserDefaults.standard.set(true, forKey: "welcomeCompleted")
                        self?.welcome?.close()
                        if pair { self?.showPairing?() }
                    }))
        }
        show(welcome)
    }

    func showSettings() {
        if settings == nil {
            settings = window(title: "Trackglass Settings", size: NSSize(width: 560, height: 440),
                content: MacSettingsContent(model: model, pairing: pairing, control: control, updates: updates,
                    toggleRecording: { [weak self] in self?.toggleRecording() }))
        }
        model.refreshLoginState()
        pairing.refreshPeers(); show(settings)
    }

    func toggleRecording() {
        if model.isRecording { input.stopRecording() } else { input.startRecording() }
    }

    private func window<V: View>(title: String, size: NSSize, content: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentViewController = NSHostingController(rootView: content)
        window.center(); return window
    }

    private func show(_ window: NSWindow?) {
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

private struct WelcomeContent: View {
    @Bindable var permission: AccessibilityPermission
    @Bindable var model: MacSettingsModel
    let finish: (_ pair: Bool) -> Void
    @State private var startAtLogin: Bool
    /// "Get started" could not make the login setting stick: Welcome stays open and says what to do.
    @State private var loginProblem = false
    private let temporaryLocation = MacSettingsModel.isRunningFromTemporaryLocation()

    init(permission: AccessibilityPermission, model: MacSettingsModel, startAtLogin: Bool, finish: @escaping (_ pair: Bool) -> Void) {
        _permission = Bindable(permission); _model = Bindable(model); self.finish = finish
        _startAtLogin = State(initialValue: startAtLogin)
    }

    private var showsLoginProblem: Bool { loginProblem && startAtLogin && model.loginState != .enabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Trackglass").font(.largeTitle.bold())
            Text("Use your iPhone or iPad to control this Mac. First, allow Accessibility so Trackglass can move the pointer and perform gestures.")
                .fixedSize(horizontal: false, vertical: true)
            Label(permission.isTrusted ? "Accessibility is allowed" : "Accessibility is required", systemImage: permission.isTrusted ? "checkmark.circle.fill" : "hand.raised")
            if !permission.isTrusted { Button("Open System Settings", action: permission.openSystemSettings) }
            if LocalNetworkPermission.shared.isDenied {
                Label("Local Network access is off, so your phone cannot find this Mac.", systemImage: "network.slash")
                Button("Open Local Network Settings") { LocalNetworkPermission.shared.openSystemSettings() }
            }
            if temporaryLocation {
                Label("Move Trackglass for Mac to Applications. Run from the disk image it cannot start at login and stops working once the image is ejected.",
                      systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Applications Folder") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true)) }
            }
            Toggle("Start Trackglass at login", isOn: $startAtLogin)
            if showsLoginProblem {
                Text(model.loginError ?? "Allow Trackglass for Mac in System Settings → General → Login Items.")
                    .foregroundStyle(model.loginError == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Login Items") { model.openLoginItemsSettings() }
            }
            Text("Trackglass lives in the menu bar. Open it there to pair a device, change settings or quit.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Button("Pair a device…") { complete(pair: true) }
                    .disabled(!permission.isTrusted)
                Spacer()
                Button(showsLoginProblem ? "Continue" : "Get started") { complete(pair: false) }
                    .buttonStyle(.borderedProminent).disabled(!permission.isTrusted)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 480, height: 470, alignment: .topLeading)
    }

    private func complete(pair: Bool) {
        // Second press after a problem was shown: the user chose to go on without it.
        let wanted: LoginItemState = startAtLogin ? .enabled : .disabled
        if !showsLoginProblem, model.loginState != wanted {
            if !model.setLoginEnabled(startAtLogin) && startAtLogin {
                loginProblem = true
                return
            }
        }
        finish(pair)
    }
}

private struct MacSettingsContent: View {
    @Bindable var model: MacSettingsModel
    @Bindable var pairing: PairingService
    @Bindable var control: ControlListener
    @Bindable var updates: UpdateController
    let toggleRecording: () -> Void
    private var website: URL? { (Bundle.main.object(forInfoDictionaryKey: "TGWebsiteURL") as? String).flatMap(URL.init(string:)) }
    private static func milliseconds(_ micros: UInt32) -> String { String(format: "%.2f ms", Double(micros) / 1_000) }
    var body: some View {
        TabView {
            Form {
                Toggle("Start at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) }))
                if model.loginState == .requiresApproval {
                    HStack {
                        Text("Waiting for your approval in System Settings → General → Login Items.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open Login Items") { model.openLoginItemsSettings() }
                    }
                }
                if let error = model.loginError { Text(error).foregroundStyle(.red) }
                LabeledContent("Mac tracking speed", value: String(format: "%.2f", control.currentTrackingSpeed))
                LabeledContent("Phone tracking offset", value: String(format: "%+.2f", control.trackingOverride))
                Text("Tracking speed follows System Settings. Adjust the phone’s Feel settings for an offset.").font(.caption).foregroundStyle(.secondary)
                Toggle("Check for updates automatically", isOn: $updates.automaticallyChecksForUpdates)
                HStack {
                    Button("Check for Updates…") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                    if let lastCheck = updates.lastCheck {
                        Text("Last checked \(lastCheck.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding().tabItem { Label("General", systemImage: "gear") }
            List {
                if pairing.pairedPeers.isEmpty { Text("No paired devices") }
                ForEach(pairing.pairedPeers, id: \.peerID) { peer in
                    HStack {
                        Text(peer.name)
                        if control.connectedPeerID == peer.peerID {
                            Text("Connected").font(.caption).foregroundStyle(.green)
                        }
                        Spacer()
                        if control.connectedPeerID == peer.peerID {
                            Button("Disconnect") { control.disconnect(peerID: peer.peerID) }
                        }
                        Button("Forget…", role: .destructive) {
                            model.devicesError = DeviceActions.forget(peer, control: control, pairing: pairing)
                        }
                    }
                }
                if let error = model.devicesError { Text(error).foregroundStyle(.red) }
            }.tabItem { Label("Devices", systemImage: "iphone") }
            Form {
                HStack {
                    Button(model.isRecording ? "Stop recording" : "Record session", action: toggleRecording)
                        .disabled(!model.isRecording && control.connectedPeerID == nil)
                    Button("Show in Finder") { model.revealRecordings() }
                }
                Text(control.connectedPeerID == nil && !model.isRecording
                     ? "Connect a phone to record a session. Recordings are saved in Application Support/Trackglass/Recordings."
                     : "Recordings are saved in Application Support/Trackglass/Recordings.").font(.caption)
                if let error = model.advancedError { Text(error).foregroundStyle(.red) }
                Section("Pipeline timing") {
                    if let status = control.lastStatus {
                        LabeledContent("Pipeline p50", value: Self.milliseconds(status.pipelineP50Micros))
                        LabeledContent("Pipeline p95", value: Self.milliseconds(status.pipelineP95Micros))
                        LabeledContent("Round trip", value: Self.milliseconds(status.rttMicros))
                        LabeledContent("Frames per second", value: "\(status.framesPerSecond)")
                        LabeledContent("Loss", value: "\(status.lossPermille) ‰")
                    } else {
                        Text("Connect a phone to see receive-to-post timing.").foregroundStyle(.secondary)
                    }
                }
                Section("Reduced gesture mode") {
                    ForEach(QuartzInjector.degradedGestures(), id: \.self) { Text($0) }
                }
            }.padding().tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            VStack(spacing: 16) {
                Text("Trackglass").font(.largeTitle)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                Text("Trackglass never leaves your network")
                if let website { Link("Website", destination: website); Link("Privacy Policy", destination: website.appendingPathComponent("privacy.html")) }
            }.tabItem { Label("About", systemImage: "info.circle") }
        }.padding(16).frame(width: 560, height: 440)
    }
}
