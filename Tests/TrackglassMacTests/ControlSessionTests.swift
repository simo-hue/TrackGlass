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
        let stale = harness.client()
        let fresh = harness.client()
        defer { stale.disconnect(); fresh.disconnect() }
        let staleConnected = await stale.connect(endpoint: endpoint, mac: harness.mac(for: 0), hello: harness.hello(0))
        XCTAssertTrue(staleConnected)
        // Same peerID, new connection (Wi-Fi blip / relaunch): admitted immediately, never told it is busy with itself.
        let freshConnected = await fresh.connect(endpoint: endpoint, mac: harness.mac(for: 0), hello: harness.hello(0))
        XCTAssertTrue(freshConnected)
        try await eventually { fresh.isConnected && !stale.isConnected }
        let session = await harness.server.coordinator.activeSession
        XCTAssertEqual(session?.peer.peerID, harness.phones[0].peerID)
        XCTAssertFalse(fresh.status.contains("being used"))
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
        server.stop()
        listener?.cancel()
        for phone in phones { try? store.delete(peerID: phone.peerID) }
    }
}
