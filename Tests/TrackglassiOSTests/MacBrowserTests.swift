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

    /// §5.5 / M2: the input service is the `_trackglass._udp` record with the control instance's name. A record that
    /// only claims the Mac's `id` (a decoy, or a Bonjour rename of one service type) is used only after the grace.
    func testInputServiceIsTheControlInstancesOwn() {
        let other = UUID()
        let decoy = SessionClient.InputRecord(endpoint: udp(" Studio"), peerID: peerID)
        let own = SessionClient.InputRecord(endpoint: udp("Studio"), peerID: peerID)
        let otherMac = SessionClient.InputRecord(endpoint: udp("Studio"), peerID: other)
        XCTAssertEqual(SessionClient.instanceName(of: udp("Studio")), "Studio")
        XCTAssertNil(SessionClient.instanceName(of: .hostPort(host: "127.0.0.1", port: 4000)))
        XCTAssertEqual(SessionClient.inputEndpoint(in: [decoy, otherMac, own], peerID: peerID, instanceName: "Studio",
                                                   acceptOtherNames: false), udp("Studio"))
        XCTAssertNil(SessionClient.inputEndpoint(in: [decoy, otherMac], peerID: peerID, instanceName: "Studio",
                                                 acceptOtherNames: false), "another name waits for the Mac's own record")
        XCTAssertEqual(SessionClient.inputEndpoint(in: [decoy, otherMac], peerID: peerID, instanceName: "Studio",
                                                   acceptOtherNames: true), udp(" Studio"), "then a renamed record is used")
        XCTAssertNil(SessionClient.inputEndpoint(in: [otherMac], peerID: peerID, instanceName: "Studio", acceptOtherNames: true),
                     "never another Mac's")
        XCTAssertEqual(SessionClient.inputEndpoint(in: [own], peerID: peerID, instanceName: nil, acceptOtherNames: false),
                       udp("Studio"), "a host:port control endpoint has no name to match")
    }

    private func udp(_ name: String) -> NWEndpoint {
        .service(name: name, type: "_trackglass._udp", domain: "local.", interface: nil)
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
