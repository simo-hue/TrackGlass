import UIKit
import OSLog
import SwiftUI
import TrackglassKit

final class TouchSurfaceViewController: UIViewController {
    private let themeStore = ThemeStore()
    private let recordingState = SurfaceRecordingState()
    private weak var touchSurface: TouchSurfaceView?
    private var hasPresentedDiscovery = false
    let pairingLinks = PairingLinkRouter()
    private let inputSink = UDPFrameSink()
    let connectionState = ConnectionState()
    private lazy var session = SessionClient(inputSink: inputSink)
    lazy var connectionManager = ConnectionManager(state: connectionState, browser: MacBrowser(), session: session)
    private let identity = PhoneIdentityStore()
    private var geometry: SurfaceGeometry?
    private var surfaceVisible = false
    private var statusHost: UIHostingController<SessionStatusView>?
    private var noMacHost: UIViewController?
    private weak var discoveryHost: UIViewController?
    private let overlayLayout = OverlayLayout()
    private var tapToClickNoticePending = false
    private var thermalObserver: NSObjectProtocol?

    /// HELLO `caps` (§4.5): bit 0 haptics, bit 1 coalesced samples (M10.3).
    nonisolated static func capabilities(defaults: UserDefaults = .standard) -> UInt32 {
        (HapticEngine.supportsHaptics ? 1 : 0) | (defaults.bool(forKey: "coalescedSamples") ? 2 : 0)
    }

    nonisolated static func suppressesHalos(for state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }

    private func applyThermalState(_ state: ProcessInfo.ThermalState) {
        touchSurface?.setHalosSuppressed(Self.suppressesHalos(for: state))
    }

