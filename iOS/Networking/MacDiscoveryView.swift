import SwiftUI
import TrackglassKit

struct MacDiscoveryView: View {
    @Bindable var state: ConnectionState
    let manager: ConnectionManager
    var connect: (DiscoveredMac) -> Void
    @Bindable var links: PairingLinkRouter
    @Environment(\.dismiss) private var dismiss

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
        .sheet(item: $links.presentation, onDismiss: { Task { await manager.refreshPairedMacs() } }) { item in
            PairingFlowView(payload: item.payload)
        }
        .onAppear { Task { await manager.startDiscovery(); await manager.refreshPairedMacs() } }
    }
}
