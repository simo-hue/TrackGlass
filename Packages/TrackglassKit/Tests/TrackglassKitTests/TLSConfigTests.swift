import CryptoKit
import Foundation
import Network
import XCTest
@testable import TrackglassKit

final class TLSConfigTests: XCTestCase {
    func testMatchingKeyHandshake() throws {
        let done = expectation(description: "Authenticated loopback message")
        let harness = try TLSHarness(done: done, matchingKey: true)
        harness.start()
        wait(for: [done], timeout: 15)
        harness.stop()
    }

    func testWrongKeyHandshakeFails() throws {
        let done = expectation(description: "Wrong PSK rejected")
        let harness = try TLSHarness(done: done, matchingKey: false)
        harness.start()
        wait(for: [done], timeout: 15)
        harness.stop()
    }

    func testParameters() {
        let key = SymmetricKey(size: .bits256)
        for parameters in [TLSConfig.parameters(control: TLSConfig.tlsOptions(psk: key, identity: "peer")),
                           TLSConfig.parameters(input: TLSConfig.tlsOptions(psk: key, identity: "peer"))] {
            XCTAssertTrue(parameters.includePeerToPeer)
            XCTAssertTrue(parameters.allowLocalEndpointReuse)
            XCTAssertEqual(parameters.prohibitedInterfaceTypes, [.cellular])
            XCTAssertNil(parameters.requiredInterface)
        }
    }
}

// State and callbacks are confined to queue.
private final class TLSHarness: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tls-tests")
    private let listener: NWListener
    private let done: XCTestExpectation
    private let matchingKey: Bool
    private var client: NWConnection?
    private var server: NWConnection?
    private var finished = false
    private let identity = "00000000-0000-0000-0000-000000000001"

    init(done: XCTestExpectation, matchingKey: Bool) throws {
        self.done = done
        self.matchingKey = matchingKey
        let options = TLSConfig.listenerOptions(keys: [(SymmetricKey(data: Data(repeating: 0xA5, count: 32)), identity)])
        let parameters = TLSConfig.parameters(control: options)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() {
        listener.newConnectionHandler = { connection in
            self.server = connection
            connection.stateUpdateHandler = { state in
                if case .failed(let error) = state, self.matchingKey { self.finish(error: error) }
            }
            connection.start(queue: self.queue)
            connection.receiveMessage { data, _, complete, error in
                if let error {
                    if self.matchingKey { self.finish(error: error) }
                    return
                }
                XCTAssertTrue(self.matchingKey)
                XCTAssertTrue(complete)
                XCTAssertEqual(data, self.message())
                self.finish()
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { self.finish(error: error) }
            guard case .ready = state, let port = self.listener.port else { return }
            let key = SymmetricKey(data: Data(repeating: self.matchingKey ? 0xA5 : 0x5A, count: 32))
            let parameters = TLSConfig.parameters(control: TLSConfig.tlsOptions(psk: key, identity: self.identity))
            let client = NWConnection(host: "127.0.0.1", port: port, using: parameters)
            self.client = client
            client.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard self.matchingKey else {
                        XCTFail("Wrong PSK unexpectedly authenticated")
                        self.finish()
                        return
                    }
                    let context = NWConnection.ContentContext(identifier: "ping", metadata: [
                        NWProtocolFramer.Message(definition: TGControlFramer.definition)
                    ])
                    client.send(content: self.message(), contentContext: context, isComplete: true,
                                completion: .contentProcessed { if let error = $0 { self.finish(error: error) } })
                case .failed(let error), .waiting(let error):
                    if self.matchingKey { self.finish(error: error) }
                    else {
                        guard case .tls = error else { self.finish(error: error); return }
                        self.finish()
                    }
                default: break
                }
            }
            client.start(queue: self.queue)
        }
        listener.start(queue: queue)
    }

    private func message() -> Data {
        try! ControlMessage.ping(PingMessage(nonce: 42)).encode(sequence: 1, sentAt: 2)
    }

    private func finish(error: NWError? = nil) {
        guard !finished else { return }
        finished = true
        if let error { XCTFail("Unexpected TLS loopback failure: \(error)") }
        done.fulfill()
    }

    func stop() {
        queue.sync {
            finished = true
            client?.cancel()
            server?.cancel()
            listener.cancel()
        }
    }
}
