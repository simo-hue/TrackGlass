import XCTest
import Network
import TrackglassKit
@testable import TrackglassMac

final class BonjourAdvertiserTests: XCTestCase {
    @MainActor func testPersistentIdentityAndAdvertisement() throws {
        let suite = "TrackglassDiscoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = BonjourAdvertiser(defaults: defaults)
        let second = BonjourAdvertiser(defaults: defaults)
        XCTAssertEqual(first.peerID, second.peerID)
        let txt = BonjourAdvertiser.txtRecord(peerID: first.peerID, name: "Reference Mac")
        XCTAssertEqual(txt.getEntry(for: "id")?.data, Data(first.peerID.uuidString.lowercased().utf8))
        XCTAssertEqual(txt.getEntry(for: "v")?.data, Data("1".utf8))
        XCTAssertEqual(txt.getEntry(for: "pr")?.data, Data("0".utf8))
        XCTAssertEqual(txt.getEntry(for: "im")?.data, Data("1".utf8))
        XCTAssertEqual(txt.getEntry(for: "nm")?.data, Data("Reference Mac".utf8))
    }
    func testIdentityMadeOnOtherHardwareIsReplaced() {
        // L7: Migration Assistant copies the peerID (UserDefaults) but not the pairings (this-device-only Keychain).
        let id = UUID()
        XCTAssertEqual(MacIdentity.decide(storedID: nil, storedFingerprint: nil, currentFingerprint: "a", hasPairings: true), .generate)
        XCTAssertEqual(MacIdentity.decide(storedID: id, storedFingerprint: "a", currentFingerprint: "a", hasPairings: false), .keep)
        XCTAssertEqual(MacIdentity.decide(storedID: id, storedFingerprint: "a", currentFingerprint: "b", hasPairings: true), .generate)
        // No readable fingerprint: a working identity is never dropped.
        XCTAssertEqual(MacIdentity.decide(storedID: id, storedFingerprint: "a", currentFingerprint: nil, hasPairings: false), .keep)
        // An ID from before the fingerprint: kept while phones are paired under it, replaced when none could connect.
        XCTAssertEqual(MacIdentity.decide(storedID: id, storedFingerprint: nil, currentFingerprint: "a", hasPairings: true), .keep)
        XCTAssertEqual(MacIdentity.decide(storedID: id, storedFingerprint: nil, currentFingerprint: "a", hasPairings: false), .generate)
    }

    func testMigratedDefaultsGetANewPeerIDOnTheNewMac() throws {
        let suite = "TrackglassIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairingStore(service: "app.trackglass.identity-tests.\(UUID())")
        let original = MacIdentity.resolve(defaults: defaults, store: store, currentFingerprint: "old-mac")
        XCTAssertEqual(MacIdentity.resolve(defaults: defaults, store: store, currentFingerprint: "old-mac"), original)
        // The same defaults on another Mac (Migration Assistant): a new ID, which then stays.
        let migrated = MacIdentity.resolve(defaults: defaults, store: store, currentFingerprint: "new-mac")
        XCTAssertNotEqual(migrated, original)
        XCTAssertEqual(MacIdentity.resolve(defaults: defaults, store: store, currentFingerprint: "new-mac"), migrated)
        XCTAssertEqual(defaults.string(forKey: MacIdentity.peerIDKey), migrated.uuidString)
        XCTAssertNotNil(MacIdentity.hardwareFingerprint(), "IOPlatformUUID is readable on a Mac")
    }

    @MainActor func testListeningAloneDoesNotClaimAdvertising() throws {
        let suite = "TrackglassRegistrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let advertiser = BonjourAdvertiser(defaults: defaults)
        advertiser.update(.ready, kind: "tcp")
        advertiser.update(.ready, kind: "udp")
        XCTAssertFalse(advertiser.status.hasPrefix("Advertising as"))
        let endpoint = NWEndpoint.service(name: "Test", type: "_trackglass._tcp", domain: "local.", interface: nil)
        advertiser.registrationChanged(.add(endpoint), kind: "tcp")
        XCTAssertFalse(advertiser.status.hasPrefix("Advertising as"))
        advertiser.registrationChanged(.add(endpoint), kind: "udp")
        XCTAssertTrue(advertiser.status.hasPrefix("Advertising as"))
        advertiser.registrationChanged(.remove(endpoint), kind: "tcp")
        XCTAssertFalse(advertiser.status.hasPrefix("Advertising as"))
    }

    @MainActor func testAdmittedInputPeerSurvivesStopAndPairingSetChanges() throws {
        // §6.3: the input listener is recreated with the admitted phone's key on every restart; the identity
        // must therefore outlive the listener objects (a pairing-set change or a sleep/wake cycle).
        let suite = "TrackglassAdmissionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let advertiser = BonjourAdvertiser(defaults: defaults)
        let phone = UUID()
        advertiser.setInputIdentity(phone)
        XCTAssertEqual(advertiser.admittedInputPeer, phone)
        advertiser.pairingSetChanged()   // no listener running: must not clear the admitted identity
        advertiser.stop()
        XCTAssertEqual(advertiser.admittedInputPeer, phone)
        advertiser.setInputIdentity(nil)
        XCTAssertNil(advertiser.admittedInputPeer)
    }
}
