import SwiftUI
@preconcurrency import AVFoundation

struct QRScannerView: UIViewControllerRepresentable {
    let scanned: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController { QRScannerController(scanned: scanned) }
    func updateUIViewController(_ controller: QRScannerController, context: Context) {}
}

@MainActor
final class QRScannerController: UIViewController {
    private let scanned: @MainActor (String) -> Void
    private var pipeline: CameraPipeline?
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false
    private let message = UILabel()

    init(scanned: @escaping @MainActor (String) -> Void) {
        self.scanned = scanned
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(scanned:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        message.textColor = .white
        message.numberOfLines = 0
        message.textAlignment = .center
        message.font = UIFont.preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.text = "Point the camera at the QR code in Trackglass for Mac."
        view.addSubview(message)
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Camera view for scanning the pairing code"
        view.accessibilityHint = "The code is read automatically when it is in view."
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard let self, self.view.window != nil, self.pipeline == nil else { return }
            guard granted else {
                self.message.text = "Camera access is required. Enable it for Trackglass in Settings, then scan again."
                return
            }
            let pipeline = CameraPipeline { [weak self] text, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error { self.message.text = error }
                    guard let text, !self.delivered else { return }
                    self.delivered = true
                    self.pipeline?.stop()
                    self.scanned(text)
                }
            }
            self.pipeline = pipeline
            let preview = AVCaptureVideoPreviewLayer(session: pipeline.session)
            preview.videoGravity = .resizeAspectFill
            self.preview = preview
            self.view.layer.insertSublayer(preview, at: 0)
            self.view.setNeedsLayout()
            pipeline.start()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        message.frame = view.bounds.insetBy(dx: 24, dy: 24)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pipeline?.stop()
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
