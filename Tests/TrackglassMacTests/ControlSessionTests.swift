import CryptoKit
import Foundation
import Network
import TrackglassKit
import XCTest
@testable import TrackglassMac

@MainActor
final class ControlSessionTests: XCTestCase {
    func testInactiveUserSessionRejectsAdmissionUntilReactivated() async throws {
        let harness = try SessionHarness()
        defer { harness.stop() }
        let endpoint = try await harness.start()
        let client = harness.client()
        defer { client.disconnect() }
        harness.server.setSessionActive(false)
        let rejected = await client.connect(endpoint: endpoint, mac: harness.mac(for: 0), hello: harness.hello(0))
        XCTAssertFalse(rejected)
        XCTAssertTrue(client.status.contains("being used"))
        harness.server.setSessionActive(true)
        let connected = await client.connect(endpoint: endpoint, mac: harness.mac(for: 0), hello: harness.hello(0))
        XCTAssertTrue(connected)
    }
    func testAdmissionBusyRTTSurfaceAndBye() async throws {
        let harness = try SessionHarness()
        defer { harness.stop() }
        let endpoint = try await harness.start()
        let first = harness.client()
        let second = harness.client()
        defer { first.disconnect(); second.disconnect() }
        let firstConnected = await first.connect(endpoint: endpoint, mac: harness.mac(for: 0), hello: harness.hello(0))
        XCTAssertTrue(firstConnected)
        try await eventually { first.isConnected && first.rttMicros > 0 }
        XCTAssertEqual(first.settings, ControlListener.defaultSettings)
        let secondConnected = await second.connect(endpoint: endpoint, mac: harness.mac(for: 1), hello: harness.hello(1))
        XCTAssertFalse(secondConnected)
        try await eventually { second.status.contains("being used by Phone 1") }
        XCTAssertFalse(second.isConnected)
        XCTAssertTrue(first.isConnected)
        first.updateSurface(SurfaceMessage(surfaceWidthMM: 141, surfaceHeightMM: 65, ppi: 460, trackingOverride: 0))
        first.trackingOverride = 0.5
        try await eventually {
            let session = await harness.server.coordinator.activeSession
            return session?.surface.surfaceWidthMM == 141 && session?.surface.trackingOverride == 0.5
        }
        first.disconnect()
        try await eventually { await harness.server.coordinator.activeSession == nil }
        let secondReconnected = await second.connect(endpoint: endpoint, mac: harness.mac(for: 1), hello: harness.hello(1))
        XCTAssertTrue(secondReconnected)
        try await eventually { second.isConnected }
    }

    func testSamePhoneReconnectSupersedesItsStaleSession() async throws {
        let harness = try SessionHarness()
        defer { harness.stop() }
        let endpoint = try await harness.start()
        // The stale session: admitted, then the phone went quiet (Wi-Fi blip) with its TCP connection still open.
        let stale = try await harness.admittedSilentConnection(endpoint: endpoint, phone: 0)
        defer { stale.cancel() }
        try await Task.sleep(for: .milliseconds(1_700))
        let fresh = harness.client()
        defer { fresh.disconnect() }
        // Same peerID, new connection: admitted at once, never told it is busy with itself.
        let freshConnected = await fresh.connect(endpoint: endpoint, mac: harness.mac(for: 0), hello: harness.hello(0))
        XCTAssertTrue(freshConnected)
        try await eventually { fresh.isConnected }
        let session = await harness.server.coordinator.activeSession
        XCTAssertEqual(session?.peer.peerID, harness.phones[0].peerID)
        XCTAssertFalse(fresh.status.contains("being used"))
    }

