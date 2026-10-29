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
        service.approvalRequested = { [weak self] in self?.bringForward() }
    }

    func show() {
        if let window {
            // The window outlived its pairing (paired, declined, failed, code limit): "Pair a device…" starts over.
            if service.isFinished { service.open() }
            bringForward(window)
            return
        }
        service.open()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pair a device"
        window.level = .floating
        // A menu-bar app's window opens on the Space the user is looking at, not on the one it was last shown on.
        window.collectionBehavior = [.moveToActiveSpace]
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: PairingWindowContent(service: service))
        window.delegate = self
        window.center()
        self.window = window
        bringForward(window)
    }

    /// A phone is waiting for Allow: the question must be seen even if the user moved on to another app or Space.
    private func bringForward(_ target: NSWindow? = nil) {
        guard let window = target ?? window else { return }
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if target == nil { NSApp.requestUserAttention(.informationalRequest) }
    }

    func windowWillClose(_ notification: Notification) {
        service.close()
        window = nil
    }
}

private struct PairingWindowContent: View {
    let service: PairingService

    var body: some View {
        if let pending = service.pendingApproval {
            approval(pending)
        } else {
            credentials
        }
    }

    /// §3.4 (2026-10-28): the phone has proven it knows the code; the user decides whether it may pair.
    private func approval(_ pending: PairingService.PendingApproval) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 48)).accessibilityHidden(true)
            Text("Allow “\(pending.phoneName)” to pair with this Mac?").font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("\(pending.modelName) will be able to control this Mac's pointer whenever it is nearby. Only allow a device you are holding.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Don’t Allow") { service.respondToPendingPairing(allow: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { service.respondToPendingPairing(allow: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 480, height: 360)
    }

    private var credentials: some View {
        HStack(spacing: 12) {
            if service.mode == .pin, service.isAdvertised, let pin = service.pin {
                Text(pin).font(.system(size: 48, weight: .semibold, design: .monospaced))
                    .accessibilityLabel("Pairing code \(pin)")
            } else if service.mode == .qr, service.isAdvertised, let payload = service.payload, let image = QRCodeRenderer.image(for: payload.url) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 260, height: 260)
                    // White quiet zone around the symbol: in Dark Mode the window background is not one, and phone
                    // cameras need it to find the code.
                    .padding(16)
                    .background(Color.white)
                    .accessibilityLabel("Pairing QR code")
            }
            VStack(spacing: 16) {
                Text(service.status)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if LocalNetworkPermission.shared.isDenied {
                    Button("Open Local Network Settings") { LocalNetworkPermission.shared.openSystemSettings() }
                }
                if service.isOpen && !service.isFinished && service.payload != nil {
                    Button(service.mode == .qr ? "Use a code instead" : "Use QR instead") {
                        service.setMode(service.mode == .qr ? .pin : .qr)
                    }
                }
                if service.isFinished {
                    Button(service.didPair ? "Pair another device" : "Try again") { service.open() }
                        .keyboardShortcut(.defaultAction)
                }
            }.frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(width: 480, height: 360)
    }

}

/// SwiftUI re-evaluates the pairing view on every status change; the code is rendered once per payload.
@MainActor
enum QRCodeRenderer {
    private static let context = CIContext()
    private static var cached: (url: URL, image: CGImage)?

    static func image(for url: URL) -> CGImage? {
        if let cached, cached.url == url { return cached.image }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, let image = context.createCGImage(output, from: output.extent) else { return nil }
        cached = (url, image)
        return image
    }
}
