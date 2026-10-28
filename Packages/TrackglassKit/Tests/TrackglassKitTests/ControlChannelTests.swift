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

    func testByeReasonsMapToUserFacingMessagesOnThePeer() async throws {
        // reason 1 → "Incompatible version", reason 3 → "Pair again", anything else → "Disconnected".
        for (reason, expected) in [(UInt8(1), "Incompatible version"), (3, "Pair again"), (4, "Disconnected")] {
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
            listener.cancel(); box.servers.forEach { $0.close() }
        }
    }
}

@MainActor private final class Box {
    var servers: [ControlChannel] = []
    var serverClosedWith: String?
}
