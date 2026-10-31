import ApplicationServices
import CryptoKit
import Foundation
import Network
import Observation
import Security
import TrackglassKit

@MainActor @Observable
final class PairingService {
    /// §3.4 (2026-10-31): the QR path (pairSecret channel, single-use code) or code pairing (public channel key; both
    /// screens compare a six-digit code). The pairing listener only ever holds the current mode's key.
    enum Mode { case qr, code }
    private(set) var mode: Mode = .qr
    private(set) var isOpen = false
    private(set) var isAdvertised = false
    private(set) var payload: PairingPayload?
    private(set) var status = "Open pairing to begin"
    private(set) var pairedPeers: [PairedPeer] = []
    private(set) var port: NWEndpoint.Port?
    /// Code sessions in this window opening that reached PAIR_COMMIT (§3.4: at most `maxCodeSessions`). A failed TLS
    /// handshake or a connection that never sends PAIR_REQUEST is not a session: nothing can be guessed through it.
    private(set) var codeSessions = 0
    nonisolated static let maxCodeSessions = 3
    /// §3.4 (owner decision 2026-10-28): the phone waits here until the user clicks Allow in the pairing window.
    /// Nothing is stored and no key material is sent before that click.
    struct PendingApproval: Equatable, Identifiable {
        let id = UUID()
        /// `PairingText.sanitizedName` of the requested name (the model name when nothing is left of it).
        let phoneName: String
        let modelName: String
        /// Code pairing: the six digits both screens show. nil on the QR path.
        let code: String?
        /// This phone is already paired under that name; allowing replaces the pairing.
        let replaces: String?
    }
    private(set) var pendingApproval: PendingApproval?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    /// Tests inject an automatic answer; the app asks the user (nil).
    private let approvalPolicy: (@MainActor (PendingApproval) async -> Bool)?
    private let identity: PeerIdentity
    private let store: PairingStore
    private let authorized: @MainActor () -> Bool
    private var listener: NWListener?
    /// The one pairing slot (§3.4): the connection being served and how far its exchange got.
    private var slot: Slot?
    private var deadline: Task<Void, Never>?
    private var generation = UUID()
    private var consumed = false
    private var windowID = UUID()
    private let windowLifetime: Duration
    /// The phone's automatic steps (TLS and PAIR_REQUEST after connecting; PAIR_NONCE after PAIR_COMMIT) must arrive
    /// within this, so a phone that vanished mid-handshake (or a stray `nc` to the port) cannot hold the one pairing
    /// slot until the window expires.
    private let requestTimeout: Duration
    var peersChanged: (() -> Void)?
    var windowExpired: (() -> Void)?
    /// Called when a phone is waiting for the Allow click, so the window can come forward (it may be on another Space).
    var approvalRequested: (() -> Void)?
    /// Nothing more can happen in this pairing window (paired, declined, expired, failed, closed), and no answer is
    /// still being sent to a phone: the window offers to start again.
    var isFinished: Bool { !isOpen || (consumed && slot == nil && approvalContinuation == nil) }
    /// A phone is past PAIR_REQUEST: the mode cannot change until its exchange ends.
    var sessionInProgress: Bool { slot.map { $0.phase != .awaitingRequest } ?? false }
    /// The last pairing in this window succeeded ("Pair another device" rather than "Try again").
    private(set) var didPair = false
    /// Connections in the pairing slot (tests).
    var connectionCount: Int { slot == nil ? 0 : 1 }

    private struct Slot {
        enum Phase {
            /// TLS and PAIR_REQUEST are due within `requestTimeout`.
            case awaitingRequest
            /// QR: the user is asked; the phone stays silent.
            case asking
            /// Code: PAIR_COMMIT sent; PAIR_NONCE is due within `requestTimeout`.
            case committed
            /// Code: PAIR_REVEAL sent; the Allow click and PAIR_CONFIRM may come in either order.
            case revealed
            /// PAIR_RESPONSE is on its way; its send completion decides.
            case responding
        }
        let connection: NWConnection
        let pairID: Data
        let id = UUID()
        var phase = Phase.awaitingRequest
        var sequence: UInt32 = 0
        var request: PairRequestMessage?
        var phoneName = ""
        var macPublicKey = Data()
        var sharedSecret: SharedSecret?
        var macNonce = Data()
        var phoneNonce = Data()
        var allowed = false
        var phoneConfirmed = false
    }

