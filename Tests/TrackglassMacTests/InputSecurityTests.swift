import CryptoKit
import Foundation
import Network
import TrackglassEngine
import TrackglassKit
import XCTest
@testable import TrackglassMac

final class InputSecurityTests: XCTestCase {
    func testFlowsFromUnknownSourcesAreBounded() {
        // Every UDP source becomes a flow on the input listener; a LAN host spraying datagrams from many ports must
        // not make them pile up for the length of a session.
        let listener = InputListener()
        listener.setAdmittedPeer(UUID(), geometry: EngineGeometry(widthMM: 100, heightMM: 60, isLandscape: true))
        var flows: [NWConnection] = []
        for port in UInt16(40_001)...UInt16(40_007) {
            let flow = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp)
            flows.append(flow)
            listener.accept(flow)
        }
        XCTAssertLessThanOrEqual(listener.flowCount, InputListener.maximumFlows)
        listener.setAdmittedPeer(nil)
        XCTAssertEqual(listener.flowCount, 0)
        flows.forEach { $0.cancel() }
    }

    func testASprayOfNewFlowsEvictsTheNewestHandshakeNotThePhones() {
        // M4: the phone's DTLS handshake starts right after admission, so it is the oldest one under way; a LAN host
        // spraying datagrams from new source ports must replace its own newest flow, not the phone's.
        let started: [Int: UInt64] = [1: 100, 2: 200, 3: 300, 4: 400]
        XCTAssertEqual(InputListener.evictionVictim(started: started, ready: []), 4)
        XCTAssertEqual(InputListener.evictionVictim(started: started, ready: [4]), 3, "a ready flow is not a handshake")
        // Every flow ready: the oldest goes (a phone that rebuilt its input connection left the previous one behind).
        XCTAssertEqual(InputListener.evictionVictim(started: started, ready: [1, 2, 3, 4]), 1)
        XCTAssertNil(InputListener.evictionVictim(started: [Int: UInt64](), ready: []))
    }

    func testWrongPSKCannotCompleteControlHandshake() async throws {
        let expected = SymmetricKey(data: Data(repeating: 0x31, count: 32))
        let listener = try makeListener(input: false, key: expected, identity: "expected-phone")
        let authenticated = expectation(description: "Wrong PSK delivered application data")
        authenticated.isInverted = true
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receiveMessage { data, _, _, error in
                if error == nil, data != nil { authenticated.fulfill() }
                connection.cancel()
            }
        }
        listener.start(queue: .main)
        let port = try await readyPort(listener)
        let wrong = SymmetricKey(data: Data(repeating: 0x72, count: 32))
        let client = NWConnection(host: "127.0.0.1", port: port,
            using: TLSConfig.parameters(control: TLSConfig.tlsOptions(psk: wrong, identity: "expected-phone")))
        client.stateUpdateHandler = { state in
            switch state {
            case .ready: authenticated.fulfill()
            default: break
            }
        }
        client.start(queue: .main)
        await fulfillment(of: [authenticated], timeout: 2)
        client.cancel()
        listener.cancel()
    }

    func testPlainUDPPayloadIsIgnoredByDTLSListener() async throws {
        let key = SymmetricKey(data: Data(repeating: 0x45, count: 32))
        let listener = try makeListener(input: true, key: key, identity: "active-phone")
        let accepted = expectation(description: "Plain UDP must not create an authenticated connection")
        accepted.isInverted = true
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receiveMessage { data, _, _, error in
                if error == nil, data != nil { accepted.fulfill() }
                connection.cancel()
            }
        }
        listener.start(queue: .main)
        let port = try await readyPort(listener)
        let sent = expectation(description: "Raw UDP probe sent")
        let raw = NWConnection(host: "127.0.0.1", port: port, using: .udp)
        raw.stateUpdateHandler = { state in
            if case .ready = state {
                raw.send(content: Data("plain-udp-probe".utf8), completion: .contentProcessed { error in
                    if error == nil { sent.fulfill() }
                })
            }
        }
        raw.start(queue: .main)
        await fulfillment(of: [sent, accepted], timeout: 2)
        raw.cancel()
        listener.cancel()
    }

    private func makeListener(input: Bool, key: SymmetricKey, identity: String) throws -> NWListener {
        let options = TLSConfig.listenerOptions(keys: [(key, identity)])
        let parameters = input ? TLSConfig.parameters(input: options) : TLSConfig.parameters(control: options)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        return try NWListener(using: parameters)
    }

    private func readyPort(_ listener: NWListener) async throws -> NWEndpoint.Port {
        for _ in 0..<250 {
            if let port = listener.port, port.rawValue != 0 { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "InputSecurityTests.ListenerNotReady", code: 1)
    }
}
