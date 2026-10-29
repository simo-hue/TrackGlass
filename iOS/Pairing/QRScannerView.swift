import SwiftUI
@preconcurrency import AVFoundation

struct QRScannerView: UIViewControllerRepresentable {
    /// Returns whether the code was accepted; any other QR code is reported and scanning continues.
    let scanned: @MainActor (String) -> Bool

    func makeUIViewController(context: Context) -> QRScannerController { QRScannerController(scanned: scanned) }
    func updateUIViewController(_ controller: QRScannerController, context: Context) {}
}

@MainActor
final class QRScannerController: UIViewController {
    private let scanned: @MainActor (String) -> Bool
    private var pipeline: CameraPipeline?
    private var preview: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var interruptionObservers: [NSObjectProtocol] = []
    private var delivered = false
    /// The last rejected code: the camera reports a code on every frame, the user hears about it once.
    private var lastRejected: String?
    private let viewfinder = UIView()
    private let message = UILabel()
    private var settingsButton: UIButton?
    private static let instructions = "Point the camera at the QR code in Trackglass for Mac."

    init(scanned: @escaping @MainActor (String) -> Bool) {
        self.scanned = scanned
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(scanned:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // VoiceOver: the viewfinder, the message and (when shown) the Settings button are separate elements; the
        // root view is only their container, so the message stays readable as it changes.
        viewfinder.isAccessibilityElement = true
        viewfinder.accessibilityLabel = "Camera viewfinder"
        viewfinder.accessibilityHint = "The pairing code is read automatically when it is in view."
        view.addSubview(viewfinder)
        message.textColor = .white
        message.numberOfLines = 0
        message.textAlignment = .center
        message.font = UIFont.preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.text = Self.instructions
        message.accessibilityTraits.insert(.updatesFrequently)
        view.addSubview(message)
        updateAccessibilityOrder()
    }

    private func updateAccessibilityOrder() {
        var elements: [Any] = [message, viewfinder]
        if let settingsButton { elements.append(settingsButton) }
        view.accessibilityElements = elements
    }

    /// Updates the on-screen message and, when `announce`, has VoiceOver read it.
    private func setMessage(_ text: String, announce: Bool) {
        guard message.text != text else { return }
        message.text = text
        if announce { UIAccessibility.post(notification: .announcement, argument: text) }
    }

    private func showSettingsButton() {
        guard settingsButton == nil else { return }
        var configuration = UIButton.Configuration.filled()
        configuration.title = "Open Settings"
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        })
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40)
        ])
        settingsButton = button
        updateAccessibilityOrder()
        UIAccessibility.post(notification: .layoutChanged, argument: message)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIAccessibility.post(notification: .screenChanged, argument: message)
        Task { [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard let self, self.view.window != nil, self.pipeline == nil else { return }
            guard granted else {
                self.setMessage("Camera access is required. Enable it for Trackglass in Settings, then scan again.", announce: true)
                self.showSettingsButton()
                return
            }
            let pipeline = CameraPipeline { [weak self] text, error in
                Task { @MainActor in self?.handle(text: text, error: error) }
            }
            self.pipeline = pipeline
            let preview = AVCaptureVideoPreviewLayer(session: pipeline.session)
            preview.videoGravity = .resizeAspectFill
            self.preview = preview
            self.viewfinder.layer.addSublayer(preview)
            self.view.setNeedsLayout()
            self.observeInterruptions(of: pipeline.session)
            self.followDeviceRotation(preview: preview)
            pipeline.start()
        }
    }

    private func handle(text: String?, error: String?) {
        if let error { setMessage(error, announce: true) }
        guard let text, !delivered else { return }
        if scanned(text) {
            delivered = true
            pipeline?.stop()
        } else if text != lastRejected {
            lastRejected = text
            setMessage("This QR code is not a Trackglass pairing code. Scan the code shown by Trackglass for Mac.", announce: true)
        }
    }

    /// iOS 17: keeps the preview upright in every interface orientation (iPad landscape included).
    private func followDeviceRotation(preview: AVCaptureVideoPreviewLayer) {
        guard let camera = AVCaptureDevice.default(for: .video) else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: preview)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) {
            @Sendable [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor in self?.applyPreviewRotation(angle) }
        }
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = preview?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    /// The camera stops for other apps, Split View / Slide Over, background and system pressure; say why.
    private func observeInterruptions(of session: AVCaptureSession) {
        let center = NotificationCenter.default
        interruptionObservers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                                        object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            MainActor.assumeIsolated { self?.setMessage(Self.interruptionMessage(rawReason: raw), announce: true) }
        })
        interruptionObservers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                                        object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setMessage(Self.instructions, announce: true) }
        })
        // The preview layer has no connection until the session runs, so the coordinator's initial angle can arrive
        // before there is anything to rotate; apply the current one once frames flow.
        interruptionObservers.append(center.addObserver(forName: AVCaptureSession.didStartRunningNotification,
                                                        object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let coordinator = self.rotationCoordinator else { return }
                self.applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
            }
        })
    }

    nonisolated static func interruptionMessage(rawReason: Int?) -> String {
        let paused = "The camera is paused. Scanning resumes when it is available again."
        guard let rawReason, let reason = AVCaptureSession.InterruptionReason(rawValue: rawReason) else { return paused }
        switch reason {
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            return "The camera is unavailable while other apps share the screen. Make Trackglass full screen to scan."
        case .videoDeviceInUseByAnotherClient:
            return "Another app is using the camera. Close it to scan the pairing code."
        case .videoDeviceNotAvailableDueToSystemPressure:
            return "The camera paused because the device is too warm. Let it cool down, then try again."
        case .videoDeviceNotAvailableInBackground:
            return "The camera is paused while Trackglass is in the background."
        default:
            return paused
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        viewfinder.frame = view.bounds
        preview?.frame = viewfinder.bounds
        message.frame = view.bounds.insetBy(dx: 24, dy: 24)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pipeline?.stop()
        for observer in interruptionObservers { NotificationCenter.default.removeObserver(observer) }
        interruptionObservers.removeAll()
        rotationObservation?.invalidate(); rotationObservation = nil
        rotationCoordinator = nil
    }
}