    /// How a code session that reached PAIR_COMMIT ended without pairing.
    private enum Ending { case mismatch, unfinished }

    init(identity: PeerIdentity, store: PairingStore = PairingStore(),
         authorized: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
         windowLifetime: Duration = .seconds(120),
         requestTimeout: Duration = .seconds(5),
         approvalPolicy: (@MainActor (PendingApproval) async -> Bool)? = nil) {
        self.identity = identity
        self.store = store
        self.authorized = authorized
        self.windowLifetime = windowLifetime
        self.requestTimeout = requestTimeout
        self.approvalPolicy = approvalPolicy
        refreshPeers()
    }

    /// The pairing window's Allow / Don't Allow buttons.
    func respondToPendingPairing(allow: Bool) {
        guard let continuation = approvalContinuation else { return }
        approvalContinuation = nil
        pendingApproval = nil
        continuation.resume(returning: allow)
    }

    private func approve(_ pending: PendingApproval) async -> Bool {
        if let approvalPolicy { return await approvalPolicy(pending) }
        return await withCheckedContinuation { continuation in
            respondToPendingPairing(allow: false)   // never two questions at once
            approvalContinuation = continuation
            pendingApproval = pending
            approvalRequested?()
        }
    }

    func open() {
        close()
        guard authorized() else { status = "Grant Accessibility permission before pairing."; return }
        isOpen = true
        consumed = false
        didPair = false
        mode = .qr
        codeSessions = 0
        let windowID = windowID
        deadline = Task { [weak self, windowLifetime] in
            do { try await Task.sleep(for: windowLifetime) } catch { return }
            guard let self, self.windowID == windowID else { return }
            self.close()
            self.status = "Pairing expired. Open a new window to try again."
            self.windowExpired?()
        }
        do {
            // One pairID per window opening (and the QR's 256-bit secret). Nothing rotates on a failed handshake any
            // more (§3.4, 2026-10-31): with these keys a failed handshake is never a guess.
            let payload = try PairingPayload(pairID: randomBytes(8), pairSecret: randomBytes(32),
                                             macName: identity.name, bonjourInstanceName: "\(identity.name) (pairing)")
            installListener(payload: payload)
        } catch { fail(error.localizedDescription) }
    }

    func setMode(_ mode: Mode) {
        guard isOpen, !consumed, !sessionInProgress, self.mode != mode, let payload else { return }
        self.mode = mode
        installListener(payload: payload)
    }

    /// What the window says while it waits for a phone.
    private var waitingStatus: String {
        mode == .code
            ? "On your iPhone or iPad, open Trackglass → Pair with a code and choose “\(identity.name)”."
            : "Scan with Trackglass on your iPhone or iPad."
    }

