import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import TrackglassKit

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
        // Keeps the QR code out of screen sharing and recordings that honour it (round 4 security review, item 3).
        window.sharingType = .none
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
            // A new identity per question, so Allow starts disabled again.
            PairingApprovalView(service: service, pending: pending).id(pending.id)
        } else {
            credentials
        }
    }

    private var credentials: some View {
        HStack(spacing: 12) {
            if service.mode == .qr, service.isAdvertised, let payload = service.payload, let image = QRCodeRenderer.image(for: payload.url) {
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
                if service.isOpen && !service.isFinished && service.payload != nil && !service.sessionInProgress {
                    Button(service.mode == .qr ? "Use a code instead" : "Use the QR code instead") {
                        service.setMode(service.mode == .qr ? .code : .qr)
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

/// §3.4: the user decides whether the phone may pair. QR path (2026-10-28): the phone proved it scanned the code.
/// Code pairing (2026-10-31): the user compares the six digits with the phone's screen; that comparison is what
/// authenticates the exchange. The phone's name is sanitized (`PairingText.sanitizedName`).
private struct PairingApprovalView: View {
    let service: PairingService
    let pending: PairingService.PendingApproval
    /// Allow is enabled about a second after the question appears: the window comes forward on its own, at a
    /// predictable spot, and a click meant for something else must not land on it.
    @State private var canAllow = false

    var body: some View {
        VStack(spacing: 16) {
            if let code = pending.code {
                Text("Does “\(pending.phoneName)” show").font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityHidden(true)
                Text("\(PairingText.formattedCode(code))?")
                    .font(.system(size: 48, weight: .semibold, design: .monospaced))
                    .accessibilityLabel("Does “\(pending.phoneName)” show the code \(PairingText.spokenCode(code))?")
                Text("Allow only if it shows the same code.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            } else {
                Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 48)).accessibilityHidden(true)
                Text("Allow “\(pending.phoneName)” to pair with this Mac?").font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("\(pending.modelName) will be able to control this Mac's pointer whenever it is nearby. Only allow a device you are holding.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            if let replaces = pending.replaces {
                Text("This replaces the existing pairing of “\(replaces)”.")
                    .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Don’t Allow") { service.respondToPendingPairing(allow: false) }
                    .keyboardShortcut(.cancelAction)
                // No default action: the question comes to the front while the user may be typing elsewhere, and a
                // Return meant for another app must never approve a pairing (§3.4: the Allow click is the consent).
                Button("Allow") { service.respondToPendingPairing(allow: true) }
                    .disabled(!canAllow)
            }
        }
        .padding(28)
        .frame(width: 480, height: 360)
        .task {
            try? await Task.sleep(for: .seconds(1))
            canAllow = true
        }
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
