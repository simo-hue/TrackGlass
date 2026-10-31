import Security
import TrackglassKit
import XCTest
@testable import TrackglassiOS

final class PhoneIdentityStoreTests: XCTestCase {
    @MainActor func testMarketingDefaultAndUserNamePersist() throws {
        let suite = "PhoneIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = MemoryPeerIDStorage()
        let first = PhoneIdentityStore(defaults: defaults, modelIdentifier: "iPhone16,2", storage: storage)
        XCTAssertEqual(first.name, "iPhone 15 Pro Max")
        first.name = "Simone's phone"
        let second = PhoneIdentityStore(defaults: defaults, modelIdentifier: "iPad8,1", storage: storage)
        XCTAssertEqual(second.peerID, first.peerID)
        XCTAssertEqual(second.name, "Simone's phone", "the display name stays in UserDefaults (§3.2)")
        XCTAssertNil(defaults.object(forKey: PhoneIdentityStore.legacyPeerIDKey), "the ID is not, so no backup carries it")
    }

    /// L7: an ID an earlier version kept in UserDefaults moves into the Keychain once and leaves UserDefaults.
    @MainActor func testLegacyIDMovesIntoTheKeychainOnce() throws {
        let suite = "PhoneIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = UUID()
        defaults.set(legacy.uuidString, forKey: PhoneIdentityStore.legacyPeerIDKey)
        let storage = MemoryPeerIDStorage()
        XCTAssertEqual(PhoneIdentityStore(defaults: defaults, storage: storage).peerID, legacy, "pairings keep working")
        XCTAssertEqual(storage.id, legacy)
        XCTAssertNil(defaults.object(forKey: PhoneIdentityStore.legacyPeerIDKey))
        XCTAssertEqual(PhoneIdentityStore(defaults: defaults, storage: storage).peerID, legacy)
        XCTAssertEqual(storage.saves, 1)
    }

    /// The Keychain wins over a UserDefaults ID (a restored backup of an older version brings one back).
    @MainActor func testKeychainIDWinsAndAFreshInstallGeneratesOne() throws {
        let suite = "PhoneIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = MemoryPeerIDStorage()
        let fresh = PhoneIdentityStore(defaults: defaults, storage: storage).peerID
        XCTAssertEqual(storage.id, fresh)
        defaults.set(UUID().uuidString, forKey: PhoneIdentityStore.legacyPeerIDKey)
        XCTAssertEqual(PhoneIdentityStore(defaults: defaults, storage: storage).peerID, fresh)
        XCTAssertNil(defaults.object(forKey: PhoneIdentityStore.legacyPeerIDKey))
        XCTAssertEqual(storage.saves, 1)
    }

    /// Without a usable Keychain (an unsigned build) the identity stays where it was, so it never changes per launch.
    @MainActor func testUnusableKeychainKeepsTheIdentityStable() throws {
        let suite = "PhoneIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let broken = MemoryPeerIDStorage()
        broken.failure = PairingStoreError.keychain(errSecMissingEntitlement)
        let first = PhoneIdentityStore(defaults: defaults, storage: broken).peerID
        XCTAssertEqual(PhoneIdentityStore(defaults: defaults, storage: broken).peerID, first)
        let working = MemoryPeerIDStorage()
        XCTAssertEqual(PhoneIdentityStore(defaults: defaults, storage: working).peerID, first, "and moves once it can")
        XCTAssertEqual(working.id, first)
        XCTAssertNil(defaults.object(forKey: PhoneIdentityStore.legacyPeerIDKey))
    }

    /// Once the identity is in the Keychain, a failed read never mints a lasting replacement: that launch uses a
    /// temporary ID that is stored nowhere, and the real one comes back with the next successful read.
    @MainActor func testTransientKeychainFailureNeverReplacesTheIdentity() throws {
        let suite = "PhoneIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = MemoryPeerIDStorage()
        let original = PhoneIdentityStore(defaults: defaults, storage: storage).peerID
        storage.failure = PairingStoreError.keychain(errSecInteractionNotAllowed)
        let temporary = PhoneIdentityStore(defaults: defaults, storage: storage).peerID
        XCTAssertNotEqual(temporary, original)
        XCTAssertNil(defaults.object(forKey: PhoneIdentityStore.legacyPeerIDKey), "the temporary ID is not persisted")
        storage.failure = nil
        XCTAssertEqual(PhoneIdentityStore(defaults: defaults, storage: storage).peerID, original)
        XCTAssertEqual(storage.saves, 1)
    }

    /// The real item: this device only, never synced. Skipped where the host has no Keychain access (the unsigned CI
    /// build, like `PairingStoreTests`).
    func testKeychainItemIsThisDeviceOnly() throws {
        let storage = KeychainPeerIDStorage(service: "app.trackglass.identity.tests.\(UUID().uuidString)")
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: storage.service]
        defer { SecItemDelete(query as CFDictionary) }
        let id = UUID()
        do { try storage.save(id) } catch PairingStoreError.keychain(let status)
            where status == errSecMissingEntitlement || status == errSecNotAvailable {
            throw XCTSkip("This host cannot use the Keychain (unsigned build): \(status)")
        }
        XCTAssertEqual(try storage.load(), id)
        let replacement = UUID()
        try storage.save(replacement)
        XCTAssertEqual(try storage.load(), replacement)
        var attributesQuery = query
        attributesQuery[kSecReturnAttributes as String] = true
        var raw: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(attributesQuery as CFDictionary, &raw), errSecSuccess)
        let attributes = try XCTUnwrap(raw as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertNil(try KeychainPeerIDStorage(service: "app.trackglass.identity.tests.\(UUID().uuidString)").load())
    }
}

private final class MemoryPeerIDStorage: PeerIDStorage {
    var id: UUID?
    var failure: Error?
    private(set) var saves = 0

    func load() throws -> UUID? {
        if let failure { throw failure }
        return id
    }

    func save(_ id: UUID) throws {
        if let failure { throw failure }
        self.id = id
        saves += 1
    }
}
