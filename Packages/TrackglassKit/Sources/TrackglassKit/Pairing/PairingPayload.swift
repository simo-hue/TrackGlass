import Foundation

public enum PairingPayloadError: Error, Equatable, Sendable {
    case invalidURL
    case invalidVersion
    case invalidPairID
    case invalidSecret
}

public struct PairingPayload: Equatable, Sendable {
    public let pairID: Data
    public let pairSecret: Data
    public let macName: String
    public let bonjourInstanceName: String

    public init(pairID: Data, pairSecret: Data, macName: String, bonjourInstanceName: String) throws {
        guard pairID.count == 8 else { throw PairingPayloadError.invalidPairID }
        guard pairSecret.count == 32 else { throw PairingPayloadError.invalidSecret }
        self.pairID = pairID
        self.pairSecret = pairSecret
        self.macName = macName
        self.bonjourInstanceName = bonjourInstanceName
    }

    /// The TLS-PSK identity of both pairing paths (§3.4): the base64url `pairID`, as it appears in the QR URL
    /// `id=` item and the pairing listener's TXT `pid=`.
    public var identity: String { Self.identity(forPairID: pairID) }

    /// The PIN path has no secret and therefore no `PairingPayload`; it derives the same identity from the
    /// `pairID` alone, so the Mac (which registers `payload.identity`) and the phone agree by construction.
    public static func identity(forPairID pairID: Data) -> String { base64URL(pairID) }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "trackglass"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "id", value: identity),
            URLQueryItem(name: "s", value: Self.base64URL(pairSecret)),
            URLQueryItem(name: "n", value: macName),
            URLQueryItem(name: "h", value: bonjourInstanceName)
        ]
        return components.url!
    }

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "trackglass", components.host == "pair",
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty, components.fragment == nil,
              let items = components.queryItems else { throw PairingPayloadError.invalidURL }
        var values: [String: String] = [:]
        for item in items {
            guard let value = item.value, values[item.name] == nil else { throw PairingPayloadError.invalidURL }
            values[item.name] = value
        }
        guard values["v"] == "1" else { throw PairingPayloadError.invalidVersion }
        guard let id = values["id"], let pairID = Self.decodeBase64URL(id), pairID.count == 8 else {
            throw PairingPayloadError.invalidPairID
        }
        guard let secret = values["s"], let pairSecret = Self.decodeBase64URL(secret), pairSecret.count == 32 else {
            throw PairingPayloadError.invalidSecret
        }
        guard let name = values["n"], let host = values["h"] else { throw PairingPayloadError.invalidURL }
        try self.init(pairID: pairID, pairSecret: pairSecret, macName: name, bonjourInstanceName: host)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ string: String) -> Data? {
        guard !string.isEmpty,
              string.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        let base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)),
              Self.base64URL(data) == string else { return nil }
        return data
    }
}
