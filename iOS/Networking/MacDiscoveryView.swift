import SwiftUI
import TrackglassKit

struct MacDiscoveryView: View {
    @Bindable var state: ConnectionState
    let manager: ConnectionManager
    var connect: (DiscoveredMac) -> Void
    @Bindable var links: PairingLinkRouter
    @Environment(\.dismiss) private var dismiss
    @State private var justPaired: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(state.status)
                    if state.isConnected {
                        Text("RTT \(Double(state.rttMicros) / 1_000, specifier: "%.1f") ms")
                        Button("Disconnect") { Task { await manager.disconnect() } }
                    }
                    Button("Pair with a Mac…") { links.showPairing() }
                }
                Section("Paired Macs") {
                    MacsListView(state: state, manager: manager, connect: connect, pair: { links.showPairing() })
                }
                if state.macs.isEmpty {
                    Text(state.discoveryStatus)
                    if state.discoveryStatus.hasPrefix("Discovery waiting") || state.discoveryStatus.hasPrefix("Discovery failed") {
                        Text("Allow Local Network access for Trackglass in Settings → Privacy & Security → Local Network.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Macs")
            .toolbar { Button("Done") { dismiss() } }
        }
        .sheet(item: $links.presentation, onDismiss: {
            Task {
                await manager.refreshPairedMacs()
                // A freshly paired Mac becomes the connection target as soon as its session service shows up.
                guard let peerID = justPaired else { return }
                justPaired = nil
                for _ in 0..<15 {
                    if let mac = state.macs.first(where: { !$0.isPairing && $0.peerID == peerID }) {
                        connect(mac); dismiss(); return
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }) { item in
            PairingFlowView(payload: item.payload) { justPaired = $0.peerID }
        }
        .onAppear { Task { await manager.startDiscovery(); await manager.refreshPairedMacs() } }
    }
}