/// Session configuration/start/stop are confined to queue; the preview layer only
/// displays the session. Metadata callbacks deliver immutable strings to the UI.
private final class CameraPipeline: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.trackglass.camera")
    private let result: @Sendable (String?, String?) -> Void

    init(result: @escaping @Sendable (String?, String?) -> Void) { self.result = result }

    func start() {
        queue.async { [self] in
            do {
                guard let camera = AVCaptureDevice.default(for: .video) else {
                    result(nil, "No camera is available."); return
                }
                let input = try AVCaptureDeviceInput(device: camera)
                let output = AVCaptureMetadataOutput()
                session.beginConfiguration()
                // iPad: keep scanning in Split View / Slide Over / Stage Manager where the system allows it.
                if session.isMultitaskingCameraAccessSupported { session.isMultitaskingCameraAccessEnabled = true }
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    session.commitConfiguration()
                    result(nil, "The camera could not be configured."); return
                }
                session.addInput(input)
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: queue)
                guard output.availableMetadataObjectTypes.contains(.qr) else {
                    session.commitConfiguration()
                    result(nil, "QR scanning is unavailable."); return
                }
                output.metadataObjectTypes = [.qr]
                session.commitConfiguration()
                session.startRunning()
            } catch { result(nil, "The camera could not be opened.") }
        }
    }

    func stop() { queue.async { [self] in session.stopRunning() } }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        for case let code as AVMetadataMachineReadableCodeObject in metadataObjects {
            if code.type == .qr, let text = code.stringValue { result(text, nil); break }
        }
    }
}
