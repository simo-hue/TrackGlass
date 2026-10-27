import CryptoKit
import Foundation
import Network
import Security
import TrackglassKit
import XCTest

final class TLSGateTests: XCTestCase {
    func testTwoRegisteredKeysTLS() throws { try runGate(datagram: false) }
    func testTwoRegisteredKeysDTLS() throws { try runGate(datagram: true) }

    private func runGate(datagram: Bool) throws {
        let done = expectation(description: "Both identities exchange authenticated payloads")
        let gate = try MultiKeyGate(datagram: datagram, done: done)
        gate.start()
        wait(for: [done], timeout: 20)
        gate.stop()
    }
}

// All mutable state is confined to queue, including teardown.
private final class MultiKeyGate: @unchecked Sendable {
    private let queue = DispatchQueue(label: "trackglass.multi-key-gate")
    private let listener: NWListener
    private let datagram: Bool
    private let done: XCTestExpectation
    private let identities = ["00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000002"]
    private var clients: [NWConnection] = []
    private var servers: [NWConnection] = []
    private var received: Set<UInt8> = []
    private var finished = false

    init(datagram: Bool, done: XCTestExpectation) throws {
        self.datagram = datagram
        self.done = done
        let keys = identities.enumerated().map { index, identity in
            (SymmetricKey(data: Data(repeating: UInt8(index + 1), count: 32)), identity)
        }
        let options = TLSConfig.listenerOptions(keys: keys)
        let parameters = datagram ? TLSConfig.parameters(input: options) : TLSConfig.parameters(control: options)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() {
        listener.newConnectionHandler = { connection in
            self.servers.append(connection)
            connection.start(queue: self.queue)
            connection.receiveMessage { data, _, complete, error in
                if let error { self.finish(error: "Server receive: \(error)"); return }
                guard complete, let data, [self.message(1), self.message(2)].contains(data) else {
                    self.finish(error: "Invalid authenticated payload"); return
                }
                connection.send(content: data, contentContext: self.context(), isComplete: true,
                                completion: .contentProcessed { error in
                    if let error { self.finish(error: "Server send: \(error)") }
                })
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { self.finish(error: "Listener: \(error)") }
            guard case .ready = state, let port = self.listener.port, self.clients.isEmpty else { return }
            for (index, identity) in self.identities.enumerated() {
                let id = UInt8(index + 1)
                let options = TLSConfig.tlsOptions(psk: SymmetricKey(data: Data(repeating: id, count: 32)), identity: identity)
                let parameters = self.datagram ? TLSConfig.parameters(input: options) : TLSConfig.parameters(control: options)
                let client = NWConnection(host: "127.0.0.1", port: port, using: parameters)
                self.clients.append(client)
                client.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard let metadata = client.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
                            self.finish(error: "Missing TLS metadata"); return
                        }
                        let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata)
                        XCTAssertEqual(version, self.datagram ? .DTLSv12 : .TLSv12)
                        client.send(content: self.message(id), contentContext: self.context(), isComplete: true,
                                    completion: .contentProcessed { error in
                            if let error { self.finish(error: "Client \(id) send: \(error)") }
                        })
                        client.receiveMessage { data, _, complete, error in
                            if let error { self.finish(error: "Client \(id) receive: \(error)"); return }
                            guard complete, data == self.message(id) else {
                                self.finish(error: "Client \(id) echo mismatch"); return
                            }
                            self.received.insert(id)
                            if self.received.count == 2 { self.finish() }
                        }
                    case .waiting(let error), .failed(let error):
                        self.finish(error: "Client \(id) handshake: \(error)")
                    default: break
                    }
                }
                client.start(queue: self.queue)
            }
        }
        listener.start(queue: queue)
    }

    private func message(_ id: UInt8) -> Data {
        try! ControlMessage.ping(PingMessage(nonce: UInt32(id))).encode(sequence: 0, sentAt: 0)
    }

    private func context() -> NWConnection.ContentContext {
        if datagram { return .defaultMessage }
        return NWConnection.ContentContext(identifier: "gate", metadata: [
            NWProtocolFramer.Message(definition: TGControlFramer.definition)
        ])
    }

    private func finish(error: String? = nil) {
        guard !finished else { return }
        finished = true
        if let error { XCTFail(error) }
        done.fulfill()
    }

    func stop() {
        queue.sync {
            finished = true
            for connection in clients + servers { connection.cancel() }
            listener.cancel()
        }
    }
}
