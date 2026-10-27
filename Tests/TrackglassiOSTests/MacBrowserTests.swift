import XCTest
import Network
@testable import TrackglassiOS

final class MacBrowserTests: XCTestCase {
    private let peerID = UUID(uuidString: "B7705D4A-D7B4-4B88-8D61-65EE052DBAC1")!

    func testMainAndPairingInstancesStaySeparate() throws {
        let main = try XCTUnwrap(DiscoveredMac(endpoint: endpoint("Mac"), txt: record(pairing: false)))
        let pairing = try XCTUnwrap(DiscoveredMac(endpoint: endpoint("Mac (pairing)"), txt: record(pairing: true)))
        XCTAssertEqual(main.peerID, pairing.peerID)
        XCTAssertNotEqual(main.id, pairing.id)
        XCTAssertFalse(main.isPairing)
        XCTAssertTrue(pairing.isPairing)
        XCTAssertNil(main.pairID)
        XCTAssertEqual(pairing.pairID, Data(repeating: 0, count: 8))
        XCTAssertEqual(main.name, "Mac")
    }

    func testInvalidMetadataIsIgnored() {
        var txt = record(pairing: false)
        txt.setEntry(.string("2"), for: "v")
        XCTAssertNil(DiscoveredMac(endpoint: endpoint("Mac"), txt: txt))
        txt = record(pairing: true)
        txt.removeEntry(key: "pid")
        XCTAssertNil(DiscoveredMac(endpoint: endpoint("Mac"), txt: txt))
        txt.setEntry(.string("AAAAAAAAAAB"), for: "pid")
        XCTAssertNil(DiscoveredMac(endpoint: endpoint("Mac"), txt: txt), "Reject noncanonical base64url")
        txt = record(pairing: false)
        txt.setEntry(.string("not-a-uuid"), for: "id")
        XCTAssertNil(DiscoveredMac(endpoint: endpoint("Mac"), txt: txt))
    }

    private func endpoint(_ name: String) -> NWEndpoint {
        .service(name: name, type: "_trackglass._tcp", domain: "local.", interface: nil)
    }

    private func record(pairing: Bool) -> NWTXTRecord {
        var values = ["v": "1", "id": peerID.uuidString, "nm": "Mac", "pr": pairing ? "1" : "0"]
        if pairing { values["pid"] = "AAAAAAAAAAA" }
        return NWTXTRecord(values)
    }
}
