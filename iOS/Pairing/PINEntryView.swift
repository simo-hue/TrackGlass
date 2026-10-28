import SwiftUI
import TrackglassKit

struct PINEntryView: View {
    let phoneName: String
    var paired: (PairedPeer) -> Void
    @State private var browser = MacBrowser()
    @State private var client = PairingClient()
    @State private var selectedInstance: String?
    @State private var pin = ""
    @State private var status = "Choose a Mac showing a pairing code."
    @State private var inProgress = false
    @State private var exchange: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    private var selectedMac: DiscoveredMac? {
        browser.macs.first { $0.isPairing && $0.instanceName == selectedInstance }
    }
    private var validPIN: Bool { pin.utf8.count == 6 && pin.utf8.allSatisfy { (48...57).contains($0) } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Macs ready to pair") {
                    ForEach(browser.macs.filter(\.isPairing)) { mac in
                        Button {
                            selectedInstance = mac.instanceName
                            pin = ""
                        } label: {
                            HStack {
                                Text(mac.name)
                                Spacer()
                                if selectedInstance == mac.instanceName { Image(systemName: "checkmark").accessibilityHidden(true) }
                            }
                        }
                        .disabled(inProgress)
                        .accessibilityAddTraits(selectedInstance == mac.instanceName ? .isSelected : [])
                    }
                    if !browser.macs.contains(where: \.isPairing) { Text(browser.status) }
                }
                Section("Six-digit code") {
                    SecureField("000000", text: $pin).keyboardType(.numberPad).disabled(inProgress)
                    Button("Pair") { submit() }
                        .disabled(inProgress || selectedMac == nil || !validPIN)
                    Text(status)
                }
            }
            .navigationTitle("Pair using a code")
            .toolbar { Button("Done") { dismiss() } }
        }
        .onAppear { browser.start() }
        .onChange(of: selectedMac?.pairID) { oldValue, newValue in
            if oldValue != nil && oldValue != newValue {
                pin = ""
                status = "The Mac’s code changed. Enter the new code."
            }
        }
        .onDisappear { browser.stop(); exchange?.cancel(); client.cancel() }
    }

    private func submit() {
        guard let mac = selectedMac, let pairID = mac.pairID, validPIN, !inProgress else { return }
        let enteredPIN = pin
        pin = ""
        inProgress = true
        status = "Pairing… Click Allow on the Mac when it asks."
        let identity = PhoneIdentityStore()
        identity.name = phoneName
        let request = PairRequestMessage(peerID: identity.peerID, name: phoneName,
                                         modelIdentifier: PhoneIdentityStore.modelIdentifier(), protocolVersion: MessageHeader.protocolVersion)
        exchange = Task {
            defer { inProgress = false }
            do {
                let peer = try await client.pair(pin: enteredPIN, pairID: pairID, endpoint: mac.endpoint,
                                                expectedMacID: mac.peerID, request: request)
                status = "Paired with \(peer.name)"
                paired(peer)
            } catch is CancellationError { status = "Pairing cancelled." }
            catch PairingClient.Failure.declined { status = PairingClient.Failure.declined.localizedDescription }
            catch { status = "Pairing failed. Check the new code on the Mac and try again." }
        }
    }
}
