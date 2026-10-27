import XCTest
import Network
import TrackglassKit
@testable import TrackglassMac

final class PINPairingTests: XCTestCase {
    @MainActor func testPINExchangeUsesDerivedKey() async throws {
        let serverStore = PairingStore(service: "app.trackglass.tests.pin.mac.\(UUID())")
        let phoneStore = PairingStore(service: "app.trackglass.tests.pin.phone.\(UUID())")
        let mac = PeerIdentity(name: "PIN Mac")
        let request = PairRequestMessage(peerID: UUID(), name: "PIN Phone", modelIdentifier: "iPhone16,2", protocolVersion: 1)
        let service = PairingService(identity: mac, store: serverStore, authorized: { true })
        defer { service.close(); try? serverStore.delete(peerID: request.peerID); try? phoneStore.delete(peerID: mac.peerID) }
        service.open()
        let originalPairID = try XCTUnwrap(service.payload?.pairID)
        service.setMode(.pin)
        XCTAssertEqual(service.payload?.pairID, originalPairID)
        let endpoint = try await endpoint(of: service)
        let pin = try XCTUnwrap(service.pin)
        XCTAssertEqual(pin.utf8.count, 6)
        XCTAssertTrue(pin.utf8.allSatisfy { (48...57).contains($0) })
        let client = PairingClient(store: phoneStore)
        let peer = try await client.pair(pin: pin, pairID: originalPairID, endpoint: endpoint, expectedMacID: mac.peerID, request: request)
        XCTAssertEqual(try serverStore.load(peerID: request.peerID)?.ltk, peer.ltk)
        XCTAssertEqual(try phoneStore.load(peerID: mac.peerID)?.name, mac.name)
        XCTAssertNil(service.pin)
    }

    @MainActor func testWrongPINRotatesAndThreeFailuresExhaustWindow() async throws {
        let store = PairingStore(service: "app.trackglass.tests.pin.fail.\(UUID())")
        let mac = PeerIdentity(name: "Rotation Mac")
        let service = PairingService(identity: mac, store: store, authorized: { true })
        defer { service.close() }
        service.open()
        service.setMode(.pin)
        let client = PairingClient(store: store)
        let request = PairRequestMessage(peerID: UUID(), name: "Wrong PIN", modelIdentifier: "iPhone16,2", protocolVersion: 1)
        var lastEndpoint: NWEndpoint?
        var lastPairID: Data?
        var lastPIN: String?
        for generation in 1...3 {
            let endpoint = try await endpoint(of: service)
            let previous = try XCTUnwrap(service.payload)
            let oldPIN = try XCTUnwrap(service.pin)
            lastEndpoint = endpoint
            lastPairID = previous.pairID
            lastPIN = oldPIN
            XCTAssertEqual(service.pinGeneration, generation)
            let wrongPIN = oldPIN == "000000" ? "000001" : "000000"
            do {
                _ = try await client.pair(pin: wrongPIN, pairID: previous.pairID, endpoint: endpoint,
                                          expectedMacID: mac.peerID, request: request)
                XCTFail("Incorrect PIN was accepted")
            } catch {}
            for _ in 0..<250 {
                if !service.isOpen || service.pinGeneration > generation { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            if generation < 3 {
                XCTAssertTrue(service.isOpen)
                XCTAssertEqual(service.pinGeneration, generation + 1)
                XCTAssertNotEqual(service.pin, oldPIN)
                XCTAssertNotEqual(service.payload?.pairID, previous.pairID)
                XCTAssertNotEqual(service.payload?.pairSecret, previous.pairSecret)
            }
        }
        XCTAssertFalse(service.isOpen)
        XCTAssertEqual(service.pinGeneration, 3)
        XCTAssertNil(service.pin)
        XCTAssertNil(service.port)
        XCTAssertNil(service.payload)
        service.setMode(.qr)
        service.setMode(.pin)
        XCTAssertNil(service.port, "Mode switches cannot restore a fourth attempt")
        do {
            _ = try await client.pair(pin: XCTUnwrap(lastPIN), pairID: XCTUnwrap(lastPairID),
                                      endpoint: XCTUnwrap(lastEndpoint), expectedMacID: mac.peerID, request: request)
            XCTFail("A fourth connection using even the last correct PIN must fail")
        } catch {}
        XCTAssertTrue(try store.all().isEmpty)
        service.open()
        XCTAssertEqual(service.pinGeneration, 1, "Only a newly opened window resets the limit")
    }

    @MainActor func testModeSwitchDoesNotExtendWindowLifetime() async throws {
        let service = PairingService(identity: PeerIdentity(name: "Expiring Mac"),
                                     store: PairingStore(service: "app.trackglass.tests.expiry.\(UUID())"),
                                     authorized: { true }, windowLifetime: .seconds(2))
        defer { service.close() }
        service.open()
        _ = try await endpoint(of: service)
        try await Task.sleep(for: .milliseconds(1200))
        service.setMode(.pin)
        _ = try await endpoint(of: service)
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(service.isOpen)
        XCTAssertNil(service.payload)
        XCTAssertNil(service.pin)
    }

    @MainActor private func endpoint(of service: PairingService) async throws -> NWEndpoint {
        for _ in 0..<250 {
            if let port = service.port { return .hostPort(host: "127.0.0.1", port: port) }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "PINPairingTests.ListenerNotReady", code: 1)
    }
}
