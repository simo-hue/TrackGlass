import CryptoKit
import XCTest
import Network
import TrackglassKit
@testable import TrackglassMac

/// §3.4 code pairing (2026-10-31). This file held the PIN tests until the PIN path was replaced; every PIN test has
/// its code-pairing counterpart here (exchange, attempt limit, mode switch, window lifetime).
@MainActor
final class CodePairingTests: XCTestCase {
    func testBothScreensShowTheSameCodeAndBothSidesDeriveTheSameKey() async throws {
        let macID = UUID(), phoneID = UUID()
        let serverStore = PairingStore(service: "app.trackglass.tests.code.mac.\(UUID())")
        let phoneStore = PairingStore(service: "app.trackglass.tests.code.phone.\(UUID())")
        let prompts = Prompts()
        let service = PairingService(identity: PeerIdentity(peerID: macID, name: "Code Mac"), store: serverStore, authorized: { true },
                                     approvalPolicy: { pending in prompts.macCodes.append(pending.code ?? "none"); return true })
        defer { service.close(); try? serverStore.delete(peerID: phoneID); try? phoneStore.delete(peerID: macID) }
        service.open()
        let pairID = try XCTUnwrap(service.payload?.pairID)
        service.setMode(.code)
        XCTAssertEqual(service.mode, .code)
        XCTAssertEqual(service.payload?.pairID, pairID, "the pairID the phone sees in TXT pid stays")
        let endpoint = try await endpoint(of: service)
        let client = PairingClient(store: phoneStore)
        let mac = try await client.pair(codeWithPairID: pairID, endpoint: endpoint, expectedMacID: macID,
                                        request: request(phoneID)) { code in
            prompts.phoneCodes.append(code)
            client.confirmCode(matches: true)
        }
        XCTAssertEqual(prompts.macCodes.count, 1)
        XCTAssertEqual(prompts.phoneCodes, prompts.macCodes, "both screens show the same code")
        XCTAssertEqual(prompts.macCodes.first?.count, 6)
        XCTAssertTrue(prompts.macCodes.first?.allSatisfy { $0.isASCII && $0.isNumber } == true)
        XCTAssertEqual(mac.ltk.count, 32)
        XCTAssertEqual(try serverStore.load(peerID: phoneID)?.ltk, mac.ltk, "both sides derived the same LTK")
        XCTAssertEqual(try phoneStore.load(peerID: macID)?.name, "Code Mac")
        XCTAssertEqual(service.codeSessions, 1)
        try await eventually { service.isFinished }
        XCTAssertTrue(service.didPair)
        XCTAssertNil(service.payload)
        XCTAssertNil(service.port, "the pairing listener stops once paired")
    }

