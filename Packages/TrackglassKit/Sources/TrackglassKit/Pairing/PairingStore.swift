import Foundation
import Security

public struct PairedPeer: Equatable, Sendable {
    public let peerID: UUID
    public let ltk: Data
    public let name: String
    public let pairedAt: Date

    public init(peerID: UUID, ltk: Data, name: String, pairedAt: Date = Date()) {
        self.peerID = peerID
        self.ltk = ltk
        self.name = name
        self.pairedAt = pairedAt
    }
}

public enum PairingStoreError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case invalidRecord
}

public struct PairingStore: Sendable {
    public let service: String

    public init(service: String = "app.trackglass.pairing") { self.service = service }

    public func save(_ peer: PairedPeer) throws {
        guard peer.ltk.count == 32 else { throw PairingStoreError.invalidRecord }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Value(ltk: peer.ltk, name: peer.name, pairedAt: peer.pairedAt))
        var item = query(peerID: peer.peerID)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = data
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data,
                                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            try check(SecItemUpdate(query(peerID: peer.peerID) as CFDictionary, update as CFDictionary))
        } else {
            try check(status)
        }
    }

    public func load(peerID: UUID) throws -> PairedPeer? {
        var item = query(peerID: peerID)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw PairingStoreError.invalidRecord }
        return try decode(data, peerID: peerID)
    }

    public func all() throws -> [PairedPeer] {
        var item = query()
        item[kSecReturnAttributes as String] = true
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)
        guard let entries = result as? [[String: Any]] else { throw PairingStoreError.invalidRecord }
        return try entries.map { entry in
            guard let account = entry[kSecAttrAccount as String] as? String,
                  let id = UUID(uuidString: account),
                  let data = entry[kSecValueData as String] as? Data else { throw PairingStoreError.invalidRecord }
            return try decode(data, peerID: id)
        }.sorted { $0.peerID.uuidString < $1.peerID.uuidString }
    }

    public func delete(peerID: UUID) throws {
        let status = SecItemDelete(query(peerID: peerID) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func query(peerID: UUID? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrSynchronizable as String: false]
        if let peerID { query[kSecAttrAccount as String] = peerID.uuidString.lowercased() }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private func decode(_ data: Data, peerID: UUID) throws -> PairedPeer {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(Value.self, from: data), value.ltk.count == 32 else {
            throw PairingStoreError.invalidRecord
        }
        return PairedPeer(peerID: peerID, ltk: value.ltk, name: value.name, pairedAt: value.pairedAt)
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw PairingStoreError.keychain(status) }
    }

    private struct Value: Codable {
        let ltk: Data
        let name: String
        let pairedAt: Date
    }
}
