import XCTest
import Network
import CoreImage
import TrackglassKit
@testable import TrackglassMac

final class PairingExchangeTests: XCTestCase {
    @MainActor func testQRExchangeStoresBothPeersAndRejectsReplay() async throws {
        let macID = UUID()
        let phoneID = UUID()
        let serverStore = PairingStore(service: "app.trackglass.tests.mac.\(UUID())")
        let phoneStore = PairingStore(service: "app.trackglass.tests.phone.\(UUID())")
        let service = PairingService(identity: PeerIdentity(peerID: macID, name: "Test Mac"), store: serverStore, authorized: { true },
                                     approvalPolicy: { _ in true })
        defer {
            service.close()
            try? serverStore.delete(peerID: phoneID)
            try? phoneStore.delete(peerID: macID)
        }
        service.open()
        let port = try await port(of: service)
        let payload = try XCTUnwrap(service.payload)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let request = PairRequestMessage(peerID: phoneID, name: "Simone’s phone", modelIdentifier: "iPhone16,2", protocolVersion: 1)
        let client = PairingClient(store: phoneStore)
        let mac = try await client.pair(payload: payload, endpoint: endpoint, expectedMacID: macID, request: request)
        XCTAssertEqual(mac.name, "Test Mac")
        let phone = try XCTUnwrap(serverStore.load(peerID: phoneID))
        XCTAssertEqual(phone.name, request.name)
        XCTAssertEqual(phone.ltk.count, 32)
        XCTAssertEqual(phone.ltk, mac.ltk)
        XCTAssertEqual(try phoneStore.load(peerID: macID)?.ltk, phone.ltk)
        XCTAssertNil(service.payload, "A used QR must no longer be shown")
        XCTAssertNil(service.port, "The pairing listener must stop")
        do {
            // `replacingExisting`: get past the phone's own replace check (L4) to the Mac, which must refuse the code.
            _ = try await client.pair(payload: payload, endpoint: endpoint, expectedMacID: macID, request: request, replacingExisting: true)
            XCTFail("Used QR was accepted again")
        } catch {}
        XCTAssertEqual(try serverStore.all().count, 1)
    }

    /// §3.4 (round 4, L4): a scanned code or link never silently replaces this device's pairing with the same Mac.
    @MainActor func testQRPairingAsksBeforeReplacingAnExistingPairing() async throws {
        let macID = UUID(), phoneID = UUID()
        let serverStore = PairingStore(service: "app.trackglass.tests.replace.mac.\(UUID())")
        let phoneStore = PairingStore(service: "app.trackglass.tests.replace.phone.\(UUID())")
        let service = PairingService(identity: PeerIdentity(peerID: macID, name: "Office Mac"), store: serverStore, authorized: { true },
                                     approvalPolicy: { _ in true })
        defer { service.close(); try? serverStore.delete(peerID: phoneID); try? phoneStore.delete(peerID: macID) }
        let old = PairedPeer(peerID: macID, ltk: Data(repeating: 0x42, count: 32), name: "Old Office Mac",
                             pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try phoneStore.save(old)
        service.open()
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: try await port(of: service))
        let payload = try XCTUnwrap(service.payload)
        let request = PairRequestMessage(peerID: phoneID, name: "Phone", modelIdentifier: "iPhone16,2", protocolVersion: 1)
        let client = PairingClient(store: phoneStore)
        do {
            _ = try await client.pair(payload: payload, endpoint: endpoint, expectedMacID: macID, request: request)
            XCTFail("An existing pairing was replaced without asking")
        } catch PairingClient.Failure.alreadyPaired(let name) {
            XCTAssertEqual(name, "Old Office Mac", "the question names the stored pairing, not the link")
        } catch { XCTFail("Expected alreadyPaired, got \(error)") }
        XCTAssertEqual(try phoneStore.load(peerID: macID), old)
        XCTAssertEqual(service.connectionCount, 0, "nothing was sent before the user decided")
        XCTAssertNotNil(service.payload, "the code is still unused")
        let mac = try await client.pair(payload: payload, endpoint: endpoint, expectedMacID: macID, request: request, replacingExisting: true)
        XCTAssertNotEqual(mac.ltk, old.ltk)
        XCTAssertEqual(try phoneStore.load(peerID: macID)?.ltk, mac.ltk)
        XCTAssertEqual(try serverStore.load(peerID: phoneID)?.ltk, mac.ltk)
    }

