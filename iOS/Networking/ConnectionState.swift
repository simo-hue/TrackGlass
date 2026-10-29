import Foundation
import Observation
import TrackglassKit

@MainActor @Observable
final class ConnectionState {
    var notice: String?
    var onSessionChange: (() -> Void)?
    var onTapToClickDisabled: (() -> Void)?
    /// VoiceOver announcements for connection changes and final outcomes (the VC posts them).
    var onAnnouncement: ((String) -> Void)?
    private(set) var isConnected = false
    private(set) var status = "No Mac connected"
    private(set) var macName = ""
    private(set) var rttMicros: UInt32 = 0
    private(set) var diagnostics: StatusMessage?
    private(set) var latencySamples: [Double] = []
    private var diagnosticsSequence: UInt64 = 0
    private(set) var settings: SettingsMessage?
    /// §5.5: which injector the connected Mac runs (1 Quartz, 2 driver); 0 while disconnected.
    private(set) var injectorMode: UInt8 = 0
    private(set) var macs: [DiscoveredMac] = []
    private(set) var pairedMacs: [PairedPeer] = []
    /// The Mac the app connects to automatically (§3.5 "last used Mac"); drives the `.noMac` overlay text.
    private(set) var lastMacName = ""
    /// Something is (re)connecting by itself: the No-Mac panel shows a passive label instead of buttons a finger
    /// still on the surface could hit.
    private(set) var isReconnecting = false
    /// The Mac the session is connected to; the Macs lists mark it and disable its Connect.
    private(set) var connectedPeerID: UUID?
    /// Discovery is blocked because Local Network access is off for Trackglass.
    private(set) var localNetworkDenied = false

    private var appliedSnapshot: UInt64 = 0

    /// Applies a session snapshot unless an older one arrives after a newer one was already applied.
    func apply(_ snapshot: SessionClient.Snapshot, isReconnecting: Bool = false) {
        guard snapshot.sequence > appliedSnapshot else { return }
        appliedSnapshot = snapshot.sequence
        let wasReconnecting = self.isReconnecting
        self.isReconnecting = isReconnecting && !snapshot.isConnected
        updateSession(wasReconnecting: wasReconnecting,
                      isConnected: snapshot.isConnected, status: snapshot.status, macName: snapshot.macName,
                      rttMicros: snapshot.rttMicros, settings: snapshot.settings,
                      diagnostics: snapshot.diagnostics, diagnosticsSequence: snapshot.diagnosticsSequence,
                      injectorMode: snapshot.injectorMode, connectedPeerID: snapshot.connectedPeerID)
    }

    func updateSession(wasReconnecting: Bool? = nil, isConnected: Bool, status: String, macName: String, rttMicros: UInt32,
                       settings: SettingsMessage?, diagnostics: StatusMessage? = nil, diagnosticsSequence: UInt64 = 0,
                       injectorMode: UInt8 = 0, connectedPeerID: UUID? = nil) {
        let wasConnected = self.isConnected
        let previousStatus = self.status
        let previousMac = self.macName
        self.injectorMode = isConnected ? injectorMode : 0
        self.connectedPeerID = isConnected ? connectedPeerID : nil
        self.diagnostics = diagnostics
        if self.diagnosticsSequence != diagnosticsSequence, diagnostics != nil {
            self.diagnosticsSequence = diagnosticsSequence
            if latencySamples.count == 120 { latencySamples.removeFirst() }
            latencySamples.append(Double(rttMicros) / 1_000)
        }
        if !isConnected { latencySamples.removeAll(keepingCapacity: true) }
        self.isConnected = isConnected
        self.status = status
        self.macName = macName
        self.rttMicros = rttMicros
        self.settings = settings
        if let text = Self.announcement(wasConnected: wasConnected, isConnected: isConnected,
                                        previousStatus: previousStatus, status: status,
                                        macName: macName.isEmpty ? previousMac : macName,
                                        wasReconnecting: wasReconnecting ?? isReconnecting, isReconnecting: isReconnecting) {
            onAnnouncement?(text)
        }
        if isConnected, settings?.tapToClick == 0 { onTapToClickDisabled?() }
        onSessionChange?()
    }

    /// Browser state text ("Looking for Macs…", or why discovery is blocked, e.g. Local Network denied).
    private(set) var discoveryStatus = "Looking for Macs…"

