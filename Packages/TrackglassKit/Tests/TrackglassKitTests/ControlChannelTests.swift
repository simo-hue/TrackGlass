import Foundation
import Network
import XCTest
@testable import TrackglassKit

/// Loopback over plain TCP + the control framer (no TLS): exercises the channel's own state machine.
@MainActor
final class ControlChannelTests: XCTestCase {
    private static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolFramer.Options(definition: TGControlFramer.definition), at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        return parameters
    }

    private func listener(onConnection: @escaping @Sendable (NWConnection) -> Void) async throws -> (NWListener, NWEndpoint) {
        let listener = try NWListener(using: Self.parameters())
        listener.newConnectionHandler = onConnection
        listener.start(queue: .main)
        for _ in 0..<100 {
            if let port = listener.port, port.rawValue != 0 { return (listener, .hostPort(host: "127.0.0.1", port: port)) }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("listener did not start"); throw CancellationError()
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<250 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("condition not met within five seconds")
    }

    func testSilentPeerIsClosedByTheHandshakeWatchdog() async throws {
        let (listener, endpoint) = try await listener { connection in connection.start(queue: .main) }   // accepts, never speaks
        defer { listener.cancel() }
        let channel = ControlChannel(connection: NWConnection(to: endpoint, using: Self.parameters()))
        channel.handshakeTimeout = .milliseconds(300)
        var closedWith: String?
        channel.onClose = { closedWith = $0 }
        channel.start()
        try await eventually { closedWith != nil }
        XCTAssertEqual(closedWith, "Connection timed out")
    }

    func testHeartbeatStartCancelsTheWatchdogAndCloseIsIdempotent() async throws {
        let box = Box()
        let (listener, endpoint) = try await listener { connection in
            Task { @MainActor in
                // The server answers PINGs with PONGs, so the client's heartbeat stays alive.
                let server = ControlChannel(connection: connection)
                server.onMessage = { _ in }
                server.start(); server.startHeartbeat()
                box.servers.append(server)
            }
        }
        defer { listener.cancel(); box.servers.forEach { $0.close() } }
        let channel = ControlChannel(connection: NWConnection(to: endpoint, using: Self.parameters()))
        channel.handshakeTimeout = .milliseconds(300)
        var closeCount = 0
        var ready = false
        channel.onReady = { ready = true; channel.startHeartbeat() }
        channel.onClose = { _ in closeCount += 1 }
        channel.start()
        try await eventually { ready }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(closeCount, 0, "a channel with a running heartbeat must survive the handshake timeout")
        channel.close(); channel.close()
        XCTAssertEqual(closeCount, 1)
    }

    /// A framed peer that answers PINGs only when `answers(nonce)` says so — the channel's own
    /// `ControlChannel` always answers, so selective loss needs a hand-rolled server.
    nonisolated private static func selectivePongServer(_ connection: NWConnection, answers: @escaping @Sendable (UInt32) -> Bool) {
        @Sendable func receive() {
            connection.receiveMessage { data, _, _, error in
                guard error == nil, let data, let packet = try? ControlMessage.decode(data) else { return }
                if case .ping(let ping) = packet.message, answers(ping.nonce) {
                    let pong = ControlMessage.pong(PongMessage(nonce: ping.nonce, echoSentAt: packet.header.sentAt))
                    if let bytes = try? pong.encode(sequence: 0, sentAt: MonotonicClock.nanoseconds()) {
                        let context = NWConnection.ContentContext(identifier: "control", metadata: [
                            NWProtocolFramer.Message(definition: TGControlFramer.definition)
                        ])
                        connection.send(content: bytes, contentContext: context, isComplete: true, completion: .idempotent)
                    }
                }
                receive()
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func testEveryOtherPingAnsweredKeepsTheChannelAlive() async throws {
        // §4.6 / Appendix A: "3 missed = dead" counts consecutive misses. A peer that skips every other
        // PING never misses three in a row, so the channel must stay open (the old cumulative count
        // closed it after the third skipped ping).
        let (listener, endpoint) = try await listener { connection in
            Self.selectivePongServer(connection) { nonce in nonce.isMultiple(of: 2) }
        }
        defer { listener.cancel() }
        let channel = ControlChannel(connection: NWConnection(to: endpoint, using: Self.parameters()))
        channel.heartbeatInterval = .milliseconds(100)
        var closedWith: String?
        var rtts = 0
        channel.onReady = { channel.startHeartbeat() }
        channel.onClose = { closedWith = $0 }
        channel.onRTT = { _ in rtts += 1 }
        channel.start()
        try await Task.sleep(for: .milliseconds(1500))   // ≈ 15 pings, 7 of them skipped
        XCTAssertNil(closedWith, "alternating misses are never three consecutive misses")
        XCTAssertGreaterThanOrEqual(rtts, 4)
        channel.close()
    }

    func testThreeConsecutiveMissesCloseTheChannel() async throws {
        // The peer answers the first two pings, then falls silent: closed once the third unanswered
        // ping is three intervals old, i.e. after about five intervals in total.
        let (listener, endpoint) = try await listener { connection in
            Self.selectivePongServer(connection) { nonce in nonce <= 2 }
        }
        defer { listener.cancel() }
        let channel = ControlChannel(connection: NWConnection(to: endpoint, using: Self.parameters()))
        channel.heartbeatInterval = .milliseconds(100)
        var closedWith: String?
        channel.onReady = { channel.startHeartbeat() }
        channel.onClose = { closedWith = $0 }
        channel.start()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertNil(closedWith, "two answered pings and one miss are not a dead link")
        try await eventually { closedWith != nil }
        XCTAssertEqual(closedWith, "Connection timed out")
    }

    func testOversizedLengthPrefixFailsTheConnection() async throws {
        // §4.3: the framer rejects a prefix above 64 KiB (and below the header size) by failing the connection,
        // so a malformed peer cannot make the receiver allocate.
        let box = Box()
        let (listener, endpoint) = try await listener { connection in
            Task { @MainActor in
                let server = ControlChannel(connection: connection)
                server.onMessage = { _ in }
                server.onClose = { box.serverClosedWith = $0 }
                server.start()
                box.servers.append(server)
            }
        }
        defer { listener.cancel(); box.servers.forEach { $0.close() } }
        let raw = NWConnection(to: endpoint, using: .tcp)   // no framer: we write the prefix ourselves
        raw.start(queue: .main)
        try await eventually { raw.state == .ready }
        raw.send(content: Data([0xFF, 0xFF, 0xFF, 0xFF, 0x54, 0x47, 0x01, 0x05]), completion: .idempotent)
        try await eventually { box.serverClosedWith != nil }
        XCTAssertNotNil(box.serverClosedWith)
        raw.cancel()
    }

    func testHeaderWithAnotherProtocolVersionGetsAnIncompatibleBye() async throws {
        // §4.1: a receiver that sees version != 1 sends BYE{reason: incompatible} and disconnects.
        let box = Box()
        let (listener, endpoint) = try await listener { connection in
            Task { @MainActor in
                let server = ControlChannel(connection: connection)
                server.onMessage = { _ in }
                server.onClose = { box.serverClosedWith = $0 }
                server.start()
                box.servers.append(server)
            }
        }
        defer { listener.cancel(); box.servers.forEach { $0.close() } }
        let client = NWConnection(to: endpoint, using: Self.parameters())   // framed, but we write the message bytes ourselves
        client.start(queue: .main)
        try await eventually { client.state == .ready }
        var message = Data([0x54, 0x47, 0x02, MessageType.ping.rawValue])  // magic, version 2, PING
        message.append(Data(count: 12))                                      // sequence + sentAt
        message.append(Data([1, 0, 0, 0]))                                   // nonce
        let context = NWConnection.ContentContext(identifier: "control", metadata: [NWProtocolFramer.Message(definition: TGControlFramer.definition)])
        client.send(content: message, contentContext: context, isComplete: true, completion: .idempotent)
        client.receiveMessage { data, _, _, _ in
            let decoded = data.flatMap { try? ControlMessage.decode($0).message }
            Task { @MainActor in box.reply = decoded }
        }
        try await eventually { box.reply != nil && box.serverClosedWith != nil }
        XCTAssertEqual(box.reply, .bye(ByeMessage(reason: 1)))
        XCTAssertEqual(box.serverClosedWith, "Incompatible version")
        client.cancel()
    }

    func testUnknownMessageTypeIsIgnoredAndTheChannelKeepsReceiving() async throws {
        // §4.1: an unknown `type` is logged once and ignored — the rule that lets a newer peer add messages.
        let box = Box()
        let (listener, endpoint) = try await listener { connection in
            Task { @MainActor in
                let server = ControlChannel(connection: connection)
                server.onMessage = { _ in }
                server.onClose = { box.serverClosedWith = $0 }
                server.start()
                box.servers.append(server)
            }
        }
        defer { listener.cancel(); box.servers.forEach { $0.close() } }
        let client = NWConnection(to: endpoint, using: Self.parameters())
        client.start(queue: .main)
        try await eventually { client.state == .ready }
        let context = NWConnection.ContentContext(identifier: "control", metadata: [NWProtocolFramer.Message(definition: TGControlFramer.definition)])
        var unknown = Data([0x54, 0x47, 0x01, 0xF0])   // magic, version 1, a type this version does not know
        unknown.append(Data(count: 12))
        unknown.append(Data([1, 2, 3]))
        client.send(content: unknown, contentContext: context, isComplete: true, completion: .idempotent)
        let ping = try ControlMessage.ping(PingMessage(nonce: 77)).encode(sequence: 1, sentAt: 5)
        client.send(content: ping, contentContext: context, isComplete: true, completion: .idempotent)
        client.receiveMessage { data, _, _, _ in
            let decoded = data.flatMap { try? ControlMessage.decode($0).message }
            Task { @MainActor in box.reply = decoded }
        }
        try await eventually { box.reply != nil }
        XCTAssertEqual(box.reply, .pong(PongMessage(nonce: 77, echoSentAt: 5)))
        XCTAssertNil(box.serverClosedWith, "an unknown type must not close the channel")
        client.cancel()
    }

    func testUndecodableMessageGetsAByeBeforeTheChannelCloses() async throws {
        let box = Box()
        let (listener, endpoint) = try await listener { connection in
            Task { @MainActor in
                let server = ControlChannel(connection: connection)
                server.onMessage = { _ in }
                server.onClose = { box.serverClosedWith = $0 }
                server.start()
                box.servers.append(server)
            }
        }
        defer { listener.cancel(); box.servers.forEach { $0.close() } }
        let client = NWConnection(to: endpoint, using: Self.parameters())
        client.start(queue: .main)
        try await eventually { client.state == .ready }
        var truncated = Data([0x54, 0x47, 0x01, MessageType.pong.rawValue])   // PONG without its payload
        truncated.append(Data(count: 12))
        let context = NWConnection.ContentContext(identifier: "control", metadata: [NWProtocolFramer.Message(definition: TGControlFramer.definition)])
        client.send(content: truncated, contentContext: context, isComplete: true, completion: .idempotent)
        client.receiveMessage { data, _, _, _ in
            let decoded = data.flatMap { try? ControlMessage.decode($0).message }
            Task { @MainActor in box.reply = decoded }
        }
        try await eventually { box.reply != nil && box.serverClosedWith != nil }
        XCTAssertEqual(box.reply, .bye(ByeMessage(reason: 1)))
        client.cancel()
    }

    func testLengthPrefixShorterThanAHeaderFailsTheConnection() async throws {
        // §4.3: a length below the 16-byte header cannot hold a message; the framer fails the connection.
        let box = Box()
        let (listener, endpoint) = try await listener { connection in
            Task { @MainActor in
                let server = ControlChannel(connection: connection)
                server.onMessage = { _ in }
                server.onClose = { box.serverClosedWith = $0 }
                server.start()
                box.servers.append(server)
            }
        }
        defer { listener.cancel(); box.servers.forEach { $0.close() } }
        let raw = NWConnection(to: endpoint, using: .tcp)
        raw.start(queue: .main)
        try await eventually { raw.state == .ready }
        raw.send(content: Data([8, 0, 0, 0, 0x54, 0x47, 0x01, 0x04, 0, 0, 0, 0]), completion: .idempotent)
        try await eventually { box.serverClosedWith != nil }
        XCTAssertNotNil(box.serverClosedWith)
        raw.cancel()
    }

    func testByeReasonsMapToUserFacingMessagesOnThePeer() async throws {
        // §4.5: 1 incompatible, 2 busy, 3 unpaired, 4 sleeping; 0 (user) and anything unknown → "Disconnected".
        for (reason, expected) in [(UInt8(1), "Incompatible version"), (2, "The Mac is busy"), (3, "Pair again"),
                                   (4, "The Mac went to sleep"), (5, "Disconnected on the Mac"), (0, "Disconnected"), (9, "Disconnected")] {
            let box = Box()
            let (listener, endpoint) = try await listener { connection in
                Task { @MainActor in
                    let server = ControlChannel(connection: connection)
                    server.onMessage = { _ in }
                    server.onClose = { box.serverClosedWith = $0 }
                    server.start()
                    box.servers.append(server)
                }
            }
            let channel = ControlChannel(connection: NWConnection(to: endpoint, using: Self.parameters()))
            var clientClosed: String?
            channel.onClose = { clientClosed = $0 }
            channel.onReady = { channel.end(reason: reason, message: "sent bye") }
            channel.start()
            try await eventually { clientClosed != nil && box.serverClosedWith != nil }
            XCTAssertEqual(clientClosed, "sent bye")
            XCTAssertEqual(box.serverClosedWith, expected, "reason \(reason)")
            XCTAssertEqual(box.servers.last?.closedFinally, reason == 1 || reason == 3 || reason == 5,
                           "only unpaired, incompatible and disconnected-on-the-Mac are final")
            listener.cancel(); box.servers.forEach { $0.close() }
        }
    }
}

@MainActor private final class Box {
    var servers: [ControlChannel] = []
    var serverClosedWith: String?
    var reply: ControlMessage?
}
