import Network
import XCTest
@testable import TrackglassiOS

final class ConnectionStateTests: XCTestCase {
    private func snapshot(_ sequence: UInt64, connected: Bool, status: String, rtt: UInt32 = 0,
                          peer: UUID? = nil) -> SessionClient.Snapshot {
        // Like SessionClient, the Mac's name outlives the session that set it.
        SessionClient.Snapshot(isConnected: connected, status: status, macName: "Mac", rttMicros: rtt,
                               settings: nil, diagnostics: nil, diagnosticsSequence: 0, sequence: sequence,
                               connectedPeerID: connected ? peer : nil)
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

    @MainActor func testReconnectingAndConnectedMacArePublished() {
        let state = ConnectionState()
        let peer = UUID()
        state.apply(snapshot(1, connected: true, status: "Connected to Mac", peer: peer), isReconnecting: true)
        XCTAssertEqual(state.connectedPeerID, peer)
        XCTAssertFalse(state.isReconnecting, "a connected session is never 'reconnecting'")
        state.apply(snapshot(2, connected: false, status: "Connection lost"), isReconnecting: true)
        XCTAssertNil(state.connectedPeerID)
        XCTAssertTrue(state.isReconnecting)
        state.apply(snapshot(3, connected: false, status: "Connection lost"))
        XCTAssertFalse(state.isReconnecting)
        state.updateDiscovery(macs: [], pairedMacs: [], status: MacBrowser.localNetworkOffStatus, localNetworkDenied: true)
        XCTAssertTrue(state.localNetworkDenied)
        state.updateDiscovery(macs: [], pairedMacs: [])
        XCTAssertTrue(state.localNetworkDenied, "nil keeps the last value")
    }

    @MainActor func testVoiceOverHearsAnActionableAnswerOnceWhileRetrying() {
        let state = ConnectionState()
        var heard: [String] = []
        state.onAnnouncement = { heard.append($0) }
        for (sequence, status) in [(UInt64(1), "Connecting to Mac…"), (2, "Mac is being used by Sam's iPhone"),
                                   (3, "Connecting to Mac…"), (4, "Mac is being used by Sam's iPhone"),
                                   (5, "Connecting to Mac…"), (6, "Connection timed out")] {
            state.apply(snapshot(sequence, connected: false, status: status), isReconnecting: true)
        }
        XCTAssertEqual(heard, ["Mac is being used by Sam's iPhone. Disconnect it there, then reconnect."])
        XCTAssertNil(ConnectionState.outcome(for: "Reconnecting to Mac…", macName: "Mac"),
                     "busy with this very phone (a stale session) is routine")
    }

    @MainActor func testLastMacIsListedOnlyWhenItsServiceIsFound() {
        let state = ConnectionState()
        let id = UUID()
        state.updateLastMac(name: "Studio", peerID: id)
        XCTAssertFalse(state.lastMacIsListed)
        var txt = NWTXTRecord()
        txt["v"] = "1"; txt["id"] = id.uuidString; txt["nm"] = "Studio"; txt["pr"] = "0"
        let mac = DiscoveredMac(endpoint: .service(name: "Studio", type: "_trackglass._tcp", domain: "local.", interface: nil), txt: txt)
        state.updateDiscovery(macs: mac.map { [$0] } ?? [], pairedMacs: [])
        XCTAssertTrue(state.lastMacIsListed)
        state.updateLastMac(name: "", peerID: nil)
        XCTAssertFalse(state.lastMacIsListed)
    }

    @MainActor func testVoiceOverHearsConnectsDropsAndFinalOutcomesOnly() {
        let state = ConnectionState()
        var heard: [String] = []
        state.onAnnouncement = { heard.append($0) }
        state.apply(snapshot(1, connected: true, status: "Connected to Mac"))
        state.apply(snapshot(2, connected: true, status: "Connected to Mac", rtt: 2_000))   // RTT updates are silent
        state.apply(snapshot(3, connected: false, status: "Connection lost"), isReconnecting: true)
        state.apply(snapshot(4, connected: false, status: "Connecting to Mac…"), isReconnecting: true)
        state.apply(snapshot(5, connected: false, status: "Connection timed out"), isReconnecting: true)
        state.apply(snapshot(6, connected: false, status: "Pair again"), isReconnecting: false)
        state.apply(snapshot(7, connected: false, status: "Pair again"), isReconnecting: false)
        XCTAssertEqual(heard, ["Connected to Mac", "Connection to Mac lost. Reconnecting.",
                               "Mac no longer recognizes this device. Pair again to reconnect."])
        heard.removeAll()
        state.apply(snapshot(8, connected: true, status: "Connected to Mac"))
        state.apply(snapshot(9, connected: false, status: "Disconnected"))
        XCTAssertEqual(heard, ["Connected to Mac", "Disconnected from Mac"])
    }

    func testOutcomesAreActionable() {
        XCTAssertNil(ConnectionState.outcome(for: "No Mac connected", macName: "Studio"))
        XCTAssertNil(ConnectionState.outcome(for: "Disconnected", macName: "Studio"))
        XCTAssertNil(ConnectionState.outcome(for: "Connecting to Studio…", macName: "Studio"))
        XCTAssertNil(ConnectionState.outcome(for: "Connected to Studio", macName: "Studio"))
        XCTAssertEqual(ConnectionState.outcome(for: "Pair again", macName: "Studio"),
                       "Studio no longer recognizes this device. Pair again to reconnect.")
        XCTAssertEqual(ConnectionState.outcome(for: "The Mac went to sleep", macName: ""),
                       "The Mac went to sleep. Wake it to reconnect.")
        for status in ["Incompatible version", "Invalid control message", "Input path lost", "Input connection failed",
                       "Mac input service not found", "The Mac is busy", "Connection timed out"] {
            let text = ConnectionState.outcome(for: status, macName: "Studio")
            XCTAssertNotNil(text)
            XCTAssertNotEqual(text, status, "\(status) is explained, not repeated")
        }
        XCTAssertEqual(ConnectionState.outcome(for: "Studio is being used by Ana’s iPhone", macName: "Studio"),
                       "Studio is being used by Ana’s iPhone. Disconnect it there, then reconnect.")
        XCTAssertEqual(ConnectionState.outcome(for: "Connection lost", macName: "Studio"), "Connection lost")
        XCTAssertEqual(ConnectionState.panelAction(for: "Pair again"), .pair)
        XCTAssertEqual(ConnectionState.panelAction(for: "Incompatible version"), .nothing)
        XCTAssertEqual(ConnectionState.panelAction(for: "Connection timed out"), .reconnect)
    }

    @MainActor func testPillShowsADashUntilTheFirstRoundTripAndTheSurfaceValueFollowsTheSession() {
        XCTAssertEqual(ConnectionState.latencyText(rttMicros: 0), "—")
        XCTAssertEqual(ConnectionState.latencyText(rttMicros: 3_000), "1.5 ms")
        let state = ConnectionState()
        XCTAssertEqual(state.accessibilityStatus, "No Mac connected")
        state.updateLastMac(name: "Studio")
        XCTAssertEqual(state.accessibilityStatus, "Not connected to Studio")
        state.apply(snapshot(1, connected: false, status: "Connection lost"), isReconnecting: true)
        XCTAssertEqual(state.accessibilityStatus, "Reconnecting to Studio")
        state.apply(snapshot(2, connected: true, status: "Connected to Mac"))
        XCTAssertEqual(state.pillText, "Mac · —")
        XCTAssertEqual(state.accessibilityStatus, "Connected to Mac")
        state.apply(snapshot(3, connected: true, status: "Connected to Mac", rtt: 4_200))
        XCTAssertEqual(state.pillText, "Mac · 2.1 ms")
        state.showNotice("Hello")
        XCTAssertEqual(state.pillText, "Hello")
    }
}