    func updateDiscovery(macs: [DiscoveredMac], pairedMacs: [PairedPeer], status: String? = nil,
                         localNetworkDenied: Bool? = nil) {
        self.macs = macs
        self.pairedMacs = pairedMacs
        if let status { discoveryStatus = status }
        if let localNetworkDenied { self.localNetworkDenied = localNetworkDenied }
    }

    func updateLastMac(name: String) { lastMacName = name }
    func showNotice(_ text: String) { notice = text }

    /// The status line shown by the HUD pill: the notice, else "<Mac> · <one-way> ms" once a round trip has been
    /// measured ("—" before), else the session status.
    var pillText: String {
        if let notice { return notice }
        guard isConnected else { return status }
        return "\(macName) · \(Self.latencyText(rttMicros: rttMicros))"
    }

    /// The trackpad's VoiceOver value: what the surface is controlling right now.
    var accessibilityStatus: String {
        if isConnected { return "Connected to \(macName)" }
        if lastMacName.isEmpty { return "No Mac connected" }
        return isReconnecting ? "Reconnecting to \(lastMacName)" : "Not connected to \(lastMacName)"
    }

    nonisolated static func latencyText(rttMicros: UInt32) -> String {
        rttMicros > 0 ? "\(String(format: "%.1f", Double(rttMicros) / 2_000)) ms" : "—"
    }

    /// What VoiceOver hears when the session changes: connects and drops always, a final outcome once — when
    /// nothing retries any more (§8.10). Attempts made while reconnecting stay silent.
    nonisolated static func announcement(wasConnected: Bool, isConnected: Bool, previousStatus: String, status: String,
                                         macName: String, wasReconnecting: Bool, isReconnecting: Bool) -> String? {
        let name = macName.isEmpty ? "the Mac" : macName
        if isConnected { return wasConnected ? nil : "Connected to \(name)" }
        if wasConnected {
            if isReconnecting { return "Connection to \(name) lost. Reconnecting." }
            guard let outcome = outcome(for: status, macName: macName) else { return "Disconnected from \(name)" }
            return "Disconnected from \(name). \(outcome)"
        }
        guard !isReconnecting, status != previousStatus || wasReconnecting else { return nil }
        return outcome(for: status, macName: macName)
    }

    /// The reason a session ended, as something the user can act on; nil for routine states that would only repeat
    /// the panel's headline ("No Mac connected", "Connecting to…").
    nonisolated static func outcome(for status: String, macName: String) -> String? {
        let mac = macName.isEmpty ? "The Mac" : macName
        switch status {
        case "", "No Mac connected", "Disconnected": return nil
        case _ where status.hasPrefix("Connecting to") || status.hasPrefix("Connected to"): return nil
        case ControlCloseMessage.incompatible:
            return "This version of Trackglass doesn't match the one on \(mac). Update both apps, then reconnect."
        case "Invalid control message":
            return "\(mac) sent something this version can't read. Update Trackglass on both devices."
        case ControlCloseMessage.pairAgain:
            return "\(mac) no longer recognizes this device. Pair again to reconnect."
        case "Input path lost", "Input connection failed", "Input connection stalled", "Mac input service not found":
            return "Touches couldn't reach \(mac). Make sure both devices are on the same Wi-Fi network, then reconnect."
        case "The Mac went to sleep":
            return "\(mac) went to sleep. Wake it to reconnect."
        case ControlCloseMessage.disconnectedOnMac:
            return "\(mac) disconnected this device. Tap Reconnect to use it again."
        case "The Mac is busy":
            return "\(mac) is in use by another device. Disconnect it there, then reconnect."
        case "Connection timed out":
            return "\(mac) didn't answer. Check that Trackglass is running on it and both devices are on the same network."
        case _ where status.contains(" is being used by "):
            return "\(status). Disconnect it there, then reconnect."
        default: return status
        }
    }

    /// The panel's one button for an outcome: pairing for a Mac that forgot this phone, nothing for a version
    /// mismatch (retrying cannot help), Reconnect otherwise.
    enum PanelAction: Equatable { case reconnect, pair, nothing }

    nonisolated static func panelAction(for status: String) -> PanelAction {
        switch status {
        case ControlCloseMessage.pairAgain: return .pair
        case ControlCloseMessage.incompatible, "Invalid control message": return .nothing
        default: return .reconnect
        }
    }
}