    func testHelloNeverEndsASessionThatIsStillTalking() async throws {
        // A HELLO cannot prove which paired phone sent it, so a session that still answers its PINGs is never
        // superseded: the newcomer is told the Mac is busy and the live session stays.
        let harness = try SessionHarness()
        defer { harness.stop() }
        let endpoint = try await harness.start()
        let live = harness.client()
        let second = harness.client()
        defer { live.disconnect(); second.disconnect() }
        let liveConnected = await live.connect(endpoint: endpoint, mac: harness.mac(for: 0), hello: harness.hello(0))
        XCTAssertTrue(liveConnected)
        try await eventually { live.rttMicros > 0 }
        let secondConnected = await second.connect(endpoint: endpoint, mac: harness.mac(for: 0), hello: harness.hello(0))
        XCTAssertFalse(secondConnected)
        XCTAssertTrue(live.isConnected)
        let session = await harness.server.coordinator.activeSession
        XCTAssertEqual(session?.peer.peerID, harness.phones[0].peerID)
    }

    func testForgetRejectsNextHandshake() async throws {
        let harness = try SessionHarness()
        defer { harness.stop() }
        var endpoint = try await harness.start()
        let client = harness.client()
        defer { client.disconnect() }
        let connected = await client.connect(endpoint: endpoint, mac: harness.mac(for: 0), hello: harness.hello(0))
        XCTAssertTrue(connected)
        try await eventually { client.isConnected }
        try harness.server.forget(harness.phones[0].peerID)
        try await eventually { client.status == "Pair again" }
        XCTAssertNil(try harness.store.load(peerID: harness.phones[0].peerID))
        endpoint = try await harness.start()
        let forgottenConnected = await client.connect(endpoint: endpoint, mac: harness.mac(for: 0), hello: harness.hello(0))
        XCTAssertFalse(forgottenConnected)
        try await eventually { client.status == "Pair again" }
        XCTAssertFalse(client.isConnected)
        let retained = harness.client()
        defer { retained.disconnect() }
        let retainedConnected = await retained.connect(endpoint: endpoint, mac: harness.mac(for: 1), hello: harness.hello(1))
        XCTAssertTrue(retainedConnected)
        try await eventually { retained.isConnected }
    }

    func testDisconnectOnTheMacIsFinalForThePhoneButAManualReconnectWorks() async throws {
        // §6.1 menu / Devices "Disconnect": BYE{5}. The phone treats it as final (its reconnect loop stops), and
        // its user can still reconnect by hand.
        let harness = try SessionHarness()
        defer { harness.stop() }
        let endpoint = try await harness.start()
        let client = harness.client()
        defer { client.disconnect() }
        let phone = harness.phones[0].peerID
        let connected = await client.connect(endpoint: endpoint, mac: harness.mac(for: 0), hello: harness.hello(0))
        XCTAssertTrue(connected)
        try await eventually { client.isConnected && harness.server.connectedPeerID == phone }
        harness.server.disconnect(peerID: phone)
        try await eventually { !client.isConnected && harness.server.connectedPeerID == nil }
        XCTAssertEqual(client.status, ControlCloseMessage.disconnectedOnMac)
        XCTAssertTrue(client.lastCloseWasFinal, "the phone must not reconnect by itself")
        try await eventually { await harness.server.coordinator.activeSession == nil }
        let manual = await client.connect(endpoint: endpoint, mac: harness.mac(for: 0), hello: harness.hello(0))
        XCTAssertTrue(manual)
        try await eventually { client.isConnected && harness.server.connectedPeerID == phone }
    }

    func testHelloArrivingWhileQuittingIsTurnedAway() async throws {
        // §6.1 quit: during the short wait for the BYEs to leave, a phone's HELLO must not be admitted (it would
        // get no BYE and could leave a button held when the process exits).
        let harness = try SessionHarness()
        defer { harness.stop() }
        let endpoint = try await harness.start()
        harness.server.endAllSessionsForQuit()
        let client = harness.client()
        defer { client.disconnect() }
        let connected = await client.connect(endpoint: endpoint, mac: harness.mac(for: 0), hello: harness.hello(0))
        XCTAssertFalse(connected)
        XCTAssertNil(harness.server.connectedPeerID)
        let session = await harness.server.coordinator.activeSession
        XCTAssertNil(session)
    }