    func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = surfaceVisible && connectionState.isConnected && UIApplication.shared.applicationState == .active
    }

    private func connect(_ mac: DiscoveredMac) {
        guard let hello = currentHello() else { return }
        Task { await connectionManager.connect(to: mac, hello: hello) }
    }

    /// Opens the pairing flow itself (over the Macs sheet, which connects to the new Mac once it is paired).
    private func openPairing() {
        pairingLinks.showPairing()
        if let presented = presentedViewController {
            guard presented !== discoveryHost else { return }   // the Macs sheet presents the flow by itself
            dismiss(animated: true) { [weak self] in self?.showDiscoveryIfNeeded() }
        } else {
            showDiscoveryIfNeeded()
        }
    }

    private func reconnect() {
        guard let hello = currentHello() else { return }
        Task { await connectionManager.reconnectNow(hello: hello) }
    }

    private func sessionChanged() {
        updateIdleTimer()
        touchSurface?.accessibilityValue = connectionState.accessibilityStatus
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        connectionState.onSessionChange = { [weak self] in self?.sessionChanged() }
        connectionState.onAnnouncement = { text in UIAccessibility.post(notification: .announcement, argument: text) }
        touchSurface?.accessibilityValue = connectionState.accessibilityStatus
        connectionState.onTapToClickDisabled = { [weak self] in
            self?.tapToClickNoticePending = true
            self?.showTapToClickNoticeIfNeeded()
        }
        // Container has no gestures; the touch surface and status controls are siblings.
        let host = UIHostingController(rootView: SessionStatusView(state: connectionState, layout: overlayLayout))
        host.safeAreaRegions = []   // pinned to the safe-area guide already; avoid a second inset
        // Follows the pill's size (a wrapped notice, the latency overlay) instead of a stale first measurement.
        host.sizingOptions = .intrinsicContentSize
        addChild(host)
        host.view.backgroundColor = .clear
        // The pill is information only: its hosting view (a band across the top) must never take a touch that
        // belongs to the trackpad surface underneath.
        host.view.isUserInteractionEnabled = false
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            host.view.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
        host.didMove(toParent: self)
        statusHost = host
        let grip = UIHostingController(rootView: GripButton(themes: themeStore) { [weak self] in self?.showSettings() })
        grip.safeAreaRegions = []   // pinned to the safe-area guide already; avoid a second inset
        addChild(grip); grip.view.backgroundColor = .clear; grip.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grip.view)
        NSLayoutConstraint.activate([
            grip.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            grip.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            grip.view.widthAnchor.constraint(equalToConstant: 36), grip.view.heightAnchor.constraint(equalToConstant: 36)
        ])
        grip.didMove(toParent: self)
        let noMac = UIHostingController(rootView: NoMacView(state: connectionState, layout: overlayLayout,
            pair: { [weak self] in self?.openPairing() }, connect: { [weak self] mac in self?.connect(mac) },
            reconnect: { [weak self] in self?.reconnect() },
            interactiveChanged: { [weak self] interactive in self?.noMacHost?.view.isUserInteractionEnabled = interactive }))
        noMacHost = noMac
        noMac.safeAreaRegions = []   // pinned to the safe-area guide already; avoid a second inset
        // The panel's hosting view follows its content's size, so once a Mac is connected (empty content) it
        // shrinks to nothing instead of keeping a stale frame that would swallow surface touches.
        noMac.sizingOptions = .intrinsicContentSize
        addChild(noMac); noMac.view.backgroundColor = .clear; noMac.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(noMac.view)
        NSLayoutConstraint.activate([
            noMac.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            noMac.view.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            noMac.view.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),
            noMac.view.heightAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.heightAnchor, constant: -48)
        ])
        noMac.didMove(toParent: self)
        applyThermalState(ProcessInfo.processInfo.thermalState)
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.applyThermalState(ProcessInfo.processInfo.thermalState) }
            }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        overlayLayout.update(size: CGSize(width: view.bounds.width, height: view.safeAreaLayoutGuide.layoutFrame.height))
    }

    override func loadView() {
        let surface = TouchSurfaceView(frame: .zero, sink: inputSink)
        touchSurface = surface
        // The first finger down warms the haptic engine up, so the Mac's first haptic is not late.
        surface.onFirstContactBegan = { [weak self] in self?.session.prewarmHaptics() }
        surface.applyTheme(themeStore.theme)
        themeStore.onChange = { [weak surface] theme in surface?.applyTheme(theme) }
        surface.geometryDidChange = { [weak self] geometry in
            self?.geometry = geometry
            guard let self, let hello = self.currentHello() else { return }
            let surface = SurfaceMessage(surfaceWidthMM: Float(geometry.widthMM), surfaceHeightMM: Float(geometry.heightMM),
                ppi: Float(DevicePPI.lookup(modelIdentifier: PhoneIdentityStore.modelIdentifier())), trackingOverride: UserDefaults.standard.float(forKey: "trackingOverride"))
            Task { await self.connectionManager.updateSurface(surface, hello: hello) }
            let logger = Logger(subsystem: "app.trackglass.ios", category: "SurfaceGeometry")
            logger.debug("surface widthMM=\(geometry.widthMM, privacy: .public) heightMM=\(geometry.heightMM, privacy: .public)")
        }
        let container = UIView()
        container.backgroundColor = .black
        surface.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view = container
    }

    // Keep edge deferral active; automatic hiding takes precedence over it.
    override var prefersHomeIndicatorAutoHidden: Bool { false }
    override var prefersStatusBarHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        traitCollection.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        surfaceVisible = true
        updateIdleTimer()
        showTapToClickNoticeIfNeeded()
        if pairingLinks.presentation == nil, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
           !OnboardingProgress.isCompleted(hasPairedMacs: { (try? PairingStore().all().isEmpty == false) ?? false }) {
            showOnboarding(); return
        }
        guard (!hasPresentedDiscovery || pairingLinks.presentation != nil),
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        if pairingLinks.presentation == nil, let hello = currentHello() {
            // Auto-connect to the last used Mac; only a phone with no last Mac is sent to the Macs list.
            hasPresentedDiscovery = true
            Task { [weak self] in
                guard let self else { return }
                let resumed = await self.connectionManager.resumeLastMac(hello: hello)
                if !resumed { self.showDiscoveryIfNeeded() }
            }
        } else {
            showDiscoveryIfNeeded()
        }
    }

    func handlePairingURL(_ url: URL) {
        guard pairingLinks.open(url) else { return }
        if presentedViewController != nil {
            dismiss(animated: true) { [weak self] in self?.showDiscoveryIfNeeded() }
        } else {
            showDiscoveryIfNeeded()
        }
    }

    func sceneDidEnterBackground() {
        touchSurface?.suspend()
        // §5.9: BYE(user) must leave the device before suspension; a background task keeps the app running for it.
        let task = UIApplication.shared.beginBackgroundTask(withName: "Trackglass BYE")
        Task {
            await connectionManager.sceneDidEnterBackground()
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }
    func sceneDidBecomeActive() { touchSurface?.resume(); Task { await connectionManager.sceneDidBecomeActive() } }

    private func showOnboarding() {
        guard presentedViewController == nil else { return }
        let host = UIHostingController(rootView: OnboardingView { [weak self] in
            OnboardingProgress.markCompleted()
            // "Pair a Mac" opens the pairing flow itself, not a list the user has to tap through first.
            self?.pairingLinks.showPairing()
            self?.dismiss(animated: true) { [weak self] in self?.showDiscoveryIfNeeded() }
        })
        host.modalPresentationStyle = .fullScreen
        present(host, animated: true)
    }

    private func showSettings() {
        guard presentedViewController == nil else { return }
        let sheet = UIHostingController(rootView: SettingsSheet(themes: themeStore, connection: connectionState, manager: connectionManager, connect: { [weak self] mac in self?.connect(mac) },
            openPairing: { [weak self] in
                self?.pairingLinks.showPairing()
                self?.dismiss(animated: true) { [weak self] in self?.showDiscoveryIfNeeded() }
            }, startRecording: { [weak self] in
                guard let self, let geometry = self.geometry, let sender = self.touchSurface?.frameSender else { throw CocoaError(.coderValueNotFound) }
                try await sender.startRecording(widthMM: geometry.widthMM, heightMM: geometry.heightMM)
            }, finishRecording: { [weak self] in
                guard let sender = self?.touchSurface?.frameSender else { throw CocoaError(.coderValueNotFound) }
                return try await sender.finishRecording()
            }, recordingState: recordingState))
        sheet.sheetPresentationController?.detents = [.medium(), .large()]
        present(sheet, animated: true)
    }

    private func showDiscoveryIfNeeded() {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        hasPresentedDiscovery = true
        Task {
            await connectionManager.startDiscovery()
            await connectionManager.refreshPairedMacs()
        }
        let discovery = UIHostingController(rootView: MacDiscoveryView(state: connectionState, manager: connectionManager,
            connect: { [weak self] mac in self?.connect(mac) }, links: pairingLinks))
        discoveryHost = discovery
        present(discovery, animated: true)
    }

    private func showTapToClickNoticeIfNeeded() {
        guard tapToClickNoticePending, viewIfLoaded?.window != nil,
              presentedViewController == nil,
              !UserDefaults.standard.bool(forKey: "TrackglassDidShowTapToClickNotice") else { return }
        tapToClickNoticePending = false
        UserDefaults.standard.set(true, forKey: "TrackglassDidShowTapToClickNotice")
        connectionState.notice = "Tap to click is off on your Mac. Trackglass still clicks when you tap."
    }

    private func currentHello() -> HelloMessage? {
        guard let geometry, let screen = view.window?.screen else { return nil }
        return HelloMessage(protocolVersion: 1, peerID: identity.peerID, name: identity.name,
            modelIdentifier: PhoneIdentityStore.modelIdentifier(), surfaceWidthMM: Float(geometry.widthMM),
            surfaceHeightMM: Float(geometry.heightMM), ppi: Float(DevicePPI.lookup(modelIdentifier: PhoneIdentityStore.modelIdentifier())),
            maxContacts: 10, displayHz: UInt16(screen.maximumFramesPerSecond), caps: Self.capabilities(),
            trackingOverride: UserDefaults.standard.float(forKey: "trackingOverride"))
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        surfaceVisible = false
        updateIdleTimer()
    }
}

