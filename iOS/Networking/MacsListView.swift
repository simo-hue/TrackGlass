import SwiftUI
import TrackglassKit

struct MacsListView: View {
    @Bindable var state: ConnectionState
    let manager: ConnectionManager
    let connect: (DiscoveredMac) -> Void
    let pair: () -> Void
    @State private var error: String?
    var body: some View {
        ForEach(state.pairedMacs, id: \.peerID) { peer in
            HStack {
                VStack(alignment: .leading) {
                    Text(peer.name)
                    Text(state.macs.contains { !$0.isPairing && $0.peerID == peer.peerID } ? "Available" : "Not nearby")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Connect") {
                        if let mac = state.macs.first(where: { !$0.isPairing && $0.peerID == peer.peerID }) { connect(mac) }
                    }.disabled(!state.macs.contains { !$0.isPairing && $0.peerID == peer.peerID })
                    Button("Forget", role: .destructive) {
                        Task { do { try await manager.forget(peer.peerID) } catch { self.error = error.localizedDescription } }
                    }
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Options for \(peer.name)") }
            }
        }
        Button("Pair a new Mac", action: pair)
            .alert("Cannot forget Mac", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }
}

struct NoMacView: View {
    @Bindable var state: ConnectionState
    let open: () -> Void
    let connect: (DiscoveredMac) -> Void
    var body: some View {
        if !state.isConnected {
            VStack(spacing: 14) {
                Text(state.lastMacName.isEmpty ? "No Mac connected" : "Looking for \(state.lastMacName)…").font(.headline)
                ForEach(state.pairedMacs, id: \.peerID) { peer in
                    if let mac = state.macs.first(where: { !$0.isPairing && $0.peerID == peer.peerID }) {
                        Button("Connect to \(peer.name)") { connect(mac) }
                    }
                }
                Button("Pair a new Mac", action: open)
            }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}
