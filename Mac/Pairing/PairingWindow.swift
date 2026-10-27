import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

@MainActor
final class PairingWindow: NSObject, NSWindowDelegate {
    private let service: PairingService
    private var window: NSWindow?

    init(service: PairingService) {
        self.service = service
        super.init()
        service.windowExpired = { [weak self] in self?.window?.close() }
    }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        service.open()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pair a device"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: PairingWindowContent(service: service))
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        service.close()
        window = nil
    }
}

private struct PairingWindowContent: View {
    let service: PairingService

    var body: some View {
        HStack(spacing: 12) {
            if service.mode == .pin, service.isAdvertised, let pin = service.pin {
                Text(pin).font(.system(size: 48, weight: .semibold, design: .monospaced))
                    .accessibilityLabel("Pairing code \(pin)")
            } else if service.mode == .qr, service.isAdvertised, let payload = service.payload, let image = QRCodeRenderer.image(for: payload.url) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 320, height: 320)
                    .background(.white)
                    .accessibilityLabel("Pairing QR code")
            }
            VStack(spacing: 16) {
                Text(service.status)
                if service.isOpen && service.payload != nil {
                    Button(service.mode == .qr ? "Use a code instead" : "Use QR instead") {
                        service.setMode(service.mode == .qr ? .pin : .qr)
                    }
                }
            }.frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(width: 480, height: 360)
    }

}

enum QRCodeRenderer {
    static func image(for url: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
