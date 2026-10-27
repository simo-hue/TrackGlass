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
    lazy var connectionManager = ConnectionManager(state: connectionState, browser: MacBrowser(),
        session: SessionClient(inputSink: inputSink))
    private let identity = PhoneIdentityStore()
    private var geometry: SurfaceGeometry?
    private var surfaceVisible = false
    private var statusHost: UIHostingController<SessionStatusView>?
    private var tapToClickNoticePending = false
    private var thermalObserver: NSObjectProtocol?

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

    override func viewDidLoad() {
        super.viewDidLoad()
        connectionState.onSessionChange = { [weak self] in self?.updateIdleTimer() }
        connectionState.onTapToClickDisabled = { [weak self] in
            self?.tapToClickNoticePending = true
            self?.showTapToClickNoticeIfNeeded()
        }
        // Container has no gestures; the touch surface and status controls are siblings.
        let host = UIHostingController(rootView: SessionStatusView(state: connectionState, open: { [weak self] in self?.showDiscoveryIfNeeded() }))
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            host.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.view.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -112)
        ])
        host.didMove(toParent: self)
        statusHost = host
        let grip = UIHostingController(rootView: GripButton { [weak self] in self?.showSettings() })
        addChild(grip); grip.view.backgroundColor = .clear; grip.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grip.view)
        NSLayoutConstraint.activate([
            grip.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            grip.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            grip.view.widthAnchor.constraint(equalToConstant: 36), grip.view.heightAnchor.constraint(equalToConstant: 36)
        ])
        grip.didMove(toParent: self)
        let noMac = UIHostingController(rootView: NoMacView(state: connectionState,
            open: { [weak self] in self?.showDiscoveryIfNeeded() }, connect: { [weak self] mac in self?.connect(mac) }))
        addChild(noMac); noMac.view.backgroundColor = .clear; noMac.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(noMac.view)
        NSLayoutConstraint.activate([
            noMac.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            noMac.view.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            noMac.view.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48)
        ])
        noMac.didMove(toParent: self)
        applyThermalState(ProcessInfo.processInfo.thermalState)
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.applyThermalState(ProcessInfo.processInfo.thermalState) }
            }
    }

    override func loadView() {
        let surface = TouchSurfaceView(frame: .zero, sink: inputSink)
        touchSurface = surface
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
        if !UserDefaults.standard.bool(forKey: "onboardingCompleted"), pairingLinks.presentation == nil,
           ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
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

    func sceneDidEnterBackground() { touchSurface?.suspend(); Task { await connectionManager.sceneDidEnterBackground() } }
    func sceneDidBecomeActive() { touchSurface?.resume(); Task { await connectionManager.sceneDidBecomeActive() } }

    private func showOnboarding() {
        guard presentedViewController == nil else { return }
        let host = UIHostingController(rootView: OnboardingView { [weak self] in
            UserDefaults.standard.set(true, forKey: "onboardingCompleted")
            self?.dismiss(animated: true) { [weak self] in self?.showDiscoveryIfNeeded() }
        })
        host.modalPresentationStyle = .fullScreen
        present(host, animated: true)
    }

    private func showSettings() {
        guard presentedViewController == nil else { return }
        let sheet = UIHostingController(rootView: SettingsSheet(themes: themeStore, connection: connectionState, manager: connectionManager, connect: { [weak self] mac in self?.connect(mac) },
            openMacs: { [weak self] in
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
        present(UIHostingController(rootView: MacDiscoveryView(state: connectionState, manager: connectionManager,
            connect: { [weak self] mac in self?.connect(mac) }, links: pairingLinks)), animated: true)
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
            maxContacts: 10, displayHz: UInt16(screen.maximumFramesPerSecond), caps: HapticEngine.supportsHaptics ? 1 : 0,
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
    let open: () -> Void
    @AppStorage("showsHUD") private var showsHUD = true
    @AppStorage("showsLatencyOverlay") private var showsLatencyOverlay = false
    @State private var visible = true
    var body: some View {
        VStack(spacing: 8) {
            if showsHUD && visible {
                Text(state.notice ?? (state.isConnected ? "\(state.macName) · \(String(format: "%.1f", Double(state.rttMicros) / 2_000)) ms" : state.status))
                    .font(.caption).multilineTextAlignment(.center).padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            if showsLatencyOverlay && state.isConnected {
                LatencyOverlay(state: state)
            }
        }
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
