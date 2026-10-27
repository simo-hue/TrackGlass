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
    private var browser: NWBrowser?
    private var onChange: (@MainActor @Sendable () -> Void)?

    func setOnChange(_ handler: (@MainActor @Sendable () -> Void)?) { onChange = handler }

    func start() {
        guard browser == nil else { return }
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
                case .ready: self.status = "Looking for Macs…"
                case .waiting(let error): self.status = "Discovery waiting: \(error.localizedDescription)"
                case .failed(let error): self.status = "Discovery failed: \(error.localizedDescription)"
                default: return
                }
                self.onChange?()   // the status is user-visible (Local Network denial); publish it like a result change
            }
        }
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        macs = []
    }
}
