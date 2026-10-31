import SwiftUI
import TrackglassKit
import UIKit

/// §3.4 code pairing (2026-10-31): the user taps a Mac whose pairing window is in code mode, both screens show the same
/// six-digit code, and pairing completes only when the user confirms it here and clicks Allow on the Mac. Nothing is
/// chosen or submitted automatically.
struct CodePairingView: View {
    let phoneName: String
    var paired: (PairedPeer) -> Void
    @State private var browser = MacBrowser()
    @State private var client = PairingClient()
    /// The Bonjour instance being paired with, while an attempt runs.
    @State private var activeInstance: String?
    /// The comparison code once the Mac's commitment checked out.
    @State private var code: String?
    /// The user tapped Matches; the Mac's Allow is still outstanding.
    @State private var confirmed = false
    @State private var status = "On the Mac, open Pair a device and click “Use a code instead”, then choose the Mac here."
    @State private var exchange: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let code {
                    comparison(code)
                } else {
                    Section("Macs ready to pair") {
                        ForEach(browser.macs.filter(\.isPairing)) { mac in
                            Button { start(mac) } label: {
                                HStack {
                                    Text(PairingText.sanitizedName(mac.name))
                                    Spacer()
                                    if activeInstance == mac.instanceName { ProgressView().accessibilityLabel("Connecting") }
                                }
                            }
                            .disabled(activeInstance != nil)
                        }
                        if !browser.macs.contains(where: \.isPairing) { Text(browser.status) }
                    }
                }
                Section { Text(status) }
            }
            .navigationTitle("Pair with a code")
            .toolbar { Button("Done") { dismiss() } }
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop(); exchange?.cancel(); client.cancel() }
    }

    private func comparison(_ code: String) -> some View {
        Section {
            VStack(spacing: 12) {
                Text("Does your Mac show this code?").font(.headline)
                Text(PairingText.formattedCode(code))
                    .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                    .accessibilityLabel("Code \(PairingText.spokenCode(code))")
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            if confirmed {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Click Allow on the Mac.")
                }
            } else {
                Button("Matches") {
                    confirmed = true
                    status = "Waiting for the Mac. Click Allow there if it shows the same code."
                    client.confirmCode(matches: true)
                }
                Button("Doesn't match", role: .destructive) { client.confirmCode(matches: false) }
            }
        }
    }

    private func start(_ mac: DiscoveredMac) {
        guard activeInstance == nil, let pairID = mac.pairID else { return }
        activeInstance = mac.instanceName
        code = nil
        confirmed = false
        status = "Connecting to “\(PairingText.sanitizedName(mac.name))”…"
        let identity = PhoneIdentityStore()
        identity.name = phoneName
        let request = PairRequestMessage(peerID: identity.peerID, name: phoneName,
                                         modelIdentifier: PhoneIdentityStore.modelIdentifier(), protocolVersion: MessageHeader.protocolVersion)
        exchange = Task {
            defer { activeInstance = nil; code = nil; confirmed = false }
            do {
                let peer = try await client.pair(codeWithPairID: pairID, endpoint: mac.endpoint, expectedMacID: mac.peerID,
                                                 request: request) { shown in
                    code = shown
                    status = "Compare this code with the one on the Mac."
                    UIAccessibility.post(notification: .announcement,
                                         argument: "Code \(PairingText.spokenCode(shown)). Does your Mac show this code?")
                }
                status = "Paired with \(peer.name)"
                OnboardingProgress.markCompleted()
                paired(peer)
                dismiss()
            } catch is CancellationError { status = "Pairing cancelled." }
            catch PairingClient.Failure.declined {
                // Don't Allow on the Mac (BYE{0}); its window stays open while attempts remain.
                status = "The Mac did not allow pairing. Check that both screens show the same code, then choose the Mac again."
            }
            catch { status = error.localizedDescription }
        }
    }
}