    func testThreeUnansweredPingsDisconnect() async throws {
        let harness = try SessionHarness(silent: true)
        defer { harness.stop() }
        let endpoint = try await harness.start()
        let options = TLSConfig.tlsOptions(psk: SymmetricKey(data: harness.phones[0].ltk),
            identity: harness.phones[0].peerID.uuidString.lowercased())
        let channel = ControlChannel(connection: NWConnection(to: endpoint, using: TLSConfig.parameters(control: options)))
        defer { channel.close() }
        var result: String?
        channel.onReady = { [weak channel] in channel?.startHeartbeat() }
        channel.onClose = { result = $0 }
        channel.start()
        try await eventually { result != nil }
        XCTAssertEqual(result, "Connection timed out")
    }

    func testIncompatibleHelloRejected() async throws {
        let harness = try SessionHarness()
        defer { harness.stop() }
        let endpoint = try await harness.start()
        let client = harness.client()
        var hello = harness.hello(0)
        hello.protocolVersion = 2
        let connected = await client.connect(endpoint: endpoint, mac: harness.mac(for: 0), hello: hello)
        XCTAssertFalse(connected)
        try await eventually { client.status == "Incompatible version" }
        XCTAssertFalse(client.isConnected)
        let active = await harness.server.coordinator.activeSession
        XCTAssertNil(active)
    }

    func testConnectionsThatNeverSendHelloAreCappedAndTimedOut() async throws {
        // M3: anyone on the LAN can open control connections. At most 16 wait for HELLO at a time (a newcomer beyond
        // that is refused, so a handshake already in progress survives) and each is closed `helloTimeout` after it was
        // accepted.
        let harness = try SessionHarness()
        defer { harness.stop() }
        harness.server.helloTimeout = .seconds(1)
        let sink = try await harness.silentTCPEndpoint()
        var idle: [NWConnection] = []
        defer { idle.forEach { $0.cancel() } }
        for _ in 0..<(ControlListener.maximumAwaitingHello + 8) {
            let connection = NWConnection(to: sink, using: .tcp)
            idle.append(connection)
            harness.server.accept(connection)
        }
        XCTAssertEqual(harness.server.awaitingHelloCount, ControlListener.maximumAwaitingHello)
        XCTAssertEqual(harness.server.openChannelCount, ControlListener.maximumAwaitingHello)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(harness.server.openChannelCount, ControlListener.maximumAwaitingHello, "open until the HELLO timeout")
        try await eventually { harness.server.openChannelCount == 0 && harness.server.awaitingHelloCount == 0 }
        // A phone that does send HELLO is admitted as usual and is not closed by the timeout.
        let endpoint = try await harness.start()
        let client = harness.client()
        defer { client.disconnect() }
        let connected = await client.connect(endpoint: endpoint, mac: harness.mac(for: 0), hello: harness.hello(0))
        XCTAssertTrue(connected)
        try await Task.sleep(for: .milliseconds(1_300))
        XCTAssertTrue(client.isConnected)
    }

    func testForgetEndsEverySessionAndAStillPairedPhoneReconnects() async throws {
        // L3 (§3.5): a HELLO cannot prove which paired phone sent it, so forgetting any phone ends every admitted
        // session. A phone that is still paired is not told it is final: it reconnects by itself.
        let harness = try SessionHarness()
        defer { harness.stop() }
        var endpoint = try await harness.start()
        let retained = harness.client()
        defer { retained.disconnect() }
        let connected = await retained.connect(endpoint: endpoint, mac: harness.mac(for: 1), hello: harness.hello(1))
        XCTAssertTrue(connected)
        try await eventually { retained.isConnected && harness.server.connectedPeerID == harness.phones[1].peerID }
        try harness.server.forget(harness.phones[0].peerID)
        try await eventually { !retained.isConnected && harness.server.connectedPeerID == nil }
        XCTAssertFalse(retained.lastCloseWasFinal, "a still-paired phone keeps reconnecting")
        XCTAssertNotEqual(retained.status, ControlCloseMessage.pairAgain)
        try await eventually { await harness.server.coordinator.activeSession == nil }
        endpoint = try await harness.start()   // the app restarts the control listener with the remaining keys
        let reconnected = await retained.connect(endpoint: endpoint, mac: harness.mac(for: 1), hello: harness.hello(1))
        XCTAssertTrue(reconnected)
    }

