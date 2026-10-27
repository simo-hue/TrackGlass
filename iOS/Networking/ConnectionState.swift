import Observation
import TrackglassKit

@MainActor @Observable
final class ConnectionState {
    var notice: String?
    var onSessionChange: (() -> Void)?
    var onTapToClickDisabled: (() -> Void)?
    private(set) var isConnected = false
    private(set) var status = "No Mac connected"
    private(set) var macName = ""
    private(set) var rttMicros: UInt32 = 0
    private(set) var diagnostics: StatusMessage?
    private(set) var latencySamples: [Double] = []
    private var diagnosticsSequence: UInt64 = 0
    private(set) var settings: SettingsMessage?
    private(set) var macs: [DiscoveredMac] = []
    private(set) var pairedMacs: [PairedPeer] = []
    /// The Mac the app connects to automatically (§3.5 "last used Mac"); drives the `.noMac` overlay text.
    private(set) var lastMacName = ""

    func updateSession(isConnected: Bool, status: String, macName: String, rttMicros: UInt32,
                       settings: SettingsMessage?, diagnostics: StatusMessage? = nil, diagnosticsSequence: UInt64 = 0) {
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
        if isConnected, settings?.tapToClick == 0 { onTapToClickDisabled?() }
        onSessionChange?()
    }

    func updateDiscovery(macs: [DiscoveredMac], pairedMacs: [PairedPeer]) {
        self.macs = macs
        self.pairedMacs = pairedMacs
    }

    func updateLastMac(name: String) { lastMacName = name }
}
