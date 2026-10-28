import SwiftUI
import TrackglassKit

struct PairingFlowView: View {
    @State private var browser = MacBrowser()
    @State private var client = PairingClient()
    @State private var name = PhoneIdentityStore().name
    @State private var scanner = false
    @State private var showPIN = false
    @State private var pending: PairingPayload?
    @State private var pairing = false
    @State private var status = "Open ‘Pair a device…’ in Trackglass for Mac."
    @State private var exchange: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    /// Called once a Mac has been paired, so the caller can connect to it right away.
    private let onPaired: ((PairedPeer) -> Void)?

    init(payload: PairingPayload? = nil, onPaired: ((PairedPeer) -> Void)? = nil) {
        _pending = State(initialValue: payload)
        self.onPaired = onPaired
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Your device name") { TextField("Name", text: $name).disabled(pairing) }
                Section {
                    Button("Scan Mac QR code") {
                        PhoneIdentityStore().name = name
                        pending = nil
                        scanner = true
                    }.disabled(pairing || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Use a code instead") {
                        PhoneIdentityStore().name = name
                        pending = nil
                        showPIN = true
                    }.disabled(pairing || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text(status)
                }
            }
            .navigationTitle("Pair with a Mac")
            .toolbar { Button("Done") { dismiss() } }
        }
        .sheet(isPresented: $showPIN) {
            PINEntryView(phoneName: name) { peer in status = "Paired with \(peer.name)"; onPaired?(peer) }
        }
        .fullScreenCover(isPresented: $scanner) {
            ZStack(alignment: .topTrailing) {
                QRScannerView { text in
                    scanner = false
                    guard let url = URL(string: text), let payload = try? PairingPayload(url: url) else {
                        status = "This is not a valid Trackglass pairing code."; return
                    }
                    pending = payload
                    status = "Looking for the Mac’s pairing window…"
                    tryPair()
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

    private func tryPair() {
        guard !pairing, let payload = pending,
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
                status = "Paired with \(peer.name)"
                onPaired?(peer)
            } catch is CancellationError { status = "Pairing cancelled." }
            catch { status = error.localizedDescription }
        }
    }
}