    func testForgettingAPhoneEndsTheSessionItOpenedUnderAnotherPhonesID() async throws {
        // L3: phone 2's key, HELLO claiming phone 1. Forgetting phone 2 ends that session at once; before, it lived on
        // under phone 1's name until three PINGs went unanswered.
        let harness = try SessionHarness()
        defer { harness.stop() }
        let endpoint = try await harness.start()
        let posing = try await harness.admittedSilentConnection(endpoint: endpoint, phone: 1, claiming: 0)
        defer { posing.cancel() }
        try harness.server.forget(harness.phones[1].peerID)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(harness.server.connectedPeerID, "ended by the BYE, not by missed PINGs (≥ 3 s)")
    }

    func testUnexpectedMessagesAndAnInvalidSurfaceAreIgnoredNotAnsweredWithAFinalBye() async throws {
        // L8b (§4.1): a known type the Mac does not expect from a phone (a newer phone's message, a repeated HELLO) is
        // ignored, never answered with BYE 1, which the phone treats as final. L9 (C3): a SURFACE with a non-positive
        // size keeps the previous geometry and the session.
        let harness = try SessionHarness()
        defer { harness.stop() }
        let endpoint = try await harness.start()
        let phone = try await harness.admittedSilentConnection(endpoint: endpoint, phone: 0)
        defer { phone.cancel() }
        try harness.send(.settings(ControlListener.defaultSettings), on: phone)
        try harness.send(.haptic(HapticMessage(kind: 1, intensity: 255)), on: phone)
        try harness.send(.hello(harness.hello(0)), on: phone)
        try harness.send(.surface(SurfaceMessage(surfaceWidthMM: 0, surfaceHeightMM: 141, ppi: 460, trackingOverride: 0)), on: phone)
        try await Task.sleep(for: .milliseconds(200))
        let unchanged = await harness.server.coordinator.activeSession?.surface.surfaceWidthMM
        XCTAssertEqual(unchanged, 65, "the HELLO geometry stays")
        try harness.send(.surface(SurfaceMessage(surfaceWidthMM: 70, surfaceHeightMM: 141, ppi: 460, trackingOverride: 0)), on: phone)
        try await eventually { await harness.server.coordinator.activeSession?.surface.surfaceWidthMM == 70 }
        XCTAssertEqual(harness.server.connectedPeerID, harness.phones[0].peerID)
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ predicate: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Control session did not reach expected state within eight seconds", file: file, line: line)
        throw SessionHarness.Failure.timeout
    }
}

@MainActor
private final class SessionHarness {
    enum Failure: Error { case timeout }
    let identity = PeerIdentity(peerID: UUID(), name: "Test Mac")
    let phones: [PairedPeer]
    let store = PairingStore(service: "app.trackglass.control-tests.\(UUID())")
    let server: ControlListener
    private var listener: NWListener?
    private let silent: Bool
    private var silentConnections: [NWConnection] = []
    private var sinks: [NWListener] = []

    /// The harness advertises no `_trackglass._udp` service, so the client's input-path watchdog must not end sessions.
    @MainActor func client() -> SessionClient {
        let client = SessionClient(inputSink: UDPFrameSink())
        client.inputPathTimeout = .seconds(600)
        return client
    }

