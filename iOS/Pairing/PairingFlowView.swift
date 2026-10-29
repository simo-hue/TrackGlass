import SwiftUI
import TrackglassKit
import UIKit

struct PairingFlowView: View {
    @State private var browser = MacBrowser()
    @State private var client = PairingClient()
    @State private var name = PhoneIdentityStore().name
    @State private var scanner = false
    @State private var showPIN = false
    @State private var pending: PairingPayload?
    /// A pairing link can be opened by any app or web page: it is only acted on after the user confirms it here
    /// (§3.4 "Never auto-pair"). Codes scanned with the in-app scanner are the user's own action already.
    @State private var awaitingLinkConfirmation: Bool
    @State private var pairing = false
    @State private var status = "Open ‘Pair a device…’ in Trackglass for Mac."
    @State private var exchange: Task<Void, Never>?
    /// A Mac was paired (either path): the flow closes itself so the phone can connect to it right away.
    @State private var didPair = false
    @Environment(\.dismiss) private var dismiss
    /// Called once a Mac has been paired, so the caller can connect to it right away.
    private let onPaired: ((PairedPeer) -> Void)?

    init(payload: PairingPayload? = nil, onPaired: ((PairedPeer) -> Void)? = nil) {
        _pending = State(initialValue: payload)
        _awaitingLinkConfirmation = State(initialValue: payload != nil)
        self.onPaired = onPaired
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Your device name") { TextField("Name", text: $name).disabled(pairing) }
                if awaitingLinkConfirmation, let link = pending {
                    Section {
                        Text("A link asks to pair with “\(link.macName)”. Continue only if that Mac shows its pairing window in front of you.")
                        Button("Pair with \(link.macName)") {
                            PhoneIdentityStore().name = name
                            awaitingLinkConfirmation = false
                            status = "Looking for the Mac’s pairing window…"
                            tryPair()
                        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Ignore this link", role: .cancel) { awaitingLinkConfirmation = false; pending = nil }
                    }
                }
                Section {
                    Button("Scan Mac QR code") {
                        PhoneIdentityStore().name = name
                        pending = nil
                        awaitingLinkConfirmation = false
                        scanner = true
                    }.disabled(pairing || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Use a code instead") {
                        PhoneIdentityStore().name = name
                        pending = nil
                        awaitingLinkConfirmation = false
                        showPIN = true
                    }.disabled(pairing || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text(status)
                }
            }
            .navigationTitle("Pair with a Mac")
            .toolbar { Button("Done") { dismiss() } }
        }
        .sheet(isPresented: $showPIN, onDismiss: { if didPair { dismiss() } }) {
            PINEntryView(phoneName: name) { peer in finishPairing(peer) }
        }
        .fullScreenCover(isPresented: $scanner) {
            ZStack(alignment: .topTrailing) {
                QRScannerView { text in
                    // Any other QR code is reported by the scanner, which keeps scanning.
                    guard let url = URL(string: text), let payload = try? PairingPayload(url: url) else { return false }
                    scanner = false
                    pending = payload
                    status = "Looking for the Mac’s pairing window…"
                    tryPair()
                    return true
                }.ignoresSafeArea()
                Button("Cancel") { scanner = false }.padding().buttonStyle(.borderedProminent)
            }
        }
        .onAppear { browser.start(); tryPair() }
        .onChange(of: browser.macs.map { $0.instanceName + ($0.pairID?.base64EncodedString() ?? "") }) { tryPair() }
        .task(id: pending?.identity) {
            guard pending != nil else { return }
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            guard !pairing, pending != nil else { return }
            pending = nil
            status = "The pairing window was not found. Open it on the Mac and scan again."
        }
        .onDisappear {
            if !scanner { browser.stop(); exchange?.cancel(); client.cancel() }
        }
    }

    private func finishPairing(_ peer: PairedPeer) {
        status = "Paired with \(peer.name)"
        didPair = true
        OnboardingProgress.markCompleted()   // a paired phone never needs the introduction again
        UIAccessibility.post(notification: .announcement, argument: "Paired with \(peer.name)")
        onPaired?(peer)
    }

    private func tryPair() {
        guard !pairing, !awaitingLinkConfirmation, let payload = pending,
              let mac = browser.macs.first(where: { $0.instanceName == payload.bonjourInstanceName && $0.isPairing && $0.pairID == payload.pairID }) else { return }
        pairing = true
        status = "Pairing… Click Allow on the Mac when it asks."
        let identity = PhoneIdentityStore()
        identity.name = name
        let request = PairRequestMessage(peerID: identity.peerID, name: name,
                                         modelIdentifier: PhoneIdentityStore.modelIdentifier(), protocolVersion: MessageHeader.protocolVersion)
        exchange = Task {
            defer { pairing = false; pending = nil }
            do {
                let peer = try await client.pair(payload: payload, endpoint: mac.endpoint, expectedMacID: mac.peerID, request: request)
                finishPairing(peer)
                dismiss()
            } catch is CancellationError { status = "Pairing cancelled." }
            catch { status = error.localizedDescription }
        }
    }
}
