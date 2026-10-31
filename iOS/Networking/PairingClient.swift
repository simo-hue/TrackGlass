import CryptoKit
import Foundation
import Network
import TrackglassKit

/// The phone's side of pairing (§3.4). QR: PAIR_REQUEST → PAIR_RESPONSE over the pairSecret channel. Code pairing
/// (2026-10-31): PAIR_REQUEST → PAIR_COMMIT → PAIR_NONCE → PAIR_REVEAL; both screens then show the comparison code;
/// the user's "Matches" sends PAIR_CONFIRM → PAIR_RESPONSE. A message out of that order ends the attempt.
/// Also compiled into the macOS test bundle, so it stays free of UIKit.
@MainActor
final class PairingClient {
    enum Failure: Error, LocalizedError {
        case invalidResponse, expired, declined, endedByMac, network(String)
        /// Code pairing: the TLS handshake failed — the Mac's pairing window is still in QR mode.
        case codeModeOff
        /// Code pairing: PAIR_COMMIT names another Mac than the record the user chose.
        case wrongMac
        /// Code pairing: PAIR_REVEAL's nonce does not open PAIR_COMMIT's commitment.
        case commitmentMismatch
        /// Code pairing: the user tapped "Doesn't match".
        case codesDidNotMatch
        /// QR or link: this device is already paired with that Mac; replacing the pairing needs the user's OK (§3.4).
        case alreadyPaired(name: String)
        var errorDescription: String? {
            switch self {
            case .invalidResponse: "The Mac returned an invalid pairing response."
            // BYE{0} (§3.4): Don't Allow, or the pairing window was closed or expired while the Mac was asking.
            case .declined: "Pairing was not allowed on the Mac, or its pairing window was closed. Open a new pairing window and try again."
            case .endedByMac: "The Mac ended pairing before answering. Open a new pairing window and try again."
            case .expired: "Pairing expired. Open a new pairing window and try again."
            case .network(let message): "Pairing connection failed: \(message)"
            case .codeModeOff: "The Mac is not ready for a code. Click “Use a code instead” in its pairing window first, then choose it here again."
            case .wrongMac: "A different device answered for this Mac, so pairing was stopped."
            case .commitmentMismatch: "The Mac’s pairing answer did not check out, so pairing was stopped."
            case .codesDidNotMatch: "The codes didn't match — try again."
            case .alreadyPaired(let name): "This device is already paired with “\(PairingText.sanitizedName(name))”."
            }
        }
    }

    private enum Phase {
        case idle, connecting
        /// QR: PAIR_REQUEST sent; PAIR_RESPONSE is next.
        case awaitingResponse
        /// Code: PAIR_REQUEST sent; PAIR_COMMIT is next.
        case awaitingCommit
        /// Code: PAIR_NONCE sent; PAIR_REVEAL is next.
        case awaitingReveal
        /// Code: the code is on screen; the Mac sends nothing until this user answers.
        case comparing
        /// Code: PAIR_CONFIRM sent; PAIR_RESPONSE is next (after the Mac's user clicked Allow).
        case confirmed
    }

    private let store: PairingStore
    private var connection: NWConnection?
    private var completion: CheckedContinuation<PairedPeer, Error>?
    private var timeout: Task<Void, Never>?
    private var attempt: UUID?
    private var phase = Phase.idle
    private var sequence: UInt32 = 0
    /// §3.4 hardening (2026-10-28): the one-time X25519 key of the running attempt; the LTK is derived once the Mac
    /// answers, and never received.
    private var ephemeralKey: Curve25519.KeyAgreement.PrivateKey?
    /// QR: the pairSecret, mixed into the LTK. Code pairing has none (its channel key is public).
    private var pairingKey: SymmetricKey?
    private var pairID = Data()
    private var requestPeerID = UUID()
    private var expectedMacID = UUID()
    /// Code pairing: the Mac's commitment message, this phone's nonce Np and the revealed Mac nonce Nm.
    private var commit: PairCommitMessage?
    private var phoneNonce = Data()
    private var macNonce = Data()
    private var showCode: (@MainActor (String) -> Void)?

    init(store: PairingStore = PairingStore()) { self.store = store }

    /// QR or pairing link (§3.4). Unless `replacingExisting` (the user confirmed it), an existing pairing with that Mac
    /// ends the attempt with `.alreadyPaired` before anything is sent: a scanned code or a link never silently replaces
    /// a working pairing.
    func pair(payload: PairingPayload, endpoint: NWEndpoint, expectedMacID: UUID,
              request: PairRequestMessage, replacingExisting: Bool = false) async throws -> PairedPeer {
        if !replacingExisting, let existing = try? store.load(peerID: expectedMacID) {
            throw Failure.alreadyPaired(name: existing.name)
        }
        return try await run(key: SymmetricKey(data: payload.pairSecret), identity: payload.identity, pairID: payload.pairID,
                             codePairing: false, endpoint: endpoint, expectedMacID: expectedMacID, request: request, showCode: nil)
    }