    init(silent: Bool = false) throws {
        self.silent = silent
        phones = (1...2).map { PairedPeer(peerID: UUID(), ltk: Data(repeating: UInt8($0), count: 32), name: "Phone \($0)") }
        for phone in phones { try store.save(phone) }
        server = ControlListener(identity: identity, store: store)
    }

    func start() async throws -> NWEndpoint {
        listener?.cancel()
        let keys = try store.all().map { (SymmetricKey(data: $0.ltk), $0.peerID.uuidString.lowercased()) }
        let params = TLSConfig.parameters(control: TLSConfig.listenerOptions(keys: keys))
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                if self.silent {
                    self.silentConnections.append(connection)
                    connection.start(queue: .main)
                } else { self.server.accept(connection) }
            }
        }
        listener.start(queue: .main)
        for _ in 0..<100 {
            if let port = listener.port, port.rawValue != 0 { return .hostPort(host: "127.0.0.1", port: port) }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.timeout
    }

    /// A phone that sent HELLO, was admitted and then went silent without closing its connection. `claimed`: the phone
    /// whose ID the HELLO claims (default: its own; another one is a paired phone posing as it, L3).
    func admittedSilentConnection(endpoint: NWEndpoint, phone index: Int, claiming claimed: Int? = nil) async throws -> NWConnection {
        let options = TLSConfig.tlsOptions(psk: SymmetricKey(data: phones[index].ltk),
                                           identity: phones[index].peerID.uuidString.lowercased())
        let connection = NWConnection(to: endpoint, using: TLSConfig.parameters(control: options))
        connection.start(queue: .main)
        for _ in 0..<250 where connection.state != .ready { try await Task.sleep(for: .milliseconds(20)) }
        let claimedIndex = claimed ?? index
        try send(.hello(hello(claimedIndex)), on: connection)
        for _ in 0..<250 {
            if await server.coordinator.activeSession?.peer.peerID == phones[claimedIndex].peerID,
               server.connectedPeerID == phones[claimedIndex].peerID { return connection }
            try await Task.sleep(for: .milliseconds(20))
        }
        connection.cancel()
        throw Failure.timeout
    }

    /// Sends one control message as a phone would (framed), on a raw connection.
    func send(_ message: ControlMessage, on connection: NWConnection) throws {
        let bytes = try message.encode(sequence: 0, sentAt: MonotonicClock.nanoseconds())
        let context = NWConnection.ContentContext(identifier: "control", metadata: [NWProtocolFramer.Message(definition: TGControlFramer.definition)])
        connection.send(content: bytes, contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// A plain TCP endpoint whose far ends stay open and silent: connections that never send HELLO (M3).
    func silentTCPEndpoint() async throws -> NWEndpoint {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let sink = try NWListener(using: parameters)
        sinks.append(sink)
        sink.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                self.silentConnections.append(connection)
                connection.start(queue: .main)
            }
        }
        sink.start(queue: .main)
        for _ in 0..<100 {
            if let port = sink.port, port.rawValue != 0 { return .hostPort(host: "127.0.0.1", port: port) }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.timeout
    }

    func mac(for index: Int) -> PairedPeer {
        PairedPeer(peerID: identity.peerID, ltk: phones[index].ltk, name: identity.name)
    }

    func hello(_ index: Int) -> HelloMessage {
        HelloMessage(protocolVersion: 1, peerID: phones[index].peerID, name: phones[index].name,
            modelIdentifier: "iPhone16,2", surfaceWidthMM: 65, surfaceHeightMM: 141, ppi: 460,
            maxContacts: 10, displayHz: 120, caps: 0, trackingOverride: 0)
    }

    func stop() {
        for connection in silentConnections { connection.cancel() }
        for sink in sinks { sink.cancel() }
        server.stop()
        listener?.cancel()
        for phone in phones { try? store.delete(peerID: phone.peerID) }
    }
}
