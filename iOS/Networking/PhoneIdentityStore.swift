import Foundation
import Darwin
import OSLog
import Security
import TrackglassKit

/// Where the phone's `peerID` is kept (§3.2).
protocol PeerIDStorage {
    func load() throws -> UUID?
    func save(_ id: UUID) throws
}

/// §3.2 (L7, 2026-10-31): the phone's `peerID` lives in the Keychain, this device only and never synced, so a backup
/// restored onto another phone does not clone the identity (two phones with one ID overwrite each other's key on the
/// Mac). Like the pairing records, the item outlives a reinstall, so the identity and its pairings stay together.
struct KeychainPeerIDStorage: PeerIDStorage {
    let service: String
    private static let account = "peerID"

    init(service: String = "app.trackglass.identity") { self.service = service }

    func load() throws -> UUID? {
        var item = query()
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PairingStoreError.keychain(status) }
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8),
              let id = UUID(uuidString: text) else { throw PairingStoreError.invalidRecord }
        return id
    }

    func save(_ id: UUID) throws {
        let data = Data(id.uuidString.utf8)
        var item = query()
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = data
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data,
                                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            status = SecItemUpdate(query() as CFDictionary, update as CFDictionary)
        }
        guard status == errSecSuccess else { throw PairingStoreError.keychain(status) }
    }

    private func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: Self.account,
         kSecAttrSynchronizable as String: false]
    }
}

@MainActor
final class PhoneIdentityStore {
    let peerID: UUID
    private let defaults: UserDefaults
    /// Where versions before 2026-10-31 kept the `peerID`; read once to move it into the Keychain.
    static let legacyPeerIDKey = "peerID"
    /// Set once the identity is known to live in the Keychain: a later failed read is then transient, never a reason to
    /// mint (and persist) another identity, which would break every pairing.
    static let keychainFlagKey = "peerIDInKeychain"
    private static let logger = Logger(subsystem: "app.trackglass", category: "identity")
    /// One identity per process for the Keychain-backed stores: HELLO, PAIR_REQUEST and the views each create a store,
    /// and they must all present the same ID even if the Keychain becomes readable between two of them.
    private static var processPeerID: UUID?

    var name: String {
        get { defaults.string(forKey: "peerName") ?? "iPhone" }
        set { defaults.set(newValue, forKey: "peerName") }
    }

    init(defaults: UserDefaults = .standard, modelIdentifier: String = PhoneIdentityStore.modelIdentifier(),
         storage: any PeerIDStorage = KeychainPeerIDStorage()) {
        self.defaults = defaults
        if storage is KeychainPeerIDStorage, let resolved = Self.processPeerID {
            peerID = resolved
        } else {
            let resolved = PhoneIdentityStore.resolvePeerID(storage: storage, defaults: defaults)
            if storage is KeychainPeerIDStorage { Self.processPeerID = resolved }
            peerID = resolved
        }
        if defaults.string(forKey: "peerName") == nil {
            defaults.set(DeviceModelName.marketingName(modelIdentifier: modelIdentifier), forKey: "peerName")
        }
    }

    /// The Keychain's ID; else the one an earlier version kept in UserDefaults, moved into the Keychain once (and
    /// removed from UserDefaults); else a new one. When the Keychain cannot be used (an unsigned build has no
    /// keychain-access-groups) the ID stays in UserDefaults as before, so it is stable and moves on a later launch.
    /// A read that fails after the identity reached the Keychain is transient: this process gets a temporary ID that
    /// is never stored, and the real one comes back on the next launch.
    private static func resolvePeerID(storage: any PeerIDStorage, defaults: UserDefaults) -> UUID {
        let legacy = defaults.string(forKey: legacyPeerIDKey).flatMap(UUID.init(uuidString:))
        do {
            if let stored = try storage.load() {
                if defaults.object(forKey: legacyPeerIDKey) != nil { defaults.removeObject(forKey: legacyPeerIDKey) }
                defaults.set(true, forKey: keychainFlagKey)
                return stored
            }
            let id = legacy ?? UUID()
            try storage.save(id)
            defaults.removeObject(forKey: legacyPeerIDKey)
            defaults.set(true, forKey: keychainFlagKey)
            return id
        } catch {
            if let legacy {
                logger.error("Phone identity is not in the Keychain: \(error.localizedDescription, privacy: .public)")
                return legacy
            }
            if defaults.bool(forKey: keychainFlagKey) {
                logger.fault("Phone identity unreadable from the Keychain; using a temporary one for this launch: \(error.localizedDescription, privacy: .public)")
                return UUID()
            }
            logger.error("Phone identity is not in the Keychain: \(error.localizedDescription, privacy: .public)")
            let id = UUID()
            defaults.set(id.uuidString, forKey: legacyPeerIDKey)
            return id
        }
    }

    nonisolated static func modelIdentifier() -> String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        #endif
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