private struct SessionStatusView: View {
    @Bindable var state: ConnectionState
    let layout: OverlayLayout
    @AppStorage("showsHUD") private var showsHUD = true
    @AppStorage("showsLatencyOverlay") private var showsLatencyOverlay = false
    @State private var visible = true
    var body: some View {
        VStack(spacing: 8) {
            if showsHUD && visible {
                // "—" until the first round trip has been measured, never a made-up "0.0 ms".
                Text(state.pillText)
                    .font(.caption).multilineTextAlignment(.center).padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            if showsLatencyOverlay && state.isConnected {
                LatencyOverlay(state: state)
            }
        }
        .frame(width: layout.statusWidth)
        .allowsHitTesting(false)
        .task(id: state.status + (state.notice ?? "")) {
            visible = true
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            visible = false
            // A notice is shown once; later pill appearances must show the live session state again.
            if state.notice != nil { state.notice = nil }
        }
    }
}

private struct LatencyOverlay: View {
    @Bindable var state: ConnectionState
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RTT \(Double(state.rttMicros) / 1_000, specifier: "%.1f") ms · \(state.diagnostics?.framesPerSecond ?? 0) fps · loss \(state.diagnostics?.lossPermille ?? 0)‰")
                .font(.caption2.monospacedDigit())
            Canvas { context, size in
                let samples = state.latencySamples
                guard samples.count > 1 else { return }
                let maximum = max(1, samples.max() ?? 1)
                var path = Path()
                for (index, sample) in samples.enumerated() {
                    let point = CGPoint(x: Double(index) / Double(samples.count - 1) * size.width,
                        y: size.height * (1 - sample / maximum))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(.primary), lineWidth: 1)
            }.frame(height: 30).accessibilityLabel("Recent round trip latency")
        }
        .padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
