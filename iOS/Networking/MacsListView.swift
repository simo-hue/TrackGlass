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
                // §8.10 / §3.2: the reason the last attempt ended ("<Mac> is being used by <phone>",
                // "Pair again", "Connection timed out") must be visible even with the HUD pill off.
                if let detail = Self.detail(from: state.status) {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                // §5.1: every other paired Mac is offered; the ones not in range are listed but inert,
                // so the user sees what the phone knows and can tell "not paired" from "not nearby".
                ForEach(state.pairedMacs, id: \.peerID) { peer in
                    if let mac = state.macs.first(where: { !$0.isPairing && $0.peerID == peer.peerID }) {
                        Button("Connect to \(peer.name)") { connect(mac) }
                    } else {
                        Text("\(peer.name) · not nearby").foregroundStyle(.secondary)
                            .accessibilityLabel("\(peer.name), not nearby")
                    }
                }
                Button("Pair a new Mac", action: open)
            }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    /// Only outcomes are shown; the routine "No Mac connected"/"Connecting to…" states would just repeat the headline.
    static func detail(from status: String) -> String? {
        guard !status.isEmpty, status != "No Mac connected", status != "Disconnected",
              !status.hasPrefix("Connecting to"), !status.hasPrefix("Connected to") else { return nil }
        return status
    }
}