    func testMacAllowingFirstStoresNothingUntilThePhoneConfirms() async throws {
        let macID = UUID(), phoneID = UUID()
        let serverStore = PairingStore(service: "app.trackglass.tests.code.order.mac.\(UUID())")
        let phoneStore = PairingStore(service: "app.trackglass.tests.code.order.phone.\(UUID())")
        let service = PairingService(identity: PeerIdentity(peerID: macID, name: "Asking Mac"), store: serverStore, authorized: { true })
        defer { service.close(); try? serverStore.delete(peerID: phoneID); try? phoneStore.delete(peerID: macID) }
        service.open()
        service.setMode(.code)
        let endpoint = try await endpoint(of: service)
        let pairID = try XCTUnwrap(service.payload?.pairID)
        let prompts = Prompts()
        let client = PairingClient(store: phoneStore)
        let phoneRequest = request(phoneID)
        let pairing = Task { @MainActor in
            try await client.pair(codeWithPairID: pairID, endpoint: endpoint, expectedMacID: macID, request: phoneRequest) {
                prompts.phoneCodes.append($0)
            }
        }
        try await eventually { service.pendingApproval != nil && !prompts.phoneCodes.isEmpty }
        let pending = try XCTUnwrap(service.pendingApproval)
        XCTAssertEqual(pending.code, prompts.phoneCodes.first, "the Mac asks about the code the phone shows")
        XCTAssertEqual(pending.phoneName, "Code Phone")
        let code = try XCTUnwrap(pending.code)
        XCTAssertTrue(service.status.contains(PairingText.formattedCode(code)), service.status)
        service.respondToPendingPairing(allow: true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(try serverStore.all().isEmpty, "the Mac stores only after Allow and PAIR_CONFIRM")
        XCTAssertNil(try phoneStore.load(peerID: macID), "the phone stores only after PAIR_RESPONSE")
        XCTAssertFalse(service.isFinished)
        client.confirmCode(matches: true)
        let mac = try await pairing.value
        XCTAssertEqual(try serverStore.load(peerID: phoneID)?.ltk, mac.ltk)
    }

    func testPhoneConfirmingFirstWaitsForTheMacsAllow() async throws {
        let macID = UUID(), phoneID = UUID()
        let serverStore = PairingStore(service: "app.trackglass.tests.code.wait.mac.\(UUID())")
        let phoneStore = PairingStore(service: "app.trackglass.tests.code.wait.phone.\(UUID())")
        let service = PairingService(identity: PeerIdentity(peerID: macID, name: "Slow Mac"), store: serverStore, authorized: { true })
        defer { service.close(); try? serverStore.delete(peerID: phoneID); try? phoneStore.delete(peerID: macID) }
        service.open()
        service.setMode(.code)
        let endpoint = try await endpoint(of: service)
        let pairID = try XCTUnwrap(service.payload?.pairID)
        let client = PairingClient(store: phoneStore)
        let phoneRequest = request(phoneID)
        let pairing = Task { @MainActor in
            try await client.pair(codeWithPairID: pairID, endpoint: endpoint, expectedMacID: macID, request: phoneRequest) { _ in
                client.confirmCode(matches: true)
            }
        }
        try await eventually { service.pendingApproval != nil }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(try serverStore.all().isEmpty, "PAIR_CONFIRM alone stores nothing")
        XCTAssertNil(try phoneStore.load(peerID: macID))
        service.respondToPendingPairing(allow: true)
        let mac = try await pairing.value
        XCTAssertEqual(try serverStore.load(peerID: phoneID)?.ltk, mac.ltk)
    }

    func testMismatchOnThePhoneSpendsOneAttemptAndAnotherSessionMayFollow() async throws {
        let macID = UUID(), phoneID = UUID()
        let serverStore = PairingStore(service: "app.trackglass.tests.code.mismatch.mac.\(UUID())")
        let phoneStore = PairingStore(service: "app.trackglass.tests.code.mismatch.phone.\(UUID())")
        let service = PairingService(identity: PeerIdentity(peerID: macID, name: "Retry Mac"), store: serverStore, authorized: { true },
                                     approvalPolicy: { _ in true })
        defer { service.close(); try? serverStore.delete(peerID: phoneID); try? phoneStore.delete(peerID: macID) }
        service.open()
        service.setMode(.code)
        let endpoint = try await endpoint(of: service)
        let pairID = try XCTUnwrap(service.payload?.pairID)
        let client = PairingClient(store: phoneStore)
        do {
            _ = try await client.pair(codeWithPairID: pairID, endpoint: endpoint, expectedMacID: macID, request: request(phoneID)) { _ in
                client.confirmCode(matches: false)
            }
            XCTFail("“Doesn't match” paired")
        } catch PairingClient.Failure.codesDidNotMatch {
        } catch { XCTFail("Expected codesDidNotMatch, got \(error)") }
        try await eventually { service.codeSessions == 1 && service.connectionCount == 0 }
        XCTAssertTrue(service.isOpen)
        XCTAssertTrue(service.status.hasPrefix("The codes didn't match — try again"), service.status)
        XCTAssertTrue(try serverStore.all().isEmpty)
        XCTAssertNil(try phoneStore.load(peerID: macID))
        let mac = try await client.pair(codeWithPairID: pairID, endpoint: endpoint, expectedMacID: macID, request: request(phoneID)) { _ in
            client.confirmCode(matches: true)
        }
        XCTAssertEqual(try serverStore.load(peerID: phoneID)?.ltk, mac.ltk)
        XCTAssertEqual(service.codeSessions, 2)
    }

    func testDontAllowOnTheMacIsReportedToThePhoneAndCountsAsAMismatch() async throws {
        let macID = UUID(), phoneID = UUID()
        let serverStore = PairingStore(service: "app.trackglass.tests.code.deny.mac.\(UUID())")
        let phoneStore = PairingStore(service: "app.trackglass.tests.code.deny.phone.\(UUID())")
        let service = PairingService(identity: PeerIdentity(peerID: macID, name: "Careful Mac"), store: serverStore, authorized: { true },
                                     approvalPolicy: { _ in false })
        defer { service.close() }
        service.open()
        service.setMode(.code)
        let endpoint = try await endpoint(of: service)
        let pairID = try XCTUnwrap(service.payload?.pairID)
        let client = PairingClient(store: phoneStore)
        do {
            _ = try await client.pair(codeWithPairID: pairID, endpoint: endpoint, expectedMacID: macID, request: request(phoneID)) { _ in }
            XCTFail("Don't Allow paired")
        } catch PairingClient.Failure.declined {
        } catch { XCTFail("Expected declined, got \(error)") }
        try await eventually { service.codeSessions == 1 && service.connectionCount == 0 }
        XCTAssertTrue(service.isOpen, "attempts remain")
        XCTAssertTrue(service.status.hasPrefix("The codes didn't match — try again"), service.status)
        XCTAssertTrue(try serverStore.all().isEmpty)
        XCTAssertTrue(try phoneStore.all().isEmpty)
    }

    func testThreeCodeSessionsUseUpTheWindow() async throws {
        let macID = UUID()
        let store = PairingStore(service: "app.trackglass.tests.code.limit.\(UUID())")
        let service = PairingService(identity: PeerIdentity(peerID: macID, name: "Limit Mac"), store: store, authorized: { true },
                                     approvalPolicy: { _ in true })
        defer { service.close() }
        service.open()
        service.setMode(.code)
        let endpoint = try await endpoint(of: service)
        let pairID = try XCTUnwrap(service.payload?.pairID)
        let client = PairingClient(store: store)
        for attempt in 1...PairingService.maxCodeSessions {
            do {
                _ = try await client.pair(codeWithPairID: pairID, endpoint: endpoint, expectedMacID: macID, request: request(UUID())) { _ in
                    client.confirmCode(matches: false)
                }
                XCTFail("“Doesn't match” paired")
            } catch {}
            try await eventually { service.codeSessions == attempt && service.connectionCount == 0 }
        }
        XCTAssertFalse(service.isOpen)
        XCTAssertTrue(service.isFinished, "the window offers Try again")
        XCTAssertNil(service.port)
        XCTAssertNil(service.payload)
        service.setMode(.qr)
        service.setMode(.code)
        XCTAssertNil(service.port, "mode switches cannot restore a fourth attempt")
        do {
            _ = try await client.pair(codeWithPairID: pairID, endpoint: endpoint, expectedMacID: macID, request: request(UUID())) { _ in
                client.confirmCode(matches: true)
            }
            XCTFail("A fourth session must fail")
        } catch {}
        XCTAssertTrue(try store.all().isEmpty)
        service.open()
        XCTAssertEqual(service.codeSessions, 0, "only a newly opened window resets the limit")
    }

    /// Round 4 L2: a failed TLS handshake is never a guess (256-bit QR secret; public code-channel key), so in either
    /// mode it neither counts nor rotates anything. Only sessions that reach PAIR_COMMIT count.
    func testFailedHandshakesSpendNothingInEitherMode() async throws {
        let macID = UUID(), phoneID = UUID()
        let serverStore = PairingStore(service: "app.trackglass.tests.code.tls.mac.\(UUID())")
        let phoneStore = PairingStore(service: "app.trackglass.tests.code.tls.phone.\(UUID())")
        let service = PairingService(identity: PeerIdentity(peerID: macID, name: "Sturdy Mac"), store: serverStore, authorized: { true },
                                     approvalPolicy: { _ in true })
        defer { service.close(); try? serverStore.delete(peerID: phoneID); try? phoneStore.delete(peerID: macID) }
        service.open()
        let qrEndpoint = try await endpoint(of: service)
        let original = try XCTUnwrap(service.payload)
        let wrongSecret = try PairingPayload(pairID: original.pairID, pairSecret: Data(repeating: 7, count: 32),
                                             macName: original.macName, bonjourInstanceName: original.bonjourInstanceName)
        let client = PairingClient(store: phoneStore)
        for _ in 0..<4 {
            do {
                _ = try await client.pair(payload: wrongSecret, endpoint: qrEndpoint, expectedMacID: macID, request: request(phoneID))
                XCTFail("A wrong QR secret was accepted")
            } catch {}
            try await eventually { service.connectionCount == 0 }
        }
        // Code pairing against a window still showing the QR: the phone tells its user to switch the Mac first.
        do {
            _ = try await client.pair(codeWithPairID: original.pairID, endpoint: qrEndpoint, expectedMacID: macID, request: request(phoneID)) { _ in }
            XCTFail("Code pairing reached a QR-mode listener")
        } catch PairingClient.Failure.codeModeOff {
        } catch { XCTFail("Expected codeModeOff, got \(error)") }
        try await eventually { service.connectionCount == 0 }
        XCTAssertTrue(service.isOpen)
        XCTAssertEqual(service.payload?.pairID, original.pairID, "nothing rotated")
        XCTAssertEqual(service.payload?.pairSecret, original.pairSecret, "nothing rotated")
        service.setMode(.code)
        let codeEndpoint = try await endpoint(of: service)
        for _ in 0..<4 {
            do {
                _ = try await client.pair(payload: original, endpoint: codeEndpoint, expectedMacID: macID, request: request(phoneID))
                XCTFail("The QR key opened the code channel")
            } catch {}
            try await eventually { service.connectionCount == 0 }
        }
        XCTAssertEqual(service.codeSessions, 0)
        XCTAssertTrue(service.isOpen)
        XCTAssertEqual(service.payload?.pairID, original.pairID)
        let mac = try await client.pair(codeWithPairID: original.pairID, endpoint: codeEndpoint, expectedMacID: macID, request: request(phoneID)) { _ in
            client.confirmCode(matches: true)
        }
        XCTAssertEqual(try serverStore.load(peerID: phoneID)?.ltk, mac.ltk)
    }

    /// §3.4: the phone pairs only with the Mac it chose; a PAIR_COMMIT naming another peerID ends the attempt.
    func testCommitFromAnotherMacIsRejected() async throws {
        let macID = UUID(), phoneID = UUID()
        let serverStore = PairingStore(service: "app.trackglass.tests.code.wrongmac.mac.\(UUID())")
        let phoneStore = PairingStore(service: "app.trackglass.tests.code.wrongmac.phone.\(UUID())")
        let service = PairingService(identity: PeerIdentity(peerID: macID, name: "Real Mac"), store: serverStore, authorized: { true },
                                     approvalPolicy: { _ in true })
        defer { service.close() }
        service.open()
        service.setMode(.code)
        let endpoint = try await endpoint(of: service)
        let pairID = try XCTUnwrap(service.payload?.pairID)
        let prompts = Prompts()
        do {
            _ = try await PairingClient(store: phoneStore).pair(codeWithPairID: pairID, endpoint: endpoint, expectedMacID: UUID(),
                                                                request: request(phoneID)) { prompts.phoneCodes.append($0) }
            XCTFail("Paired with an unexpected Mac")
        } catch PairingClient.Failure.wrongMac {
        } catch { XCTFail("Expected wrongMac, got \(error)") }
        XCTAssertTrue(prompts.phoneCodes.isEmpty, "no code is shown for the wrong Mac")
        try await eventually { service.connectionCount == 0 }
        XCTAssertEqual(service.codeSessions, 1)
        XCTAssertTrue(try serverStore.all().isEmpty)
        XCTAssertTrue(try phoneStore.all().isEmpty)
    }

    func testModeSwitchDoesNotExtendWindowLifetime() async throws {
        let service = PairingService(identity: PeerIdentity(name: "Expiring Mac"),
                                     store: PairingStore(service: "app.trackglass.tests.expiry.\(UUID())"),
                                     authorized: { true }, windowLifetime: .seconds(2))
        defer { service.close() }
        service.open()
        _ = try await endpoint(of: service)
        try await Task.sleep(for: .milliseconds(1200))
        service.setMode(.code)
        _ = try await endpoint(of: service)
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(service.isOpen)
        XCTAssertNil(service.payload)
    }

    /// §3.4: the listener holds one key at a time; switching mode drops a connection accepted under the old one.
    func testModeSwitchDropsAConnectionAcceptedUnderTheOldKey() async throws {
        let service = PairingService(identity: PeerIdentity(name: "Switching Mac"),
                                     store: PairingStore(service: "app.trackglass.tests.code.switch.\(UUID())"), authorized: { true })
        defer { service.close() }
        service.open()
        guard case let .hostPort(_, port) = try await endpoint(of: service) else { return XCTFail("no port") }
        let stray = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        defer { stray.cancel() }
        stray.start(queue: .main)
        try await eventually { service.connectionCount == 1 }
        XCTAssertFalse(service.sessionInProgress, "a connection before PAIR_REQUEST does not block the switch")
        service.setMode(.code)
        XCTAssertEqual(service.mode, .code)
        XCTAssertEqual(service.connectionCount, 0)
        XCTAssertEqual(service.codeSessions, 0)
    }

    /// §3.4: the phone's automatic step after PAIR_COMMIT (PAIR_NONCE) is due within the request timeout; a phone
    /// that stalls there loses the slot, and the session counts.
    func testPhoneStallingAfterTheCommitLosesTheSlot() async throws {
        let macID = UUID()
        let service = PairingService(identity: PeerIdentity(peerID: macID, name: "Timely Mac"),
                                     store: PairingStore(service: "app.trackglass.tests.code.stall.\(UUID())"), authorized: { true },
                                     requestTimeout: .milliseconds(300), approvalPolicy: { _ in true })
        defer { service.close() }
        service.open()
        service.setMode(.code)
        guard case let .hostPort(_, port) = try await endpoint(of: service) else { return XCTFail("no port") }
        let pairID = try XCTUnwrap(service.payload?.pairID)
        let phone = try RawChannel.connect(pairID: pairID, port: port)
        defer { phone.cancel() }
        try await phone.waitUntilReady()
        try phone.send(.pairRequest(rawRequest(key: Curve25519.KeyAgreement.PrivateKey())))
        guard case .pairCommit? = await phone.next() else { return XCTFail("expected PAIR_COMMIT") }
        let after = await phone.next()
        XCTAssertNil(after, "the Mac drops a phone that never sends PAIR_NONCE")
        try await eventually { service.connectionCount == 0 }
        XCTAssertEqual(service.codeSessions, 1)
        XCTAssertTrue(service.isOpen)
        XCTAssertTrue(service.status.hasPrefix("Pairing with “Raw Phone” did not finish — try again"), service.status)
    }

    /// §3.4: the Mac enforces the order REQUEST → NONCE → CONFIRM; anything else ends the exchange. Before
    /// PAIR_COMMIT nothing counts; after it, the session does.
    func testMacEndsAnExchangeThatSkipsOrRepeatsAStep() async throws {
        let macID = UUID()
        let serverStore = PairingStore(service: "app.trackglass.tests.code.raw.\(UUID())")
        let service = PairingService(identity: PeerIdentity(peerID: macID, name: "Strict Mac"), store: serverStore, authorized: { true },
                                     approvalPolicy: { _ in true })
        defer { service.close() }
        service.open()
        service.setMode(.code)
        guard case let .hostPort(_, port) = try await endpoint(of: service) else { return XCTFail("no port") }
        let pairID = try XCTUnwrap(service.payload?.pairID)

        // PAIR_NONCE before PAIR_REQUEST: dropped, not a session.
        let first = try RawChannel.connect(pairID: pairID, port: port)
        defer { first.cancel() }
        try await first.waitUntilReady()
        try first.send(.pairNonce(PairNonceMessage(nonce: KeyDerivation.randomNonce())))
        let firstReply = await first.next()
        XCTAssertNil(firstReply)
        try await eventually { service.connectionCount == 0 }
        XCTAssertEqual(service.codeSessions, 0)

        // PAIR_CONFIRM straight after PAIR_COMMIT (skipping PAIR_NONCE): dropped, and the session counts.
        let second = try RawChannel.connect(pairID: pairID, port: port)
        defer { second.cancel() }
        try await second.waitUntilReady()
        try second.send(.pairRequest(rawRequest(key: Curve25519.KeyAgreement.PrivateKey())))
        guard case .pairCommit(let commit)? = await second.next() else { return XCTFail("expected PAIR_COMMIT") }
        XCTAssertEqual(commit.peerID, macID)
        XCTAssertEqual(commit.name, "Strict Mac")
        try second.send(.pairConfirm)
        let secondReply = await second.next()
        XCTAssertNil(secondReply)
        try await eventually { service.connectionCount == 0 }
        XCTAssertEqual(service.codeSessions, 1)

        // The honest steps, then PAIR_NONCE again: dropped. The revealed nonce opens the commitment.
        let third = try RawChannel.connect(pairID: pairID, port: port)
        defer { third.cancel() }
        try await third.waitUntilReady()
        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        try third.send(.pairRequest(rawRequest(key: phoneKey)))
        guard case .pairCommit(let thirdCommit)? = await third.next() else { return XCTFail("expected PAIR_COMMIT") }
        let phoneNonce = KeyDerivation.randomNonce()
        try third.send(.pairNonce(PairNonceMessage(nonce: phoneNonce)))
        guard case .pairReveal(let reveal)? = await third.next() else { return XCTFail("expected PAIR_REVEAL") }
        XCTAssertTrue(KeyDerivation.commitmentMatches(thirdCommit.commitment, macNonce: reveal.nonce,
                                                      macPublicKey: thirdCommit.ephemeralPublicKey,
                                                      phonePublicKey: phoneKey.publicKey.rawRepresentation))
        try third.send(.pairNonce(PairNonceMessage(nonce: phoneNonce)))
        let thirdReply = await third.next()
        XCTAssertNil(thirdReply, "a repeated PAIR_NONCE ends the exchange")
        try await eventually { service.connectionCount == 0 }
        XCTAssertEqual(service.codeSessions, 2)
        XCTAssertTrue(service.isOpen)
        XCTAssertTrue(try serverStore.all().isEmpty)
    }

    /// The phone side against a fake Mac (§3.1: an attacker advertising a pairing record): PAIR_REVEAL without a
    /// PAIR_COMMIT first is refused, and no code is shown.
    func testPhoneRefusesARevealWithoutACommitment() async throws {
        let macID = UUID()
        let phoneStore = PairingStore(service: "app.trackglass.tests.code.fake1.\(UUID())")
        let pairID = Data(repeating: 0x31, count: 8)
        let fake = try FakeMac(pairID: pairID)
        defer { fake.stop() }
        let port = try await fake.readyPort()
        let prompts = Prompts()
        let client = PairingClient(store: phoneStore)
        let phoneRequest = request(UUID())
        let pairing = Task { @MainActor in
            try await client.pair(codeWithPairID: pairID, endpoint: .hostPort(host: "127.0.0.1", port: port), expectedMacID: macID,
                                  request: phoneRequest) { prompts.phoneCodes.append($0) }
        }
        let mac = try await fake.acceptedChannel()
        guard case .pairRequest? = await mac.next() else { return XCTFail("expected PAIR_REQUEST") }
        try mac.send(.pairReveal(PairNonceMessage(nonce: KeyDerivation.randomNonce())))
        do { _ = try await pairing.value; XCTFail("A reveal without a commitment was accepted") }
        catch PairingClient.Failure.invalidResponse {}
        catch { XCTFail("Expected invalidResponse, got \(error)") }
        XCTAssertTrue(prompts.phoneCodes.isEmpty)
        XCTAssertNil(try phoneStore.load(peerID: macID))
    }

    /// A fake Mac whose PAIR_REVEAL does not open its PAIR_COMMIT (it tried to pick Nm after seeing Np) is refused.
    func testPhoneRefusesARevealThatDoesNotOpenTheCommitment() async throws {
        let macID = UUID()
        let phoneStore = PairingStore(service: "app.trackglass.tests.code.fake2.\(UUID())")
        let pairID = Data(repeating: 0x32, count: 8)
        let fake = try FakeMac(pairID: pairID)
        defer { fake.stop() }
        let port = try await fake.readyPort()
        let prompts = Prompts()
        let client = PairingClient(store: phoneStore)
        let phoneRequest = request(UUID())
        let pairing = Task { @MainActor in
            try await client.pair(codeWithPairID: pairID, endpoint: .hostPort(host: "127.0.0.1", port: port), expectedMacID: macID,
                                  request: phoneRequest) { prompts.phoneCodes.append($0) }
        }
        let mac = try await fake.acceptedChannel()
        guard case .pairRequest(let sent)? = await mac.next() else { return XCTFail("expected PAIR_REQUEST") }
        let macKey = Curve25519.KeyAgreement.PrivateKey()
        let committedNonce = KeyDerivation.randomNonce()
        try mac.send(.pairCommit(PairCommitMessage(peerID: macID, name: "Fake Mac", ephemeralPublicKey: macKey.publicKey.rawRepresentation,
                                                   commitment: KeyDerivation.commitment(macNonce: committedNonce,
                                                                                        macPublicKey: macKey.publicKey.rawRepresentation,
                                                                                        phonePublicKey: sent.ephemeralPublicKey))))
        guard case .pairNonce? = await mac.next() else { return XCTFail("expected PAIR_NONCE") }
        try mac.send(.pairReveal(PairNonceMessage(nonce: KeyDerivation.randomNonce())))
        do { _ = try await pairing.value; XCTFail("A reveal that does not open the commitment was accepted") }
        catch PairingClient.Failure.commitmentMismatch {}
        catch { XCTFail("Expected commitmentMismatch, got \(error)") }
        XCTAssertTrue(prompts.phoneCodes.isEmpty, "no code is shown")
        XCTAssertNil(try phoneStore.load(peerID: macID))
    }

    /// PAIR_RESPONSE before the phone's user confirmed the code is out of order: nothing is stored.
    func testPhoneRefusesAResponseBeforeItsUserConfirmed() async throws {
        let macID = UUID()
        let phoneStore = PairingStore(service: "app.trackglass.tests.code.fake3.\(UUID())")
        let pairID = Data(repeating: 0x33, count: 8)
        let fake = try FakeMac(pairID: pairID)
        defer { fake.stop() }
        let port = try await fake.readyPort()
        let prompts = Prompts()
        let client = PairingClient(store: phoneStore)
        let phoneRequest = request(UUID())
        let pairing = Task { @MainActor in
            try await client.pair(codeWithPairID: pairID, endpoint: .hostPort(host: "127.0.0.1", port: port), expectedMacID: macID,
                                  request: phoneRequest) { prompts.phoneCodes.append($0) }
        }
        let mac = try await fake.acceptedChannel()
        guard case .pairRequest(let sent)? = await mac.next() else { return XCTFail("expected PAIR_REQUEST") }
        let macKey = Curve25519.KeyAgreement.PrivateKey()
        let macNonce = KeyDerivation.randomNonce()
        try mac.send(.pairCommit(PairCommitMessage(peerID: macID, name: "Fake Mac", ephemeralPublicKey: macKey.publicKey.rawRepresentation,
                                                   commitment: KeyDerivation.commitment(macNonce: macNonce,
                                                                                        macPublicKey: macKey.publicKey.rawRepresentation,
                                                                                        phonePublicKey: sent.ephemeralPublicKey))))
        guard case .pairNonce? = await mac.next() else { return XCTFail("expected PAIR_NONCE") }
        try mac.send(.pairReveal(PairNonceMessage(nonce: macNonce)))
        try await eventually { prompts.phoneCodes.count == 1 }
        try mac.send(.pairResponse(PairResponseMessage(peerID: macID, name: "Fake Mac", ephemeralPublicKey: macKey.publicKey.rawRepresentation)))
        do { _ = try await pairing.value; XCTFail("A response before PAIR_CONFIRM was accepted") }
        catch PairingClient.Failure.invalidResponse {}
        catch { XCTFail("Expected invalidResponse, got \(error)") }
        XCTAssertNil(try phoneStore.load(peerID: macID))
    }

    private func request(_ phoneID: UUID) -> PairRequestMessage {
        PairRequestMessage(peerID: phoneID, name: "Code Phone", modelIdentifier: "iPhone16,2", protocolVersion: 1)
    }

    private func rawRequest(key: Curve25519.KeyAgreement.PrivateKey) -> PairRequestMessage {
        PairRequestMessage(peerID: UUID(), name: "Raw Phone", modelIdentifier: "iPhone16,2", protocolVersion: 1,
                           ephemeralPublicKey: key.publicKey.rawRepresentation)
    }

    private func endpoint(of service: PairingService) async throws -> NWEndpoint {
        for _ in 0..<250 {
            if let port = service.port { return .hostPort(host: "127.0.0.1", port: port) }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "CodePairingTests.ListenerNotReady", code: 1)
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ predicate: () throws -> Bool) async throws {
        for _ in 0..<250 {
            if try predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Condition not reached within five seconds", file: file, line: line)
        throw NSError(domain: "CodePairingTests.Timeout", code: 2)
    }
}

/// What each screen showed (the tests answer the Mac's prompt through `approvalPolicy`).
@MainActor
private final class Prompts {
    var macCodes: [String] = []
    var phoneCodes: [String] = []
}

/// One end of a code-pairing channel driven by hand, to send messages out of order.
@MainActor
private final class RawChannel {
    let connection: NWConnection
    private var sequence: UInt32 = 0

    init(_ connection: NWConnection) { self.connection = connection }

    /// A phone's connection to a Mac's code-mode pairing listener.
    static func connect(pairID: Data, port: NWEndpoint.Port) throws -> RawChannel {
        let key = try KeyDerivation.codeChannelKey(pairID: pairID)
        let options = TLSConfig.tlsOptions(psk: key, identity: PairingPayload.identity(forPairID: pairID))
        let channel = RawChannel(NWConnection(host: "127.0.0.1", port: port, using: TLSConfig.parameters(control: options)))
        channel.connection.start(queue: .main)
        return channel
    }

    func waitUntilReady() async throws {
        for _ in 0..<250 {
            if case .ready = connection.state { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "CodePairingTests.RawChannelNotReady", code: 3)
    }

    func send(_ message: ControlMessage) throws {
        let data = try message.encode(sequence: sequence, sentAt: 0)
        sequence &+= 1
        let context = NWConnection.ContentContext(identifier: "test", metadata: [NWProtocolFramer.Message(definition: TGControlFramer.definition)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// The next message, or nil once the other side closed (or after 5 s without one).
    func next() async -> ControlMessage? {
        let connection = connection
        let watchdog = Task { @MainActor in
            try await Task.sleep(for: .seconds(5))
            connection.cancel()
        }
        defer { watchdog.cancel() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<ControlMessage?, Never>) in
            connection.receiveMessage { data, _, _, error in
                guard error == nil, let data, let packet = try? ControlMessage.decode(data) else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: packet.message)
            }
        }
    }

    func cancel() { connection.cancel() }
}

/// A fake Mac in code mode — the §3.1 attacker advertising a pairing record — that answers by hand.
@MainActor
private final class FakeMac {
    private let listener: NWListener
    private var channel: RawChannel?

    init(pairID: Data) throws {
        let key = try KeyDerivation.codeChannelKey(pairID: pairID)
        let parameters = TLSConfig.parameters(control: TLSConfig.tlsOptions(psk: key, identity: PairingPayload.identity(forPairID: pairID)))
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.channel == nil else { connection.cancel(); return }
                connection.start(queue: .main)
                self.channel = RawChannel(connection)
            }
        }
        listener.start(queue: .main)
    }

    /// The bound port once the listener is ready: before that `port` can still read back the requested `.any` (0),
    /// and a phone connecting to port 0 fails with EADDRNOTAVAIL.
    func readyPort() async throws -> NWEndpoint.Port {
        for _ in 0..<250 {
            if case .ready = listener.state, let port = listener.port, port.rawValue != 0 { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "CodePairingTests.FakeMacNotReady", code: 4)
    }

    func acceptedChannel() async throws -> RawChannel {
        for _ in 0..<250 {
            if let channel { return channel }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "CodePairingTests.FakeMacNoPhone", code: 5)
    }

    func stop() {
        channel?.cancel()
        listener.cancel()
    }
}