    /// Code pairing (§3.4, 2026-10-31) with the `(pairing)` record the user tapped: `pairID` is its TXT `pid`,
    /// `expectedMacID` its `id`. `showCode` receives the six digits once the Mac's commitment checked out; the user's
    /// answer goes to `confirmCode(matches:)`. Pairing completes only after that and the Mac's Allow.
    func pair(codeWithPairID pairID: Data, endpoint: NWEndpoint, expectedMacID: UUID, request: PairRequestMessage,
              showCode: @escaping @MainActor (String) -> Void) async throws -> PairedPeer {
        let key = try KeyDerivation.codeChannelKey(pairID: pairID)
        return try await run(key: key, identity: PairingPayload.identity(forPairID: pairID), pairID: pairID, codePairing: true,
                             endpoint: endpoint, expectedMacID: expectedMacID, request: request, showCode: showCode)
    }

    /// The user's answer to "Does your Mac show this code?". Matches sends PAIR_CONFIRM; Doesn't match tells the Mac
    /// with BYE{0} and ends the attempt with `.codesDidNotMatch`.
    func confirmCode(matches: Bool) {
        guard phase == .comparing, let connection else { return }
        if matches {
            phase = .confirmed
            send(.pairConfirm, on: connection)
            return
        }
        // Detached first, so `finish` leaves the connection open until the BYE is out.
        self.connection = nil
        connection.stateUpdateHandler = nil
        if let bye = try? ControlMessage.bye(ByeMessage(reason: 0)).encode(sequence: nextSequence(), sentAt: MonotonicClock.wireNanoseconds()) {
            connection.send(content: bye, contentContext: Self.context(), isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        } else {
            connection.cancel()
        }
        finish(.failure(Failure.codesDidNotMatch))
    }

    private func run(key: SymmetricKey, identity: String, pairID: Data, codePairing: Bool, endpoint: NWEndpoint,
                     expectedMacID: UUID, request: PairRequestMessage,
                     showCode: (@MainActor (String) -> Void)?) async throws -> PairedPeer {
        try Task.checkCancellation()
        cancel()
        let attempt = UUID()
        self.attempt = attempt
        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        self.ephemeralKey = ephemeralKey
        self.pairingKey = codePairing ? nil : key
        self.pairID = pairID
        self.expectedMacID = expectedMacID
        self.showCode = showCode
        phase = .connecting
        sequence = 0
        var prepared = request
        prepared.ephemeralPublicKey = ephemeralKey.publicKey.rawRepresentation
        let outgoing = prepared
        self.requestPeerID = outgoing.peerID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                let options = TLSConfig.tlsOptions(psk: key, identity: identity)
                let connection = NWConnection(to: endpoint, using: TLSConfig.parameters(control: options))
                self.connection = connection
                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    Task { @MainActor in
                        guard let self, let connection, self.connection === connection else { return }
                        switch state {
                        case .ready:
                            guard self.phase == .connecting else { return }
                            self.phase = codePairing ? .awaitingCommit : .awaitingResponse
                            self.send(.pairRequest(outgoing), on: connection)
                            self.receive(on: connection)
                        case .failed(let error), .waiting(let error):
                            self.finish(.failure(self.failure(for: error, codePairing: codePairing)))
                        case .cancelled: self.finish(.failure(CancellationError()))
                        default: break
                        }
                    }
                }
                // Covers the Mac's 120 s pairing window, including the time the users take to compare and confirm.
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(120)) } catch { return }
                    guard let self, self.attempt == attempt else { return }
                    self.finish(.failure(Failure.expired))
                }
                connection.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.attempt == attempt else { return }
                self?.cancel()
            }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    /// Before the channel is up, a TLS failure in code pairing means the Mac's listener still holds the QR key: its
    /// window is not in code mode (§3.4). The Mac does not count that handshake as an attempt. A connection the Mac
    /// simply closed (errSSLClosedGraceful −9805, errSSLClosedAbort −9806, errSSLClosedNoNotify −9816: its one pairing
    /// slot is busy, or the window closed) is a plain connection failure.
    private func failure(for error: NWError, codePairing: Bool) -> Error {
        if codePairing, phase == .connecting, case let .tls(status) = error, ![-9805, -9806, -9816].contains(status) {
            return Failure.codeModeOff
        }
        return Failure.network(error.localizedDescription)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, complete, error in
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else { return }
                do {
                    if let error { throw Failure.network(error.localizedDescription) }
                    // The Mac closed the connection without a word: it did not pair.
                    guard let data else { throw Failure.endedByMac }
                    guard complete else { throw Failure.invalidResponse }
                    try self.handle(ControlMessage.decode(data).message, on: connection)
                    if self.connection === connection { self.receive(on: connection) }
                } catch { self.finish(.failure(error)) }
            }
        }
    }

    /// One step of §3.4's order. BYE{0} is the Mac declining (Don't Allow, its window closed or expired); a message
    /// out of order, repeated or unknown ends the attempt.
    private func handle(_ message: ControlMessage, on connection: NWConnection) throws {
        switch (phase, message) {
        case (_, .bye):
            throw Failure.declined
        case (.awaitingResponse, .pairResponse(let response)), (.confirmed, .pairResponse(let response)):
            try complete(with: response)
        case (.awaitingCommit, .pairCommit(let commit)):
            // The Mac the user chose (its record's `id`) must be the one answering.
            guard commit.peerID == expectedMacID else { throw Failure.wrongMac }
            self.commit = commit
            // Np is drawn only now, after the Mac is bound to Nm by its commitment.
            phoneNonce = KeyDerivation.randomNonce()
            phase = .awaitingReveal
            send(.pairNonce(PairNonceMessage(nonce: phoneNonce)), on: connection)
        case (.awaitingReveal, .pairReveal(let reveal)):
            guard let commit = self.commit, let ephemeralKey = self.ephemeralKey else { throw Failure.invalidResponse }
            let phonePublicKey = ephemeralKey.publicKey.rawRepresentation
            guard KeyDerivation.commitmentMatches(commit.commitment, macNonce: reveal.nonce, macPublicKey: commit.ephemeralPublicKey,
                                                  phonePublicKey: phonePublicKey) else { throw Failure.commitmentMismatch }
            macNonce = reveal.nonce
            let code = try KeyDerivation.comparisonCode(pairID: pairID, phonePeerID: requestPeerID, macPeerID: commit.peerID,
                                                        phonePublicKey: phonePublicKey, macPublicKey: commit.ephemeralPublicKey,
                                                        phoneNonce: phoneNonce, macNonce: macNonce)
            phase = .comparing
            showCode?(code)
        default:
            throw Failure.invalidResponse
        }
    }

    /// PAIR_RESPONSE in the right phase: derive the LTK (QR v2, or code v3 over the committed Mac key) and store.
    private func complete(with response: PairResponseMessage) throws {
        guard response.peerID == expectedMacID, let ephemeralKey = self.ephemeralKey else { throw Failure.invalidResponse }
        let phonePublicKey = ephemeralKey.publicKey.rawRepresentation
        let ltk: SymmetricKey
        if let commit = self.commit {
            // Only the key the Mac committed to, which the compared code covers, is accepted.
            guard response.ephemeralPublicKey == commit.ephemeralPublicKey else { throw Failure.invalidResponse }
            let shared = try KeyDerivation.sharedSecret(privateKey: ephemeralKey, peerPublicKey: commit.ephemeralPublicKey)
            ltk = try KeyDerivation.codePairingLTK(sharedSecret: shared, pairID: pairID, phonePeerID: requestPeerID,
                                                   macPeerID: response.peerID, phonePublicKey: phonePublicKey,
                                                   macPublicKey: commit.ephemeralPublicKey, phoneNonce: phoneNonce, macNonce: macNonce)
        } else {
            guard let pairingKey = self.pairingKey else { throw Failure.invalidResponse }
            let shared = try KeyDerivation.sharedSecret(privateKey: ephemeralKey, peerPublicKey: response.ephemeralPublicKey)
            ltk = try KeyDerivation.pairingLTK(sharedSecret: shared, pairingKey: pairingKey, pairID: pairID,
                                               phonePeerID: requestPeerID, macPeerID: response.peerID,
                                               phonePublicKey: phonePublicKey, macPublicKey: response.ephemeralPublicKey)
        }
        let peer = PairedPeer(peerID: response.peerID, ltk: ltk.withUnsafeBytes { Data($0) }, name: response.name)
        try store.save(peer)
        finish(.success(peer))
    }

    private func send(_ message: ControlMessage, on connection: NWConnection) {
        do {
            let data = try message.encode(sequence: nextSequence(), sentAt: MonotonicClock.wireNanoseconds())
            connection.send(content: data, contentContext: Self.context(), isComplete: true, completion: .contentProcessed { [weak self, weak connection] error in
                guard let error else { return }
                Task { @MainActor in
                    guard let self, let connection, self.connection === connection else { return }
                    self.finish(.failure(Failure.network(error.localizedDescription)))
                }
            })
        } catch { finish(.failure(error)) }
    }

    private func nextSequence() -> UInt32 {
        defer { sequence &+= 1 }
        return sequence
    }

    private static func context() -> NWConnection.ContentContext {
        NWConnection.ContentContext(identifier: "pairing", metadata: [NWProtocolFramer.Message(definition: TGControlFramer.definition)])
    }

    private func finish(_ result: Result<PairedPeer, Error>) {
        let completion = completion
        self.completion = nil
        phase = .idle
        ephemeralKey = nil
        pairingKey = nil
        commit = nil
        phoneNonce = Data()
        macNonce = Data()
        showCode = nil
        timeout?.cancel()
        timeout = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        attempt = nil
        completion?.resume(with: result)
    }
}
