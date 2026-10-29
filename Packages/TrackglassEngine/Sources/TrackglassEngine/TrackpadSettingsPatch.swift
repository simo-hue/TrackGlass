import Foundation

/// A fixture's `settingsChanges` entry (§6.10): only the keys it names change, the others keep their current
/// values (decoding it as a whole `TrackpadSettings` would reset every unnamed key to its Appendix A default).
/// Used by `tgreplay` and the fixture tests; not on the frame path.
public struct TrackpadSettingsPatch: Decodable, Sendable {
    private let changes: [String: JSONValue]

    public init(from decoder: Decoder) throws {
        changes = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    public func applied(to current: TrackpadSettings) throws -> TrackpadSettings {
        var merged = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(current))
        for (key, value) in changes { merged[key] = value }
        return try JSONDecoder().decode(TrackpadSettings.self, from: JSONEncoder().encode(merged))
    }
}

private enum JSONValue: Codable, Sendable {
    case bool(Bool), number(Double), string(String), null, array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Integer values stay integers, so integer keys (doubleClickIntervalNs) decode from them.
            if value.rounded() == value, abs(value) < 9.0e15 { try container.encode(Int64(value)) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
