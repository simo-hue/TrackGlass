import SwiftUI
import TrackglassKit
import UIKit

struct PINEntryView: View {
    let phoneName: String
    var paired: (PairedPeer) -> Void
    @State private var browser = MacBrowser()
    @State private var client = PairingClient()
    @State private var selectedInstance: String?
    /// The pairing session of the selected Mac when it was chosen: a different one later means the Mac showed a new code.
    @State private var selectedPairID: Data?
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
                            // A code typed before choosing stays: it is the one this Mac shows, so it submits now.
                            select(mac)
                            autoSubmitIfComplete()
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
                    // The code is shown on the Mac's screen anyway: a plain field lets the user check what they typed.
                    TextField("Pairing code", text: $pin, prompt: Text("000000"))
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.title2.monospacedDigit())
                        .disabled(inProgress)
                        .accessibilityLabel("Pairing code")
                        .onChange(of: pin) { _, value in
                            let digits = Self.sanitized(value)
                            if digits != value { pin = digits; return }
                            autoSubmitIfComplete()
                        }
                    Button("Pair") { submit() }
                        .disabled(inProgress || selectedMac == nil || !validPIN)
                    Text(status)
                }
            }
            .navigationTitle("Pair using a code")
            .toolbar { Button("Done") { dismiss() } }
        }
        .onAppear { browser.start() }
        .onChange(of: selectedMac?.pairID) { _, newValue in
            // Choosing another Mac updates `selectedPairID` first, so only a new code on the same Mac lands here.
            guard let newValue, let previous = selectedPairID, newValue != previous else { return }
            selectedPairID = newValue
            pin = ""
            status = "The Mac’s code changed. Enter the new code."
        }
        .onDisappear { browser.stop(); exchange?.cancel(); client.cancel() }
    }

    /// Digits only, at most six (paste and one-time-code autofill can bring anything).
    nonisolated static func sanitized(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber }.prefix(6))
    }

    /// The sixth digit submits; with a single Mac ready to pair, that Mac is the one meant.
    private func autoSubmitIfComplete() {
        guard validPIN, !inProgress else { return }
        if selectedMac == nil {
            let ready = browser.macs.filter(\.isPairing)
            guard ready.count == 1 else { status = "Choose the Mac showing this code."; return }
            select(ready[0])
        }
        submit()
    }

    private func select(_ mac: DiscoveredMac) {
        selectedPairID = mac.pairID
        selectedInstance = mac.instanceName
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
                OnboardingProgress.markCompleted()
                paired(peer)
                dismiss()
            } catch is CancellationError { status = "Pairing cancelled." }
            catch let failure as PairingClient.Failure {
                // A wrong code fails the TLS handshake (a network error); every other outcome has its own message.
                if case .network = failure { status = "Pairing failed. Check the new code on the Mac and try again." }
                else { status = failure.localizedDescription }
            }
            catch { status = "Pairing failed. Check the new code on the Mac and try again." }
        }
    }
}