    /// (Re)starts the pairing listener with the current mode's key only (§3.4): the QR's pairSecret, or the public
    /// code-channel key. Restarting drops any connection accepted under the previous key.
    private func installListener(payload: PairingPayload) {
        stopTransport()
        do {
            let key = mode == .code ? try KeyDerivation.codeChannelKey(pairID: payload.pairID) : SymmetricKey(data: payload.pairSecret)
            let options = TLSConfig.tlsOptions(psk: key, identity: payload.identity)
            let listener = try NWListener(using: TLSConfig.parameters(control: options))
            let txt = NWTXTRecord(["v": "1", "id": identity.tlsIdentity, "nm": identity.name,
                                   "pr": "1", "pid": payload.identity])
            listener.service = NWListener.Service(name: payload.bonjourInstanceName, type: "_trackglass._tcp", txtRecord: txt)
            self.listener = listener
            self.payload = payload
            let generation = generation
            status = "Starting pairing…"
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    switch state {
                    case .ready:
                        self.port = self.listener?.port
                        if !self.isAdvertised { self.status = "Waiting for Bonjour. Allow Local Network access for Trackglass for Mac." }
                    case .failed(let error):
                        LocalNetworkPermission.shared.report(error)
                        self.fail(LocalNetworkPermission.message(for: error, failed: true))
                    case .waiting(let error):
                        LocalNetworkPermission.shared.report(error)
                        self.status = LocalNetworkPermission.isPolicyDenied(error)
                            ? LocalNetworkPermission.message(for: error, failed: false) : "Waiting: \(error.localizedDescription)"
                    default: break
                    }
                }
            }
            listener.serviceRegistrationUpdateHandler = { [weak self] change in
                Task { @MainActor in
                    guard let self, self.generation == generation, !self.consumed else { return }
                    switch change {
                    case .add(let endpoint):
                        guard case let .service(name, _, _, _) = endpoint, let payload = self.payload else { return }
                        self.payload = try? PairingPayload(pairID: payload.pairID, pairSecret: payload.pairSecret,
                                                          macName: payload.macName, bonjourInstanceName: name)
                        self.isAdvertised = true
                        LocalNetworkPermission.shared.reportRegistered()
                        if !self.sessionInProgress { self.status = self.waitingStatus }
                    case .remove:
                        self.isAdvertised = false
                        // Never over a running exchange (e.g. "Does “X” show 123 456?").
                        if !self.sessionInProgress { self.status = "Waiting for Bonjour. Check Local Network permission." }
                    @unknown default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.generation == generation else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            listener.start(queue: .main)

        } catch { fail(error.localizedDescription) }
    }

    func close() {
        // A phone in the middle of an exchange is told the pairing ended (BYE{0}, §3.4) instead of seeing the
        // connection drop, which it could only report as an invalid response.
        if let current = slot, current.phase != .awaitingRequest, current.phase != .responding {
            slot = nil
            sendBye(on: current.connection, sequence: current.sequence)
        }
        respondToPendingPairing(allow: false)
        windowID = UUID()
        deadline?.cancel()
        deadline = nil
        stopTransport()
        payload = nil
        isOpen = false
    }

    private func stopTransport() {
        generation = UUID()
        listener?.cancel()
        listener = nil
        if let current = slot {
            current.connection.stateUpdateHandler = nil
            current.connection.cancel()
        }
        slot = nil
        port = nil
        isAdvertised = false
    }

    private func accept(_ connection: NWConnection) {
        // One slot (§3.4). A newcomer never evicts the connection holding it; a connection that does not deliver
        // PAIR_REQUEST (TLS included) within `requestTimeout` loses the slot instead.
        guard isOpen, !consumed, slot == nil, let payload else { connection.cancel(); return }
        let current = Slot(connection: connection, pairID: payload.pairID)
        slot = current
        expire(current.id, ifStillIn: .awaitingRequest)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection, self.slot?.connection === connection else { return }
                switch state {
                case .ready: self.receive(connection)
                // A failed handshake spends nothing in either mode (§3.4, 2026-10-31): the QR's secret has 256 bits and
                // the code channel's key is public, so it is never a guess. It only frees the slot.
                case .failed, .waiting, .cancelled: self.endSlot(.unfinished)
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    /// Frees the slot if its exchange is still in `phase` after `requestTimeout`: the phone's automatic steps must not
    /// hold the one slot (§3.4).
    private func expire(_ slotID: UUID, ifStillIn phase: Slot.Phase) {
        Task { [weak self, requestTimeout] in
            try? await Task.sleep(for: requestTimeout)
            guard let self, let current = self.slot, current.id == slotID, current.phase == phase else { return }
            self.endSlot(.unfinished)
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, complete, error in
            Task { @MainActor in
                // While PAIR_RESPONSE is on its way its send completion decides; the phone closing after it is normal.
                guard let self, let connection, let current = self.slot, current.connection === connection,
                      current.phase != .responding else { return }
                guard error == nil, complete, let data, let packet = try? ControlMessage.decode(data) else {
                    self.endSlot(.unfinished); return
                }
                self.handle(packet.message, in: current)
            }
        }
    }

    /// One step of §3.4's order. Anything else — out of order, repeated, unknown, a BYE before the code was shown —
    /// ends the exchange.
    private func handle(_ message: ControlMessage, in current: Slot) {
        switch (current.phase, message) {
        case (.awaitingRequest, .pairRequest(let request)) where request.protocolVersion == MessageHeader.protocolVersion:
            if mode == .code { commit(to: request, in: current) } else { askToAllow(request, in: current) }
        case (.committed, .pairNonce(let nonce)):
            reveal(phoneNonce: nonce.nonce, in: current)
        case (.revealed, .pairConfirm) where !current.phoneConfirmed:
            slot?.phoneConfirmed = true
            if current.allowed { respondToCode() } else { receive(current.connection) }
        case (.revealed, .bye):
            endSlot(.mismatch)   // the phone's user tapped "Doesn't match"
        default:
            endSlot(.unfinished)
        }
    }

    /// QR path: the single-use code is spent now, and the user decides before anything is stored or sent (§3.4).
    private func askToAllow(_ request: PairRequestMessage, in current: Slot) {
        guard let payload else { endSlot(.unfinished); return }
        let pairingKey = SymmetricKey(data: payload.pairSecret)
        // Consumed on the main actor before any answer is queued, excluding concurrent requests. The window's 120 s
        // expiry keeps running through the question (an unanswered question expires and the phone gets BYE{0}).
        consumeWindow()
        let name = displayName(of: request)
        slot?.phase = .asking
        slot?.request = request
        slot?.phoneName = name
        receive(current.connection)   // the phone stays silent while asked: any callback means it left
        status = "Allow “\(name)” to pair with this Mac?"
        let slotID = current.id, pairID = current.pairID, generation = generation
        let pending = PendingApproval(phoneName: name, modelName: modelName(of: request), code: nil, replaces: replacedName(of: request))
        Task { [weak self] in
            guard let self else { return }
            let allowed = await self.approve(pending)
            guard self.generation == generation, let after = self.slot, after.id == slotID else { return }
            guard allowed else {
                self.slot = nil
                self.sendBye(on: after.connection, sequence: after.sequence)
                self.close()
                self.status = "Pairing with “\(name)” was not allowed. Open a new window to pair again."
                return
            }
            do {
                // Both sides derive the LTK from a fresh X25519 exchange; it never crosses the wire.
                let macKey = Curve25519.KeyAgreement.PrivateKey()
                let macPublicKey = macKey.publicKey.rawRepresentation
                let shared = try KeyDerivation.sharedSecret(privateKey: macKey, peerPublicKey: request.ephemeralPublicKey)
                let ltk = try KeyDerivation.pairingLTK(sharedSecret: shared, pairingKey: pairingKey, pairID: pairID,
                                                       phonePeerID: request.peerID, macPeerID: self.identity.peerID,
                                                       phonePublicKey: request.ephemeralPublicKey, macPublicKey: macPublicKey)
                self.respond(ltk: ltk, macPublicKey: macPublicKey)
            } catch { self.fail("Pairing failed: \(error.localizedDescription)") }
        }
    }

    /// Code path, step 1: PAIR_COMMIT binds Nm before the phone draws Np. The session counts from here (§3.4).
    private func commit(to request: PairRequestMessage, in current: Slot) {
        guard codeSessions < Self.maxCodeSessions else { endSlot(.unfinished); return }
        do {
            let macKey = Curve25519.KeyAgreement.PrivateKey()
            let macPublicKey = macKey.publicKey.rawRepresentation
            let shared = try KeyDerivation.sharedSecret(privateKey: macKey, peerPublicKey: request.ephemeralPublicKey)
            let macNonce = KeyDerivation.randomNonce()
            let commitment = try KeyDerivation.commitment(macNonce: macNonce, macPublicKey: macPublicKey,
                                                          phonePublicKey: request.ephemeralPublicKey)
            let name = displayName(of: request)
            codeSessions += 1
            slot?.phase = .committed
            slot?.request = request
            slot?.phoneName = name
            slot?.macPublicKey = macPublicKey
            slot?.sharedSecret = shared
            slot?.macNonce = macNonce
            let data = try encode(.pairCommit(PairCommitMessage(peerID: identity.peerID, name: identity.name,
                                                                ephemeralPublicKey: macPublicKey, commitment: commitment)))
            current.connection.send(content: data, contentContext: Self.context(), isComplete: true, completion: .idempotent)
            status = "Pairing with “\(name)”…"
            expire(current.id, ifStillIn: .committed)
            receive(current.connection)
        } catch { endSlot(.unfinished) }
    }

    /// Code path, step 2: Np arrived after the commitment, so Nm is revealed and both screens can show the code.
    private func reveal(phoneNonce: Data, in current: Slot) {
        guard let request = current.request else { endSlot(.unfinished); return }
        do {
            let code = try KeyDerivation.comparisonCode(pairID: current.pairID, phonePeerID: request.peerID, macPeerID: identity.peerID,
                                                        phonePublicKey: request.ephemeralPublicKey, macPublicKey: current.macPublicKey,
                                                        phoneNonce: phoneNonce, macNonce: current.macNonce)
            let data = try encode(.pairReveal(PairNonceMessage(nonce: current.macNonce)))
            slot?.phase = .revealed
            slot?.phoneNonce = phoneNonce
            current.connection.send(content: data, contentContext: Self.context(), isComplete: true, completion: .idempotent)
            receive(current.connection)
            askToCompare(code, request: request, slotID: current.id, name: current.phoneName)
        } catch { endSlot(.unfinished) }
    }

    /// Code path, step 3: the user compares the codes. Allow and the phone's PAIR_CONFIRM may arrive in either order;
    /// PAIR_RESPONSE waits for both.
    private func askToCompare(_ code: String, request: PairRequestMessage, slotID: UUID, name: String) {
        status = "Does “\(name)” show \(PairingText.formattedCode(code))? Allow only if it shows the same code."
        let generation = generation
        let pending = PendingApproval(phoneName: name, modelName: modelName(of: request), code: code, replaces: replacedName(of: request))
        Task { [weak self] in
            guard let self else { return }
            let allowed = await self.approve(pending)
            guard self.generation == generation, let after = self.slot, after.id == slotID else { return }
            guard allowed else { self.endSlot(.mismatch, tellPhone: true); return }
            self.slot?.allowed = true
            if after.phoneConfirmed {
                self.respondToCode()
            } else {
                self.status = "Waiting for “\(name)” to confirm the code…"
            }
        }
    }

    /// Both users confirmed the code: derive the code-pairing LTK and answer.
    private func respondToCode() {
        guard let current = slot, let request = current.request, let shared = current.sharedSecret else { return }
        do {
            let ltk = try KeyDerivation.codePairingLTK(sharedSecret: shared, pairID: current.pairID, phonePeerID: request.peerID,
                                                       macPeerID: identity.peerID, phonePublicKey: request.ephemeralPublicKey,
                                                       macPublicKey: current.macPublicKey, phoneNonce: current.phoneNonce,
                                                       macNonce: current.macNonce)
            consumeWindow()
            respond(ltk: ltk, macPublicKey: current.macPublicKey)
        } catch { fail("Pairing failed: \(error.localizedDescription)") }
    }

    /// Stores the pairing, then sends PAIR_RESPONSE. If it never reaches the phone, the phone's previous pairing (a
    /// re-pair) is put back rather than deleted, so the key the phone still holds keeps working (§3.4, round 4 L5).
    private func respond(ltk: SymmetricKey, macPublicKey: Data) {
        guard let current = slot, let request = current.request else { return }
        // From here the response decides; the expiry must not cut it off midway.
        deadline?.cancel(); deadline = nil
        let generation = generation, name = current.phoneName, store = store, connection = current.connection
        do {
            let response = try encode(.pairResponse(PairResponseMessage(peerID: identity.peerID, name: identity.name,
                                                                        ephemeralPublicKey: macPublicKey)))
            let previous = try store.replace(with: PairedPeer(peerID: request.peerID, ltk: ltk.withUnsafeBytes { Data($0) }, name: name))
            slot?.phase = .responding
            refreshPeers()
            connection.send(content: response, contentContext: Self.context(), isComplete: true, completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    if error != nil { try? store.restore(previous, peerID: request.peerID) }
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    guard let self else { return }
                    if error != nil { self.refreshPeers() }
                    guard self.generation == generation else { return }
                    if self.slot?.connection === connection { self.slot = nil }
                    if error == nil {
                        self.didPair = true
                        self.status = "Paired with “\(name)”"
                    } else {
                        self.status = "Pairing response failed. Open a new window to retry."
                    }
                }
            })
        } catch { fail("Pairing failed: \(error.localizedDescription)") }
    }

    /// Frees the slot. Before PAIR_REQUEST nothing was spent. A QR exchange ends the window (its code is single-use).
    /// A code session that reached PAIR_COMMIT has counted; another may start while attempts remain (§3.4).
    private func endSlot(_ ending: Ending, tellPhone: Bool = false) {
        guard let current = slot, current.phase != .responding else { return }
        slot = nil
        if tellPhone {
            sendBye(on: current.connection, sequence: current.sequence)
        } else {
            current.connection.stateUpdateHandler = nil
            current.connection.cancel()
        }
        respondToPendingPairing(allow: false)   // withdraw a question still on screen
        switch current.phase {
        case .awaitingRequest, .responding:
            return
        case .asking:
            close()
            status = "“\(current.phoneName)” disconnected before pairing finished. Open a new window to pair again."
        case .committed, .revealed:
            let reason = ending == .mismatch ? "The codes didn't match" : "Pairing with “\(current.phoneName)” did not finish"
            guard codeSessions < Self.maxCodeSessions else {
                close()
                status = "\(reason). All \(Self.maxCodeSessions) attempts of this window are used; click Try again to start over."
                return
            }
            status = "\(reason) — try again.\n\(isAdvertised ? waitingStatus : "Waiting for Bonjour. Check Local Network permission.")"
        }
    }

    /// No further connection is accepted in this window opening.
    private func consumeWindow() {
        consumed = true
        isAdvertised = false
        listener?.cancel()
        listener = nil
        payload = nil
        port = nil
    }

    /// Tells the phone the pairing ended (BYE reason 0) before the connection closes.
    private func sendBye(on connection: NWConnection, sequence: UInt32) {
        connection.stateUpdateHandler = nil
        guard let encoded = try? ControlMessage.bye(ByeMessage(reason: 0)).encode(sequence: sequence, sentAt: MonotonicClock.wireNanoseconds()) else {
            connection.cancel(); return
        }
        connection.send(content: encoded, contentContext: Self.context(), isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// The slot's next message, stamped with the wire clock (§4.2).
    private func encode(_ message: ControlMessage) throws -> Data {
        let sequence = slot?.sequence ?? 0
        slot?.sequence &+= 1
        return try message.encode(sequence: sequence, sentAt: MonotonicClock.wireNanoseconds())
    }

    private static func context() -> NWConnection.ContentContext {
        NWConnection.ContentContext(identifier: "pairing", metadata: [NWProtocolFramer.Message(definition: TGControlFramer.definition)])
    }

    /// What every prompt shows for the phone (§3.4): its sanitized name, or its model name when nothing is left.
    private func displayName(of request: PairRequestMessage) -> String {
        let name = PairingText.sanitizedName(request.name)
        return name.isEmpty ? modelName(of: request) : name
    }

    private func modelName(of request: PairRequestMessage) -> String {
        DeviceModelName.marketingName(modelIdentifier: request.modelIdentifier)
    }

    /// The name this phone is already paired under, if it is: allowing replaces that pairing.
    private func replacedName(of request: PairRequestMessage) -> String? {
        guard let previous = try? store.load(peerID: request.peerID) else { return nil }
        return PairingText.sanitizedName(previous.name)
    }

    private func fail(_ message: String) { close(); status = message }

    func refreshPeers() {
        do {
            let peers = try store.all()
            let changed = peers != pairedPeers
            pairedPeers = peers
            // Listener restarts are expensive (they drop live sessions); only report a real change.
            if changed { peersChanged?() }
        } catch { status = "Cannot read paired devices: \(error.localizedDescription)" }
    }

    private func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard result == errSecSuccess else { throw PairingStoreError.keychain(result) }
        return data
    }
}
