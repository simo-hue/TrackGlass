import SwiftUI
import TrackglassKit
import UIKit

struct PairingFlowView: View {
    @State private var browser = MacBrowser()
    @State private var client = PairingClient()
    @State private var name = PhoneIdentityStore().name
    @State private var scanner = false
    @State private var showCodePairing = false
    @State private var pending: PairingPayload?
    /// §3.4 (round 4, L4): a scanned code or a link for a Mac this device is already paired with waits for the user's
    /// "Replace" (the name is the stored one, not the link's).
    @State private var askReplace = false
    @State private var existingName = ""
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
                        Text("A link asks to pair with “\(PairingText.sanitizedName(link.macName))”. Continue only if that Mac shows its pairing window in front of you.")
                        Button("Pair with \(PairingText.sanitizedName(link.macName))") {
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
                    Button("Pair with a code") {
                        PhoneIdentityStore().name = name
                        pending = nil
                        awaitingLinkConfirmation = false
                        showCodePairing = true
                    }.disabled(pairing || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text(status)
                }
            }
            .navigationTitle("Pair with a Mac")
            .toolbar { Button("Done") { dismiss() } }
        }
        .sheet(isPresented: $showCodePairing, onDismiss: { if didPair { dismiss() } }) {
            CodePairingView(phoneName: name) { peer in finishPairing(peer) }
        }
        .alert("Replace the pairing with “\(PairingText.sanitizedName(existingName))”?", isPresented: $askReplace) {
            Button("Replace", role: .destructive) {
                askReplace = false
                tryPair(replacingExisting: true)
            }
            Button("Cancel", role: .cancel) {
                askReplace = false
                pending = nil
                status = "Pairing cancelled. The existing pairing is unchanged."
            }
        } message: {
            Text("This device is already paired with that Mac. Replace the pairing only if you are pairing the same Mac again.")
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

    private func tryPair(replacingExisting: Bool = false) {
        guard !pairing, !awaitingLinkConfirmation, !askReplace, let payload = pending,
              let mac = browser.macs.first(where: { $0.instanceName == payload.bonjourInstanceName && $0.isPairing && $0.pairID == payload.pairID }) else { return }
        pairing = true
        status = "Pairing… Click Allow on the Mac when it asks."
        let identity = PhoneIdentityStore()
        identity.name = name
        let request = PairRequestMessage(peerID: identity.peerID, name: name,
                                         modelIdentifier: PhoneIdentityStore.modelIdentifier(), protocolVersion: MessageHeader.protocolVersion)
        exchange = Task {
            defer { pairing = false }
            do {
                let peer = try await client.pair(payload: payload, endpoint: mac.endpoint, expectedMacID: mac.peerID, request: request,
                                                 replacingExisting: replacingExisting)
                pending = nil
                finishPairing(peer)
                dismiss()
            } catch PairingClient.Failure.alreadyPaired(let storedName) {
                // Nothing was sent yet: the code stays pending until the user decides (§3.4, never a silent overwrite).
                existingName = storedName
                status = "This device is already paired with “\(PairingText.sanitizedName(storedName))”."
                askReplace = true
            } catch is CancellationError { pending = nil; status = "Pairing cancelled." }
            catch { pending = nil; status = error.localizedDescription }
        }
    }
}