    /// §3.4 (2026-10-31): the prompt and the stored record never carry control or bidi characters, nor a 64 KiB name.
    @MainActor func testPromptShowsTheSanitizedPhoneName() async throws {
        let macID = UUID(), phoneID = UUID()
        let serverStore = PairingStore(service: "app.trackglass.tests.sanitize.mac.\(UUID())")
        let phoneStore = PairingStore(service: "app.trackglass.tests.sanitize.phone.\(UUID())")
        let service = PairingService(identity: PeerIdentity(peerID: macID, name: "Mac"), store: serverStore, authorized: { true })
        defer { service.close(); try? serverStore.delete(peerID: phoneID); try? phoneStore.delete(peerID: macID) }
        service.open()
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: try await port(of: service))
        let payload = try XCTUnwrap(service.payload)
        let name = "  Sam’s\u{202E}enohPi\u{202C}\n\n" + String(repeating: "x", count: 100)
        let request = PairRequestMessage(peerID: phoneID, name: name, modelIdentifier: "iPhone16,1", protocolVersion: 1)
        let client = PairingClient(store: phoneStore)
        let pairing = Task { @MainActor in try await client.pair(payload: payload, endpoint: endpoint, expectedMacID: macID, request: request) }
        for _ in 0..<250 where service.pendingApproval == nil { try await Task.sleep(for: .milliseconds(20)) }
        let pending = try XCTUnwrap(service.pendingApproval)
        XCTAssertEqual(pending.phoneName, PairingText.sanitizedName(name))
        XCTAssertTrue(pending.phoneName.hasPrefix("Sam’senohPi xxx"), pending.phoneName)
        XCTAssertEqual(pending.phoneName.count, 40)
        XCTAssertNil(pending.code, "the QR path asks without a comparison code")
        service.respondToPendingPairing(allow: true)
        _ = try await pairing.value
        XCTAssertEqual(try serverStore.load(peerID: phoneID)?.name, pending.phoneName)
    }

    @MainActor func testPairingWaitsForTheUsersAllowClickBeforeStoringAnything() async throws {
        // §3.4 hardening (2026-10-28): nothing is stored and no key material leaves the Mac until Allow is clicked.
        let macID = UUID(), phoneID = UUID()
        let serverStore = PairingStore(service: "app.trackglass.tests.allow.mac.\(UUID())")
        let phoneStore = PairingStore(service: "app.trackglass.tests.allow.phone.\(UUID())")
        let service = PairingService(identity: PeerIdentity(peerID: macID, name: "Asking Mac"), store: serverStore, authorized: { true })
        defer { service.close(); try? serverStore.delete(peerID: phoneID); try? phoneStore.delete(peerID: macID) }
        service.open()
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: try await port(of: service))
        let payload = try XCTUnwrap(service.payload)
        let request = PairRequestMessage(peerID: phoneID, name: "Held Phone", modelIdentifier: "iPhone16,1", protocolVersion: 1)
        let client = PairingClient(store: phoneStore)
        let pairing = Task { @MainActor in try await client.pair(payload: payload, endpoint: endpoint, expectedMacID: macID, request: request) }
        for _ in 0..<250 where service.pendingApproval == nil { try await Task.sleep(for: .milliseconds(20)) }
        let pending = try XCTUnwrap(service.pendingApproval, "the Mac must ask before answering")
        XCTAssertEqual(pending.phoneName, "Held Phone")
        XCTAssertEqual(pending.modelName, "iPhone 15 Pro")
        XCTAssertTrue(try serverStore.all().isEmpty, "nothing is stored before Allow")
        XCTAssertNil(try phoneStore.load(peerID: macID))
        service.respondToPendingPairing(allow: true)
        let mac = try await pairing.value
        XCTAssertNil(service.pendingApproval)
        XCTAssertEqual(try serverStore.load(peerID: phoneID)?.ltk, mac.ltk, "both sides derived the same LTK")
        XCTAssertEqual(mac.ltk.count, 32)
    }

    @MainActor func testDeclinedPairingStoresNothingAndTellsThePhone() async throws {
        let macID = UUID(), phoneID = UUID()
        let serverStore = PairingStore(service: "app.trackglass.tests.deny.mac.\(UUID())")
        let phoneStore = PairingStore(service: "app.trackglass.tests.deny.phone.\(UUID())")
        let service = PairingService(identity: PeerIdentity(peerID: macID, name: "Careful Mac"), store: serverStore,
                                     authorized: { true }, approvalPolicy: { _ in false })
        defer { service.close() }
        service.open()
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: try await port(of: service))
        let payload = try XCTUnwrap(service.payload)
        let client = PairingClient(store: phoneStore)
        do {
            _ = try await client.pair(payload: payload, endpoint: endpoint, expectedMacID: macID,
                                      request: PairRequestMessage(peerID: phoneID, name: "Stranger", modelIdentifier: "iPhone16,2", protocolVersion: 1))
            XCTFail("A declined pairing succeeded")
        } catch PairingClient.Failure.declined {
        } catch { XCTFail("Expected the declined error, got \(error)") }
        XCTAssertTrue(try serverStore.all().isEmpty)
        XCTAssertTrue(try phoneStore.all().isEmpty)
        XCTAssertFalse(service.isOpen, "a declined attempt spends the window")
        XCTAssertNil(service.payload)
    }

    @MainActor func testClosingTheWindowWhileAskingDeclines() async throws {
        let macID = UUID()
        let serverStore = PairingStore(service: "app.trackglass.tests.closeask.mac.\(UUID())")
        let phoneStore = PairingStore(service: "app.trackglass.tests.closeask.phone.\(UUID())")
        let service = PairingService(identity: PeerIdentity(peerID: macID, name: "Closing Mac"), store: serverStore, authorized: { true })
        defer { service.close() }
        service.open()
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: try await port(of: service))
        let payload = try XCTUnwrap(service.payload)
        let client = PairingClient(store: phoneStore)
        let pairing = Task { @MainActor in
            try await client.pair(payload: payload, endpoint: endpoint, expectedMacID: macID,
                                  request: PairRequestMessage(peerID: UUID(), name: "Phone", modelIdentifier: "iPhone16,2", protocolVersion: 1))
        }
        for _ in 0..<250 where service.pendingApproval == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(service.pendingApproval)
        service.close()
        XCTAssertNil(service.pendingApproval)
        do { _ = try await pairing.value; XCTFail("Closing the window must not pair") } catch {}
        XCTAssertTrue(try serverStore.all().isEmpty)
    }

    /// §3.4: the window's expiry also ends an unanswered Allow question (the phone gets BYE{0}, nothing is stored).
    @MainActor func testExpiryWhileAskingDeclines() async throws {
        let macID = UUID()
        let serverStore = PairingStore(service: "app.trackglass.tests.expireask.mac.\(UUID())")
        let phoneStore = PairingStore(service: "app.trackglass.tests.expireask.phone.\(UUID())")
        let service = PairingService(identity: PeerIdentity(peerID: macID, name: "Expiring Mac"), store: serverStore,
                                     authorized: { true }, windowLifetime: .seconds(2))
        defer { service.close() }
        service.open()
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: try await port(of: service))
        let payload = try XCTUnwrap(service.payload)
        let client = PairingClient(store: phoneStore)
        let pairing = Task { @MainActor in
            try await client.pair(payload: payload, endpoint: endpoint, expectedMacID: macID,
                                  request: PairRequestMessage(peerID: UUID(), name: "Phone", modelIdentifier: "iPhone16,2", protocolVersion: 1))
        }
        for _ in 0..<100 where service.pendingApproval == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(service.pendingApproval)
        do { _ = try await pairing.value; XCTFail("An unanswered question must expire with the window") } catch {}
        XCTAssertNil(service.pendingApproval)
        XCTAssertFalse(service.isOpen)
        XCTAssertTrue(try serverStore.all().isEmpty)
    }

    @MainActor func testClosingWindowRejectsOldCode() async throws {
        let store = PairingStore(service: "app.trackglass.tests.closed.\(UUID())")
        let identity = PeerIdentity(name: "Closed Mac")
        let service = PairingService(identity: identity, store: store, authorized: { true }, approvalPolicy: { _ in true })
        service.open()
        let port = try await port(of: service)
        let payload = try XCTUnwrap(service.payload)
        service.close()
        XCTAssertFalse(service.isOpen)
        XCTAssertNil(service.payload)
        let client = PairingClient(store: store)
        do {
            _ = try await client.pair(payload: payload, endpoint: .hostPort(host: "127.0.0.1", port: port),
                                      expectedMacID: identity.peerID,
                                      request: PairRequestMessage(peerID: UUID(), name: "Phone", modelIdentifier: "iPhone16,2", protocolVersion: 1))
            XCTFail("Closed pairing listener accepted a request")
        } catch {}
        XCTAssertTrue(try store.all().isEmpty)
    }

    @MainActor func testListenerRequiresAuthorization() {
        let service = PairingService(identity: PeerIdentity(name: "Blocked Mac"),
                                     store: PairingStore(service: "app.trackglass.tests.denied.\(UUID())"), authorized: { false })
        service.open()
        XCTAssertFalse(service.isOpen)
        XCTAssertNil(service.payload)
        XCTAssertNil(service.port)
    }

    @MainActor func testRenderedQRCodePreservesPairingPayload() throws {
        let payload = try PairingPayload(pairID: Data(repeating: 19, count: 8),
                                         pairSecret: Data(repeating: 93, count: 32),
                                         macName: "Simone’s Mac", bonjourInstanceName: "Simone’s Mac (pairing)")
        let image = try XCTUnwrap(QRCodeRenderer.image(for: payload.url))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(),
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let features = detector.features(in: CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: 8, y: 8)))
        let text = try XCTUnwrap((features.first as? CIQRCodeFeature)?.messageString)
        XCTAssertEqual(try PairingPayload(url: XCTUnwrap(URL(string: text))), payload)
    }

    @MainActor func testConcurrentUseOfOneCodeAdmitsOnlyOnePhone() async throws {
        let macID = UUID()
        let phoneIDs = [UUID(), UUID()]
        let serverStore = PairingStore(service: "app.trackglass.tests.race.mac.\(UUID())")
        let phoneStore = PairingStore(service: "app.trackglass.tests.race.phone.\(UUID())")
        let service = PairingService(identity: PeerIdentity(peerID: macID, name: "Race Mac"), store: serverStore, authorized: { true },
                                     approvalPolicy: { _ in true })
        defer {
            service.close()
            for id in phoneIDs { try? serverStore.delete(peerID: id) }
            try? phoneStore.delete(peerID: macID)
        }
        service.open()
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: try await port(of: service))
        let payload = try XCTUnwrap(service.payload)
        let first = PairingClient(store: phoneStore)
        let second = PairingClient(store: phoneStore)
        let firstRequest = PairRequestMessage(peerID: phoneIDs[0], name: "First", modelIdentifier: "iPhone16,2", protocolVersion: 1)
        let secondRequest = PairRequestMessage(peerID: phoneIDs[1], name: "Second", modelIdentifier: "iPhone16,2", protocolVersion: 1)
        async let firstResult = Self.attempt(first, payload: payload, endpoint: endpoint, macID: macID, request: firstRequest)
        async let secondResult = Self.attempt(second, payload: payload, endpoint: endpoint, macID: macID, request: secondRequest)
        let outcomes = await [firstResult, secondResult]
        XCTAssertEqual(outcomes.filter { $0 }.count, 1)
        XCTAssertEqual(try serverStore.all().count, 1)
    }

    @MainActor private static func attempt(_ client: PairingClient, payload: PairingPayload, endpoint: NWEndpoint,
                                    macID: UUID, request: PairRequestMessage) async -> Bool {
        do {
            _ = try await client.pair(payload: payload, endpoint: endpoint, expectedMacID: macID, request: request)
            return true
        } catch { return false }
    }

    @MainActor private func port(of service: PairingService) async throws -> NWEndpoint.Port {
        for _ in 0..<250 {
            if let port = service.port { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "PairingExchangeTests.ListenerNotReady", code: 1)
    }
}
