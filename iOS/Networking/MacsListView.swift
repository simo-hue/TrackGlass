import Observation
import SwiftUI
import TrackglassKit
import UIKit

struct MacsListView: View {
    @Bindable var state: ConnectionState
    let manager: ConnectionManager
    let connect: (DiscoveredMac) -> Void
    let pair: () -> Void
    @State private var error: String?
    var body: some View {
        ForEach(state.pairedMacs, id: \.peerID) { peer in
            let connected = state.connectedPeerID == peer.peerID
            let available = state.macs.first { !$0.isPairing && $0.peerID == peer.peerID }
            HStack {
                VStack(alignment: .leading) {
                    Text(peer.name)
                    Text(connected ? "Connected" : available != nil ? "Available" : "Not nearby")
                        .font(.caption).foregroundStyle(connected ? Color.accentColor : Color.secondary)
                }
                Spacer()
                if connected {
                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                }
                Menu {
                    Button("Connect") { if let available { connect(available) } }
                        .disabled(connected || available == nil)
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

/// Size limits for the overlays hosted over the surface, set by the surface controller from its bounds. Hosting
/// views size themselves from their content's ideal size, so the content is laid out at an explicit width: wrapped
/// text (large type sizes) then gets the right height. The No-Mac panel scrolls past `panelMaxHeight`.
@MainActor @Observable
final class OverlayLayout {
    private(set) var panelWidth: CGFloat = 320
    private(set) var panelMaxHeight: CGFloat = 600
    private(set) var statusWidth: CGFloat = 280

    /// `size`: the surface's width and its safe-area height.
    func update(size: CGSize) {
        let panelWidth = Self.panelWidth(forSurfaceWidth: size.width)
        let panelMaxHeight = max(160, size.height - 48)
        let statusWidth = max(120, size.width - 112)
        if panelWidth != self.panelWidth { self.panelWidth = panelWidth }
        if panelMaxHeight != self.panelMaxHeight { self.panelMaxHeight = panelMaxHeight }
        if statusWidth != self.statusWidth { self.statusWidth = statusWidth }
    }

    /// min(width − 48, 400): readable line length on iPad, a 24 pt margin on phones.
    nonisolated static func panelWidth(forSurfaceWidth width: CGFloat) -> CGFloat { max(200, min(width - 48, 400)) }
}

struct NoMacView: View {
    @Bindable var state: ConnectionState
    let layout: OverlayLayout
    /// Opens the pairing flow directly.
    let pair: () -> Void
    let connect: (DiscoveredMac) -> Void
    /// Re-arms automatic reconnection to the last Mac.
    let reconnect: () -> Void
    /// Tells the controller whether the panel takes touches (it does not while it only reports a reconnect).
    let interactiveChanged: (Bool) -> Void
    @Environment(\.openURL) private var openURL
    @State private var graceElapsed = false

    /// While something reconnects by itself the panel is a passive label for the first 3 s: a finger still moving
    /// on the surface must not land on its buttons during a brief drop.
    private var passive: Bool { state.isReconnecting && !graceElapsed }

    var body: some View {
        ZStack {
            if !state.isConnected {
                ViewThatFits(in: .vertical) {
                    content
                    ScrollView { content }
                }
                .padding(24)
                .frame(width: layout.panelWidth)
                .frame(maxHeight: layout.panelMaxHeight)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("noMacPanel")   // the soak test (M9.4) checks the session is still up
            }
        }
        .task(id: state.isReconnecting) {
            graceElapsed = false
            guard state.isReconnecting else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            graceElapsed = true
        }
        .onChange(of: !state.isConnected && !passive, initial: true) { _, interactive in interactiveChanged(interactive) }
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 14) {
            if passive {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(Self.headline(lastMacName: state.lastMacName, isReconnecting: true, passive: true)).font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            } else {
                Text(Self.headline(lastMacName: state.lastMacName, isReconnecting: state.isReconnecting, passive: false,
                                   lastMacListed: state.lastMacIsListed))
                    .font(.headline).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if state.localNetworkDenied {
                    Text("Local Network access is off").font(.subheadline.weight(.semibold))
                    Text("Trackglass needs it to find your Mac.").font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }.buttonStyle(.borderedProminent)
                } else if state.discoveryStatus == MacBrowser.noWiFiStatus {
                    Text(state.discoveryStatus).font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                // §8.10 / §3.2: the reason the last attempt ended ("<Mac> is being used by <phone>",
                // "Pair again", "Connection timed out") must be visible even with the HUD pill off.
                if let detail = ConnectionState.outcome(for: state.status, macName: state.macName) {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                // Pair again is offered even while the phone still retries: only pairing can fix a refused key (§3.2).
                if !state.lastMacName.isEmpty,
                   !state.isReconnecting || ConnectionState.panelAction(for: state.status) == .pair {
                    switch ConnectionState.panelAction(for: state.status) {
                    case .reconnect: Button("Reconnect", action: reconnect).buttonStyle(.borderedProminent)
                    case .pair: Button("Pair again", action: pair).buttonStyle(.borderedProminent)
                    case .nothing: EmptyView()
                    }
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
                Button("Pair a new Mac", action: pair)
            }
        }
    }

    /// "Reconnecting to X…" while a reconnect runs (passive) or the phone retries a Mac it can see, "Looking for X…"
    /// while it retries one that is not in range, "Not connected to X" when nothing retries.
    nonisolated static func headline(lastMacName: String, isReconnecting: Bool, passive: Bool,
                                     lastMacListed: Bool = false) -> String {
        guard !lastMacName.isEmpty else { return "No Mac connected" }
        if passive || (isReconnecting && lastMacListed) { return "Reconnecting to \(lastMacName)…" }
        return isReconnecting ? "Looking for \(lastMacName)…" : "Not connected to \(lastMacName)"
    }
}
