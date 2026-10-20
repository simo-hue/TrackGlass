import Foundation
import Network
import XCTest
@testable import TrackglassKit

final class ControlFramerTests: XCTestCase {
    func testThousandMessagesIncluding64KiB() throws {
        let done = expectation(description: "1000 framed messages arrive in order")
        let harness = try FramerHarness(done: done, fragmented: false)
        harness.start()
        wait(for: [done], timeout: 30)
        harness.stop()
    }

    func testFragmentedPrefixAndPayload() throws {
        let done = expectation(description: "Fragmented messages reassemble")
        let harness = try FramerHarness(done: done, fragmented: true)
        harness.start()
        wait(for: [done], timeout: 30)
        harness.stop()
    }
}

// All mutable connection state is confined to queue; the test thread only starts/stops it.
private final class FramerHarness: @unchecked Sendable {
    private let queue = DispatchQueue(label: "control-framer-tests")
    private let listener: NWListener
    private let done: XCTestExpectation
    private let fragmented: Bool
    private var client: NWConnection?
    private var server: NWConnection?
    private var received = 0
    private var finished = false
    private var count: Int { fragmented ? 20 : 1000 }

    init(done: XCTestExpectation, fragmented: Bool) throws {
        self.done = done
        self.fragmented = fragmented
        listener = try NWListener(using: Self.parameters(framed: true), on: .any)
    }

    private static func parameters(framed: Bool) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        if framed {
            parameters.defaultProtocolStack.applicationProtocols.insert(
                NWProtocolFramer.Options(definition: TGControlFramer.definition), at: 0)
        }
        return parameters
    }

    func start() {
        listener.newConnectionHandler = { connection in
            self.server = connection
            connection.start(queue: self.queue)
            self.receive(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = self.listener.port {
                let client = NWConnection(host: "127.0.0.1", port: port, using: Self.parameters(framed: !self.fragmented))
                self.client = client
                client.stateUpdateHandler = { state in
                    if case .ready = state { self.sendAll(client) }
                    if case .failed(let error) = state { self.fail(error) }
                }
                client.start(queue: self.queue)
            }
            if case .failed(let error) = state { self.fail(error) }
        }
        listener.start(queue: queue)
    }

    private func payload(_ index: Int) -> Data {
        let size = index == count - 1 ? 65_536 : 16 + (index * 137 % 2048)
        var data = Data(repeating: UInt8(truncatingIfNeeded: index), count: size)
        _ = try! data.withUnsafeMutableBytes {
            try MessageHeader(type: .ping, sequence: UInt32(index), sentAt: UInt64(index)).encode(into: $0)
        }
        return data
    }

    private func sendAll(_ connection: NWConnection) {
        for index in 0..<count {
            let data = payload(index)
            if fragmented {
                var length = UInt32(data.count).littleEndian
                var framed = withUnsafeBytes(of: &length) { Data($0) }
                framed.append(data)
                // Split inside the length prefix and the payload, including the maximum-size message.
                let boundaries = [0, 1, 3, 7, framed.count]
                for part in 0..<4 {
                    connection.send(content: framed.subdata(in: boundaries[part]..<boundaries[part + 1]),
                                    completion: .contentProcessed { if let error = $0 { self.fail(error) } })
                }
            } else {
                let context = NWConnection.ContentContext(identifier: "message", metadata: [
                    NWProtocolFramer.Message(definition: TGControlFramer.definition)
                ])
                connection.send(content: data, contentContext: context, isComplete: true,
                                completion: .contentProcessed { if let error = $0 { self.fail(error) } })
            }
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { data, _, complete, error in
            if let error { self.fail(error); return }
            guard let data else { self.fail(NWError.posix(.EIO)); return }
            XCTAssertTrue(complete)
            XCTAssertEqual(data, self.payload(self.received))
            self.received += 1
            if self.received == self.count {
                if !self.finished { self.finished = true; self.done.fulfill() }
            } else { self.receive(connection) }
        }
    }

    private func fail(_ error: NWError) {
        guard !finished else { return }
        finished = true
        XCTFail("Loopback failed: \(error)")
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
