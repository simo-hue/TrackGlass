import Foundation
import Network
import TrackglassKit
import XCTest
@testable import TrackglassMac

/// The pairing listener has one slot (§3.4). A connection that never gets to PAIR_REQUEST must not hold it.
@MainActor
final class PairingSlotTests: XCTestCase {
    func testSilentConnectionIsDroppedWithoutSpendingTheCode() async throws {
        let service = PairingService(identity: PeerIdentity(name: "Slot Mac"),
                                     store: PairingStore(service: "app.trackglass.tests.slot.\(UUID())"),
                                     authorized: { true }, requestTimeout: .milliseconds(300), approvalPolicy: { _ in true })
        defer { service.close() }
        service.open()
        let port = try await port(of: service)
        let payload = try XCTUnwrap(service.payload)
        let stray = NWConnection(host: "127.0.0.1", port: port, using: .tcp)   // e.g. a port scan that stays open
        defer { stray.cancel() }
        stray.start(queue: .main)
        try await eventually { service.connectionCount == 1 }
        try await eventually { service.connectionCount == 0 }
        XCTAssertTrue(service.isOpen)
        XCTAssertFalse(service.isFinished)
        XCTAssertEqual(service.payload?.pairID, payload.pairID, "a connection that never tried the key must not rotate the code")
        XCTAssertEqual(service.payload?.pairSecret, payload.pairSecret)
    }

    /// §3.4 (2026-10-31): in code mode too, a connection that never completes TLS or never sends PAIR_REQUEST loses
    /// the slot after the request timeout and is not one of the window's code sessions.
    func testSilentConnectionInCodeModeIsNotASession() async throws {
        let service = PairingService(identity: PeerIdentity(name: "Code Slot Mac"),
                                     store: PairingStore(service: "app.trackglass.tests.slot.code.\(UUID())"),
                                     authorized: { true }, requestTimeout: .milliseconds(300), approvalPolicy: { _ in true })
        defer { service.close() }
        service.open()
        service.setMode(.code)
        let port = try await port(of: service)
        for _ in 0..<(PairingService.maxCodeSessions + 1) {
            let stray = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            defer { stray.cancel() }
            stray.start(queue: .main)
            try await eventually { service.connectionCount == 1 }
            try await eventually { service.connectionCount == 0 }
        }
        XCTAssertTrue(service.isOpen)
        XCTAssertEqual(service.codeSessions, 0)
        XCTAssertEqual(service.mode, .code)
    }

    func testStalledConnectionIsDroppedAndThePhoneThenPairs() async throws {
        let macID = UUID(), phoneID = UUID()
        let serverStore = PairingStore(service: "app.trackglass.tests.slot.mac.\(UUID())")
        let phoneStore = PairingStore(service: "app.trackglass.tests.slot.phone.\(UUID())")
        let service = PairingService(identity: PeerIdentity(peerID: macID, name: "Busy Slot Mac"), store: serverStore,
                                     authorized: { true }, requestTimeout: .milliseconds(300), approvalPolicy: { _ in true })
        defer { service.close(); try? serverStore.delete(peerID: phoneID); try? phoneStore.delete(peerID: macID) }
        service.open()
        let port = try await port(of: service)
        let payload = try XCTUnwrap(service.payload)
        let stray = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        defer { stray.cancel() }
        stray.start(queue: .main)
        try await eventually { service.connectionCount == 1 }
        // The stray never sends PAIR_REQUEST: it loses the slot (a newcomer never evicts it, §3.4 code limit).
        try await eventually { service.connectionCount == 0 }
        let request = PairRequestMessage(peerID: phoneID, name: "Late Phone", modelIdentifier: "iPhone16,2", protocolVersion: 1)
        let mac = try await PairingClient(store: phoneStore).pair(payload: payload, endpoint: .hostPort(host: "127.0.0.1", port: port),
                                                                 expectedMacID: macID, request: request)
        XCTAssertEqual(mac.peerID, macID)
        XCTAssertNotNil(try serverStore.load(peerID: phoneID))
        try await eventually { service.isFinished }
        XCTAssertTrue(service.didPair, "the window offers “Pair another device”")
        service.open()
        XCTAssertFalse(service.isFinished)
        XCTAssertFalse(service.didPair)
    }

    private func port(of service: PairingService) async throws -> NWEndpoint.Port {
        for _ in 0..<250 {
            if let port = service.port { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "PairingSlotTests.ListenerNotReady", code: 1)
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<250 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Pairing slot did not reach the expected state within five seconds", file: file, line: line)
        throw NSError(domain: "PairingSlotTests.Timeout", code: 2)
    }
}
