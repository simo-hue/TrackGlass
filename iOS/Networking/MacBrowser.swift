import Foundation
import Network
import Observation

struct DiscoveredMac: Identifiable, Sendable {
    var id: String { instanceName }
    let peerID: UUID
    let name: String
    let instanceName: String
    let endpoint: NWEndpoint
    let isPairing: Bool
    let pairID: Data?

    init?(endpoint: NWEndpoint, txt: NWTXTRecord) {
        guard case let .service(instance, _, _, _) = endpoint,
              Self.string("v", in: txt) == "1",
              let idText = Self.string("id", in: txt), let peerID = UUID(uuidString: idText),
              let name = Self.string("nm", in: txt),
              let pairing = Self.string("pr", in: txt), pairing == "0" || pairing == "1" else { return nil }
        let pairID = Self.string("pid", in: txt).flatMap(Self.decodePairID)
        guard pairing != "1" || pairID != nil else { return nil }
        self.peerID = peerID
        self.name = name
        instanceName = instance
        self.endpoint = endpoint
        isPairing = pairing == "1"
        self.pairID = pairID
    }

    private static func decodePairID(_ text: String) -> Data? {
        guard text.count == 11,
              text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        let base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: base64 + "="), data.count == 8,
              data.base64EncodedString() == base64 + "=" else { return nil }
        return data
    }

    private static func string(_ key: String, in txt: NWTXTRecord) -> String? {
        guard let data = txt.getEntry(for: key)?.data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

@MainActor @Observable
final class MacBrowser {
    private(set) var macs: [DiscoveredMac] = []
    private(set) var status = "Looking for Macs…"
    /// The browser is blocked by the Local Network privacy setting (DNS-SD `kDNSServiceErr_PolicyDenied`).
    private(set) var localNetworkDenied = false
    private var browser: NWBrowser?
    /// Results kept across `pause()` until the new browser has had a chance to report (see `start()`).
    private var resultsAreStale = false
    private var onChange: (@MainActor @Sendable () -> Void)?

    func setOnChange(_ handler: (@MainActor @Sendable () -> Void)?) { onChange = handler }

    /// True between `start()` and `stop()`/`pause()`; a restart after a failure only happens while the owner still wants
    /// results (the failure path keeps it set and restarts after its own 1 s delay).
    private var running = false
    /// Identifies the `start()` a stale-results timer belongs to, so an older timer never clears a newer list.
    private var staleGeneration = 0

    /// Starts browsing if it is not wanted already; a browser that failed restarts on its own schedule.
    func resume() {
        guard !running else { return }
        start()
    }

    func start() {
        running = true
        guard browser == nil else { return }
        if !macs.isEmpty {
            // Results kept by `pause()` let a reconnect start at once; drop them if the new browser stays silent
            // (no callback is made for an empty result set), so a Mac that left is not listed forever.
            resultsAreStale = true
            staleGeneration &+= 1
            let generation = staleGeneration
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.staleGeneration == generation, self.resultsAreStale, self.browser != nil else { return }
                self.resultsAreStale = false
                self.macs = []
                self.onChange?()
            }
        }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.prohibitedInterfaceTypes = [.cellular]
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_trackglass._tcp", domain: nil), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            let macs = results.compactMap { result -> DiscoveredMac? in
                guard case let .bonjour(txt) = result.metadata else { return nil }
                return DiscoveredMac(endpoint: result.endpoint, txt: txt)
            }
            Task { @MainActor in
                guard let self, let browser, self.browser === browser else { return }
                self.resultsAreStale = false
                var byInstance: [String: DiscoveredMac] = [:]
                for mac in macs { byInstance[mac.instanceName] = mac }
                self.macs = byInstance.values.sorted { $0.instanceName < $1.instanceName }
                self.onChange?()
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            Task { @MainActor in
                guard let self, let browser, self.browser === browser else { return }
                switch state {
                case .ready:
                    self.status = "Looking for Macs…"; self.localNetworkDenied = false
                case .waiting(let error):
                    self.localNetworkDenied = Self.isLocalNetworkDenial(error)
                    self.status = Self.waitingStatus(for: error)
                case .failed(let error):
                    self.localNetworkDenied = Self.isLocalNetworkDenial(error)
                    self.status = self.localNetworkDenied ? Self.waitingStatus(for: error)
                        : "Discovery failed: \(error.localizedDescription)"
                    self.restartAfterFailure(browser)
                default: return
                }
                self.onChange?()   // the status is user-visible (Local Network denial); publish it like a result change
            }
        }
        browser.start(queue: .main)
    }

    func stop() {
        pause()
        macs = []
    }

    /// Stops browsing (no multicast traffic while a session is up) but keeps the last results, so the reconnect
    /// loop can try the Mac at once when the session drops and `start()` is called again.
    func pause() {
        running = false
        resultsAreStale = false
        browser?.cancel()
        browser = nil
    }

    /// `kDNSServiceErr_PolicyDenied`: the user turned Local Network access off for Trackglass.
    nonisolated static func isLocalNetworkDenial(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return Int(code) == -65570 }
        return false
    }

    nonisolated static let localNetworkOffStatus = "Local Network access is off"
    nonisolated static let noWiFiStatus = "Connect to Wi-Fi to find your Mac"

    /// `.waiting` other than a privacy denial means there is no usable network (no Wi-Fi) for Bonjour.
    nonisolated static func waitingStatus(for error: NWError) -> String {
        isLocalNetworkDenial(error) ? localNetworkOffStatus : noWiFiStatus
    }

    /// `.failed` is terminal for an `NWBrowser` (e.g. its DNS-SD connection went defunct while the app was
    /// suspended): replace it, or nothing new would ever be discovered until the app is relaunched. The last
    /// results stay listed until the new browser reports.
    private func restartAfterFailure(_ failed: NWBrowser) {
        failed.cancel()
        browser = nil
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.running, self.browser == nil else { return }
            self.start()
        }
    }
}
