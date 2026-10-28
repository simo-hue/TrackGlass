import XCTest
@testable import TrackglassiOS

final class ConnectionStateTests: XCTestCase {
    private func snapshot(_ sequence: UInt64, connected: Bool, status: String) -> SessionClient.Snapshot {
        SessionClient.Snapshot(isConnected: connected, status: status, macName: connected ? "Mac" : "", rttMicros: 0,
                               settings: nil, diagnostics: nil, diagnosticsSequence: 0, sequence: sequence)
    }

    @MainActor func testOlderSnapshotDeliveredLateIsIgnored() {
        let state = ConnectionState()
        state.apply(snapshot(2, connected: true, status: "Connected to Mac"))
        state.apply(snapshot(1, connected: false, status: "No Mac connected"))
        XCTAssertTrue(state.isConnected)
        XCTAssertEqual(state.status, "Connected to Mac")
        state.apply(snapshot(3, connected: false, status: "Connection lost"))
        XCTAssertFalse(state.isConnected)
        XCTAssertEqual(state.status, "Connection lost")
    }

    @MainActor func testDiscoveryStatusAndLastMacArePublished() {
        let state = ConnectionState()
        state.updateDiscovery(macs: [], pairedMacs: [], status: "Discovery waiting: policy denied")
        XCTAssertEqual(state.discoveryStatus, "Discovery waiting: policy denied")
        state.updateDiscovery(macs: [], pairedMacs: [])
        XCTAssertEqual(state.discoveryStatus, "Discovery waiting: policy denied", "a nil status keeps the last one")
        state.updateLastMac(name: "Studio")
        XCTAssertEqual(state.lastMacName, "Studio")
    }
}
