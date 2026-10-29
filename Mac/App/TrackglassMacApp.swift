import SwiftUI
import AppKit
import TrackglassKit
import TrackglassEngine

@main
struct TrackglassMacApp: App {
    @NSApplicationDelegateAdaptor(TrackglassAppDelegate.self) private var appDelegate
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
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !testing, let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
            if SingleInstance.shouldYield(SingleInstance.Instance(NSRunningApplication.current), to: others.map { SingleInstance.Instance($0) }) {
                // The copy that stays shows its window (opening the app again must visibly do something).
                DistributedNotificationCenter.default().postNotificationName(TrackglassAppDelegate.showWindowNotification,
                    object: bundleID, userInfo: nil, deliverImmediately: true)
                others.min(by: { SingleInstance.precedes(.init($0), .init($1)) })?.activate(options: [])
                exit(0)
            }
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
        }, onInputPathDead: { [weak control] peerID in
            Task { @MainActor in control?.inputPathDied(peerID: peerID) }
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
                // Synchronously, before the observer returns: a hop through a Task could run after the system has
                // already suspended networking, and the phone would only notice the Mac after three missed pings.
                MainActor.assumeIsolated {
                    control?.prepareForSleep()
                    inputListener.setAdmittedPeer(nil)
                    advertiser?.stop()
                }
            })
        workspaceObservers.append(workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak advertiser] _ in
                Task { @MainActor in advertiser?.start(promptForAccessibility: false) }
            })
        pairing.peersChanged = { [weak advertiser] in advertiser?.pairingSetChanged() }
        let pairingWindow = PairingWindow(service: pairing)
        self.pairingWindow = pairingWindow
        let windows = MacWindowCoordinator(permission: advertiser.accessibilityPermission, pairing: pairing, control: control, input: inputListener, updates: updates)
        self.windows = windows
        windows.showPairing = { [pairingWindow] in pairingWindow.show() }
        TrackglassAppDelegate.onReopen = { [weak windows] in windows?.showForReopen() }
        if let bundleID = Bundle.main.bundleIdentifier {
            workspaceObservers.append(DistributedNotificationCenter.default().addObserver(
                forName: TrackglassAppDelegate.showWindowNotification, object: bundleID, queue: .main) { _ in
                    MainActor.assumeIsolated { TrackglassAppDelegate.onReopen?() }
                })
        }
        // Quit (menu, logout, Sparkle relaunch): phones get BYE{0} instead of waiting out three pings, held buttons
        // are released and a recording is finished before the process goes (§6.1). Bounded to 0.5 s.
        TrackglassAppDelegate.prepareForTermination = { [weak control, weak advertiser, inputListener] done in
            control?.endAllSessionsForQuit()
            inputListener.shutdown()
            Task { @MainActor [control, advertiser] in
                var waited = 0
                while waited < 10, let control, control.openChannelCount > 0 {
                    try? await Task.sleep(for: .milliseconds(50))
                    waited += 1
                }
                advertiser?.stop()
                done()
            }
        }
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
                Task { @MainActor in control?.setSessionActive(true); advertiser?.start(promptForAccessibility: false) }
            })
        if !testing {
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
            if LocalNetworkPermission.shared.isDenied {
                Button("Open Local Network Settings") { LocalNetworkPermission.shared.openSystemSettings() }
            }
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
                .disabled(!updates.canCheckForUpdates)
            if !pairing.pairedPeers.isEmpty {
                Menu("Paired devices") {
                    ForEach(pairing.pairedPeers, id: \.peerID) { peer in
                        let connected = control.connectedPeerID == peer.peerID
                        Menu(connected ? "\(peer.name) — connected" : peer.name) {
                            if connected {
                                Button("Disconnect") { control.disconnect(peerID: peer.peerID) }
                            }
                            Button("Forget…") {
                                errorMessage = DeviceActions.forget(peer, control: control, pairing: pairing)
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
