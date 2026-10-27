import XCTest
import Network
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

}
