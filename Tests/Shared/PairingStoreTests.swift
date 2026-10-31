import XCTest
import Security
import TrackglassKit

final class PairingStoreTests: XCTestCase {
    func testRoundTripUpdateListAndDelete() throws {
        let store = PairingStore(service: "app.trackglass.pairing.tests.\(UUID().uuidString)")
        let firstID = UUID()
        let secondID = UUID()
        defer {
            try? store.delete(peerID: firstID)
            try? store.delete(peerID: secondID)
        }
        let first = PairedPeer(peerID: firstID, ltk: Data(repeating: 0x31, count: 32),
                               name: "Phone α", pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = PairedPeer(peerID: secondID, ltk: Data(repeating: 0x42, count: 32),
                                name: "iPad", pairedAt: first.pairedAt)
        XCTAssertNil(try store.load(peerID: firstID))
        XCTAssertTrue(try store.all().isEmpty)
        try store.save(first)
        try store.save(second)
        XCTAssertEqual(try store.load(peerID: firstID), first)
        XCTAssertEqual(Set(try store.all().map(\.peerID)), [firstID, secondID])
        let updated = PairedPeer(peerID: firstID, ltk: second.ltk, name: "Renamed", pairedAt: first.pairedAt)
        try store.save(updated)
        XCTAssertEqual(try store.load(peerID: firstID), updated)
        XCTAssertEqual(try store.all().count, 2)
        try store.delete(peerID: firstID)
        try store.delete(peerID: firstID)
        XCTAssertNil(try store.load(peerID: firstID))
        XCTAssertEqual(try store.all(), [second])
    }

    func testStoredProtectionAndJSONFormat() throws {
        let store = PairingStore(service: "app.trackglass.pairing.tests.\(UUID().uuidString)")
        let id = UUID()
        defer { try? store.delete(peerID: id) }
        try store.save(PairedPeer(peerID: id, ltk: Data(repeating: 7, count: 32), name: "Mac",
                                 pairedAt: Date(timeIntervalSince1970: 0)))
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: store.service,
                                    kSecAttrAccount as String: id.uuidString.lowercased(),
                                    kSecReturnAttributes as String: true,
                                    kSecReturnData as String: true]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        var raw: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &raw), errSecSuccess)
        let attributes = try XCTUnwrap(raw as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
        let data = try XCTUnwrap(attributes[kSecValueData as String] as? Data)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(Set(json.keys), ["ltk", "name", "pairedAt"])
        XCTAssertEqual(json["ltk"], Data(repeating: 7, count: 32).base64EncodedString())
        XCTAssertEqual(json["pairedAt"], "1970-01-01T00:00:00Z")
    }

    func testUnreadableRecordIsSkippedAndTheOthersStillList() throws {
        let store = PairingStore(service: "app.trackglass.pairing.tests.\(UUID().uuidString)")
        let good = PairedPeer(peerID: UUID(), ltk: Data(repeating: 9, count: 32), name: "Good",
                              pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save(good)
        var bad: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: store.service,
                                  kSecAttrAccount as String: "not-a-uuid",
                                  kSecAttrSynchronizable as String: false,
                                  kSecValueData as String: Data("{}".utf8)]
        #if os(macOS)
        bad[kSecUseDataProtectionKeychain as String] = true
        #endif
        XCTAssertEqual(SecItemAdd(bad as CFDictionary, nil), errSecSuccess)
        defer {
            try? store.delete(peerID: good.peerID)
            bad.removeValue(forKey: kSecValueData as String)
            SecItemDelete(bad as CFDictionary)
        }
        XCTAssertEqual(try store.all(), [good])
    }

    /// §3.4 (round 4, L5): a re-pair whose PAIR_RESPONSE never reaches the phone puts the previous, still working
    /// pairing back instead of deleting it; a first pairing that fails leaves nothing behind.
    func testReplaceReturnsThePreviousRecordAndRestorePutsItBack() throws {
        let store = PairingStore(service: "app.trackglass.pairing.tests.\(UUID().uuidString)")
        let id = UUID()
        defer { try? store.delete(peerID: id) }
        let old = PairedPeer(peerID: id, ltk: Data(repeating: 1, count: 32), name: "Phone",
                             pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let new = PairedPeer(peerID: id, ltk: Data(repeating: 2, count: 32), name: "Phone",
                             pairedAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(try store.replace(with: old), "nothing was paired before")
        XCTAssertEqual(try store.replace(with: new), old)
        XCTAssertEqual(try store.load(peerID: id), new)
        try store.restore(old, peerID: id)
        XCTAssertEqual(try store.load(peerID: id), old, "the old key works again")
        try store.restore(nil, peerID: id)
        XCTAssertNil(try store.load(peerID: id), "a first pairing that failed leaves no record")
        try store.restore(nil, peerID: id)
    }

    func testInvalidKeyIsRejectedWithoutSaving() throws {
        let store = PairingStore(service: "app.trackglass.pairing.tests.\(UUID().uuidString)")
        let id = UUID()
        XCTAssertThrowsError(try store.save(PairedPeer(peerID: id, ltk: Data(count: 31), name: "Bad"))) {
            XCTAssertEqual($0 as? PairingStoreError, .invalidRecord)
        }
        XCTAssertNil(try store.load(peerID: id))
    }
}
