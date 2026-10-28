import SwiftUI
import AppKit
import TrackglassKit
import TrackglassEngine

@main
struct TrackglassMacApp: App {
    private let privateAPICapabilities = TGPrivateAPIGetCapabilities()
    @State private var advertiser: BonjourAdvertiser

    private let control: ControlListener
    private let inputListener: InputListener
    @State private var errorMessage: String?
    private let windows: MacWindowCoordinator
    private let updates = UpdateController()
    private let pairing: PairingService
    private let pairingWindow: PairingWindow
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
           let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [])
            exit(0)
        }
        let advertiser = BonjourAdvertiser()
        _advertiser = State(initialValue: advertiser)
        let pairing = PairingService(identity: PeerIdentity(peerID: advertiser.peerID, name: advertiser.name))
        self.pairing = pairing
        let control = ControlListener(identity: PeerIdentity(peerID: advertiser.peerID, name: advertiser.name))
        self.control = control
        let inputListener = InputListener(onHaptic: { [weak control] peerID, kind in
            Task { @MainActor in control?.sendHaptic(kind, to: peerID) }
        }, onStatus: { [weak control] peerID, message in
            Task { @MainActor in control?.sendStatus(message, to: peerID) }
        })
        self.inputListener = inputListener
        advertiser.controlHandler = { [weak control] connection in control?.accept(connection) }
        advertiser.inputHandler = { [inputListener] connection in inputListener.accept(connection) }
        control.inputIdentityChanged = { [weak advertiser, inputListener] peerID, geometry in
            inputListener.setAdmittedPeer(peerID, geometry: geometry)
            advertiser?.setInputIdentity(peerID)
        }
        control.inputGeometryChanged = { [inputListener] geometry in inputListener.updateGeometry(geometry) }
        control.inputSettingsChanged = { [inputListener] settings in inputListener.updateSettings(settings) }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspaceCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main) { [inputListener] _ in inputListener.displayDidSleep() })
        workspaceObservers.append(workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak advertiser, weak control, inputListener] _ in
                Task { @MainActor in
                    control?.prepareForSleep()
                    inputListener.setAdmittedPeer(nil)
                    advertiser?.stop()
                }
            })
        workspaceObservers.append(workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak advertiser] _ in
                Task { @MainActor in advertiser?.start() }
            })
        pairing.peersChanged = { [weak advertiser] in advertiser?.pairingSetChanged() }
        pairingWindow = PairingWindow(service: pairing)
        let windows = MacWindowCoordinator(permission: advertiser.accessibilityPermission, pairing: pairing, control: control, input: inputListener, updates: updates)
        self.windows = windows
        advertiser.permissionRevoked = { [weak control, inputListener, weak windows] in
            control?.permissionRevoked(); inputListener.setAdmittedPeer(nil)
            windows?.showWelcomeIfNeeded(force: true)
        }
        workspaceObservers.append(workspaceCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil, queue: .main) { [weak control, inputListener] _ in
                Task { @MainActor in control?.setSessionActive(false); inputListener.setAdmittedPeer(nil) }
            })
        workspaceObservers.append(workspaceCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil, queue: .main) { [weak control, weak advertiser] _ in
                Task { @MainActor in control?.setSessionActive(true); advertiser?.start() }
            })
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            advertiser.start()
            Task { @MainActor in windows.showWelcomeIfNeeded() }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Text(advertiser.status)
            if !advertiser.accessibilityPermission.isTrusted {
                Text("Grant Accessibility to start")
                Button("Open System Settings") {
                    advertiser.accessibilityPermission.openSystemSettings()
                }
            }
            Text(control.status)
            let reduced = QuartzInjector.degradedGestures()
            if !reduced.isEmpty {
                Menu("Reduced gesture mode") {
                    ForEach(reduced, id: \.self) { Text($0) }
                }
            }
            if let errorMessage { Text(errorMessage) }
            Button("Pair a device…") { pairingWindow.show() }
            Button("Settings…") { windows.showSettings() }
            Button("Check for Updates…") { updates.checkForUpdates() }
            if !pairing.pairedPeers.isEmpty {
                Menu("Paired devices") {
                    ForEach(pairing.pairedPeers, id: \.peerID) { peer in
                        Menu(peer.name) {
                            Button("Forget") {
                                do { try control.forget(peer.peerID); pairing.refreshPeers(); errorMessage = nil }
                                catch { errorMessage = "Cannot forget device: \(error.localizedDescription)" }
                            }
                        }
                    }
                }
            }
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            // SPEC §6.1: template image (trackpad outline + phone outline), 18 × 18 pt.
            Image("MenuBarIcon")
                .renderingMode(.template)
                .accessibilityLabel(Bundle.main.object(forInfoDictionaryKey: "TGProductName") as? String ?? "Trackglass")
        }
    }
}
