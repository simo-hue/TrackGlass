import AppKit
import Observation
import ServiceManagement
import SwiftUI

@MainActor @Observable
final class MacSettingsModel {
    var loginEnabled = SMAppService.mainApp.status == .enabled
    var isRecording = false
    var error: String?
    @discardableResult
    func setLoginEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            let status = SMAppService.mainApp.status
            loginEnabled = status == .enabled
            // `.requiresApproval` is informational (e.g. a build outside /Applications); it is not a gate.
            error = enabled && status == .requiresApproval ? "Allow Trackglass in System Settings → General → Login Items." : nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

@MainActor
final class MacWindowCoordinator {
    let model = MacSettingsModel()
    private var welcome: NSWindow?
    private var settings: NSWindow?
    private let permission: AccessibilityPermission
    private let pairing: PairingService
    private let control: ControlListener
    private let input: InputListener
    private let updates: UpdateController
    init(permission: AccessibilityPermission, pairing: PairingService, control: ControlListener, input: InputListener, updates: UpdateController) {
        self.permission = permission; self.pairing = pairing; self.control = control; self.input = input; self.updates = updates
        // The button label follows the pipeline's real state (a session end also ends the recording).
        input.onRecordingChanged = { [weak model] recording in
            Task { @MainActor in model?.isRecording = recording }
        }
    }
    func showWelcomeIfNeeded(force: Bool = false) {
        let completed = UserDefaults.standard.bool(forKey: "welcomeCompleted")
        guard force || !completed else { return }
        // A forced re-show (Accessibility revoked) is rebuilt so its login toggle shows the current setting: only the
        // very first Welcome proposes "start at login" on; afterwards the user's own choice is kept.
        if force { welcome?.close(); welcome = nil }
        if welcome == nil {
            welcome = window(title: "Welcome to Trackglass", size: NSSize(width: 480, height: 380),
                content: WelcomeContent(permission: permission, model: model, startAtLogin: completed ? model.loginEnabled : true) { [weak self] in
                    UserDefaults.standard.set(true, forKey: "welcomeCompleted"); self?.welcome?.close()
                })
        }
        show(welcome)
    }
    func showSettings() {
        if settings == nil {
            settings = window(title: "Trackglass Settings", size: NSSize(width: 560, height: 420),
                content: MacSettingsContent(model: model, pairing: pairing, control: control, updates: updates,
                    toggleRecording: { [weak self] in self?.toggleRecording() }))
        }
        pairing.refreshPeers(); show(settings)
    }
    func toggleRecording() {
        if model.isRecording { input.stopRecording() } else { input.startRecording() }
    }
    private func window<V: View>(title: String, size: NSSize, content: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
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
    let finish: () -> Void
    @State private var startAtLogin: Bool
    init(permission: AccessibilityPermission, model: MacSettingsModel, startAtLogin: Bool, finish: @escaping () -> Void) {
        _permission = Bindable(permission); _model = Bindable(model); self.finish = finish
        _startAtLogin = State(initialValue: startAtLogin)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Welcome to Trackglass").font(.largeTitle.bold())
            Text("Use your iPhone or iPad to control this Mac. First, allow Accessibility so Trackglass can move the pointer and perform gestures.")
            Label(permission.isTrusted ? "Accessibility is allowed" : "Accessibility is required", systemImage: permission.isTrusted ? "checkmark.circle.fill" : "hand.raised")
            if !permission.isTrusted { Button("Open System Settings", action: permission.openSystemSettings) }
            Toggle("Start Trackglass at login", isOn: $startAtLogin)
            if let error = model.error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Get started") {
                    if startAtLogin != model.loginEnabled { model.setLoginEnabled(startAtLogin) }
                    finish()
                }.buttonStyle(.borderedProminent).disabled(!permission.isTrusted)
            }
        }.padding(28).frame(width: 480, height: 380)
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
                Toggle("Start at login", isOn: Binding(get: { model.loginEnabled }, set: { _ = model.setLoginEnabled($0) }))
                LabeledContent("Mac tracking speed", value: String(format: "%.2f", control.currentTrackingSpeed))
                LabeledContent("Phone tracking offset", value: String(format: "%+.2f", control.trackingOverride))
                Text("Tracking speed follows System Settings. Adjust the phone’s Feel settings for an offset.").font(.caption).foregroundStyle(.secondary)
                Toggle("Check for updates automatically", isOn: $updates.automaticallyChecksForUpdates)
                HStack {
                    Button("Check for Updates…") { updates.checkForUpdates() }
                    if let lastCheck = updates.lastCheck {
                        Text("Last checked \(lastCheck.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }.padding().tabItem { Label("General", systemImage: "gear") }
            List {
                if pairing.pairedPeers.isEmpty { Text("No paired devices") }
                ForEach(pairing.pairedPeers, id: \.peerID) { peer in
                    HStack {
                        Text(peer.name); Spacer()
                        Button("Forget", role: .destructive) {
                            do { try control.forget(peer.peerID); pairing.refreshPeers() }
                            catch { model.error = error.localizedDescription }
                        }
                    }
                }
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }.tabItem { Label("Devices", systemImage: "iphone") }
            Form {
                Button(model.isRecording ? "Stop recording" : "Record session", action: toggleRecording)
                Text("Recordings are saved in Application Support/Trackglass/Recordings.").font(.caption)
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
        }.padding(16).frame(width: 560, height: 420)
    }
}
