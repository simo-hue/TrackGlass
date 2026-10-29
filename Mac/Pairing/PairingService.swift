import ApplicationServices
import CryptoKit
import Foundation
import Network
import Observation
import Security
import TrackglassKit

@MainActor @Observable
final class PairingService {
    enum Mode { case qr, pin }
    private(set) var mode: Mode = .qr
    private(set) var pin: String?
    private(set) var pinGeneration = 0
    private(set) var isOpen = false
    private(set) var isAdvertised = false
    private(set) var payload: PairingPayload?
    private(set) var status = "Open pairing to begin"
    private(set) var pairedPeers: [PairedPeer] = []
    private(set) var port: NWEndpoint.Port?
    /// §3.4 (owner decision 2026-10-28): a phone that completed the authenticated pairing handshake waits here until
    /// the user clicks Allow in the pairing window. Nothing is stored and no key material is sent before that click.
    struct PendingApproval: Equatable {
        let phoneName: String
        let modelName: String
    }
    private(set) var pendingApproval: PendingApproval?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    /// Tests inject an automatic answer; the app asks the user (nil).
    private let approvalPolicy: (@MainActor (PairRequestMessage) async -> Bool)?
    /// The PSK of the current pairing listener (pairSecret or PIN key); it is mixed into the LTK (§3.4).
    private var listenerKey: SymmetricKey?
    private let identity: PeerIdentity
    private let store: PairingStore
    private let authorized: @MainActor () -> Bool
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var deadline: Task<Void, Never>?
    private var generation = UUID()
    private var consumed = false
    private var handshakesReady = Set<ObjectIdentifier>()
    private var windowID = UUID()
    private let windowLifetime: Duration
    /// A connection that has not delivered PAIR_REQUEST this long after it arrived is dropped, so a phone that
    /// vanished mid-handshake (or a stray `nc` to the port) cannot hold the one pairing slot until the window expires.
    private let requestTimeout: Duration
    var peersChanged: (() -> Void)?
    var windowExpired: (() -> Void)?
    /// Called when a phone is waiting for the Allow click, so the window can come forward (it may be on another Space).
    var approvalRequested: (() -> Void)?
    /// Nothing more can happen in this pairing window (paired, declined, expired, failed, closed), and no answer is
    /// still being sent to a phone: the window offers to start again.
    var isFinished: Bool { !isOpen || (consumed && connections.isEmpty && approvalContinuation == nil) }
    /// The last pairing in this window succeeded ("Pair another device" rather than "Try again").
    private(set) var didPair = false
    /// Connections in the pairing slot (tests).
    var connectionCount: Int { connections.count }

    init(identity: PeerIdentity, store: PairingStore = PairingStore(),
         authorized: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
         windowLifetime: Duration = .seconds(120),
         requestTimeout: Duration = .seconds(5),
         approvalPolicy: (@MainActor (PairRequestMessage) async -> Bool)? = nil) {
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

    private func approve(_ request: PairRequestMessage) async -> Bool {
        if let approvalPolicy { return await approvalPolicy(request) }
        return await withCheckedContinuation { continuation in
            respondToPendingPairing(allow: false)   // never two questions at once
            approvalContinuation = continuation
            pendingApproval = PendingApproval(phoneName: request.name,
                                              modelName: DeviceModelName.marketingName(modelIdentifier: request.modelIdentifier))
            status = "Allow “\(request.name)” to pair with this Mac?"
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
        pinGeneration = 0
        let windowID = windowID
        deadline = Task { [weak self, windowLifetime] in
            do { try await Task.sleep(for: windowLifetime) } catch { return }
            guard let self, self.windowID == windowID else { return }
            self.close()
            self.status = "Pairing expired. Open a new window to try again."
            self.windowExpired?()
        }
        rotateCredentials()
    }

    func setMode(_ mode: Mode) {
        guard isOpen, !consumed, self.mode != mode, let payload, let pin else { return }
        self.mode = mode
        installListener(payload: payload, pin: pin)
    }

    private func rotateCredentials() {
        guard isOpen, !consumed else { return }
        guard pinGeneration < 3 else {
            close()
            status = "Three codes have failed. Close this window and open a new one to retry."
            return
        }
        do {
            let payload = try PairingPayload(pairID: randomBytes(8), pairSecret: randomBytes(32),
                                             macName: identity.name, bonjourInstanceName: "\(identity.name) (pairing)")
            var newPIN = try randomPIN()
            while newPIN == pin { newPIN = try randomPIN() }
            pinGeneration += 1
            installListener(payload: payload, pin: newPIN)
        } catch { fail(error.localizedDescription) }
    }

    private func installListener(payload: PairingPayload, pin: String) {
        stopTransport()
        do {
            let key = mode == .pin ? try KeyDerivation.pinKey(pin: pin, pairID: payload.pairID) : SymmetricKey(data: payload.pairSecret)
            let options = TLSConfig.tlsOptions(psk: key, identity: payload.identity)
            let listener = try NWListener(using: TLSConfig.parameters(control: options))
            listenerKey = key
            let txt = NWTXTRecord(["v": "1", "id": identity.tlsIdentity, "nm": identity.name,
                                   "pr": "1", "pid": payload.identity])
            listener.service = NWListener.Service(name: payload.bonjourInstanceName, type: "_trackglass._tcp", txtRecord: txt)
            self.listener = listener
            self.payload = payload
            self.pin = pin
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
                        self.status = self.mode == .pin ? "Enter this code in Trackglass on your iPhone or iPad." : "Scan with Trackglass on your iPhone or iPad."
                    case .remove:
                        self.isAdvertised = false
                        self.status = "Waiting for Bonjour. Check Local Network permission."
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
        // A phone waiting for the Allow click is told the pairing ended (BYE{0}, §3.4) instead of seeing the
        // connection drop, which it could only report as an invalid response or a wrong code.
        if approvalContinuation != nil { for connection in Array(connections.values) { sendBye(on: connection) } }
        respondToPendingPairing(allow: false)
        listenerKey = nil
        windowID = UUID()
        deadline?.cancel()
        deadline = nil
        stopTransport()
        payload = nil
        pin = nil
        isOpen = false
    }

    private func stopTransport() {
        generation = UUID()
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connections.removeAll()
        handshakesReady.removeAll()
        port = nil
        isAdvertised = false
    }

    private func accept(_ connection: NWConnection) {
        // One slot (§3.4). A newcomer never evicts the connection holding it: an evicted handshake's key failure
        // would go uncounted, letting pipelined PIN guesses escape the three-code limit. A connection that never
        // sends PAIR_REQUEST loses the slot after `requestTimeout` instead.
        guard isOpen, !consumed, connections.isEmpty else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        let generation = generation
        Task { [weak self, weak connection, requestTimeout] in
            try? await Task.sleep(for: requestTimeout)
            guard let self, let connection, self.generation == generation, !self.consumed,
                  self.connections[ObjectIdentifier(connection)] != nil else { return }
            self.remove(connection)
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection, self.connections[ObjectIdentifier(connection)] != nil else { return }
                switch state {
                case .ready:
                    self.handshakesReady.insert(ObjectIdentifier(connection))
                    self.receive(connection)
                case .failed(let error), .waiting(let error):
                    // Only a handshake that got as far as testing the key spends a code (§3.4): a port scan or a
                    // phone that gives up mid-handshake must not rotate the QR/PIN or close the window.
                    let keyAttempt = !self.handshakesReady.contains(ObjectIdentifier(connection)) && Self.isKeyAttempt(error)
                    self.remove(connection)
                    if keyAttempt { self.rotateCredentials() }
                case .cancelled: self.remove(connection)
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    /// TLS failures other than the peer simply going away (close_notify / abort before the key was tried).
    nonisolated static func isKeyAttempt(_ error: NWError) -> Bool {
        guard case let .tls(status) = error else { return false }
        // errSSLClosedGraceful −9805, errSSLClosedAbort −9806, errSSLClosedNoNotify −9816
        return ![-9805, -9806, -9816].contains(status)
    }

    /// While the user is asked, the phone sends nothing; any callback here (end of stream, error, stray data)
    /// means it gave up or misbehaved, so the connection is dropped and the question withdrawn.
    private func watchForDeparture(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] _, _, _, _ in
            Task { @MainActor in
                guard let self, let connection, self.connections[ObjectIdentifier(connection)] != nil else { return }
                self.remove(connection)
            }
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, complete, error in
            Task { @MainActor in
                guard let self, let connection,
                      self.connections[ObjectIdentifier(connection)] != nil else { return }
                guard self.isOpen, !self.consumed, error == nil, complete, let data else { self.remove(connection); return }
                do {
                    let packet = try ControlMessage.decode(data)
                    guard case let .pairRequest(request) = packet.message,
                          request.protocolVersion == MessageHeader.protocolVersion,
                          let pairingKey = self.listenerKey, let pairID = self.payload?.pairID else {
                        self.remove(connection); return
                    }
                    // Consume on the main actor before any response is queued, excluding concurrent requests.
                    // The window's 120 s expiry keeps running through the Allow question (§3.4: an unanswered
                    // question expires with the window and the phone gets BYE{0}).
                    self.consumed = true
                    self.isAdvertised = false
                    self.listener?.cancel()
                    self.listener = nil
                    self.payload = nil
                    self.pin = nil
                    self.port = nil
                    for other in Array(self.connections.values) where other !== connection { self.remove(other) }
                    self.watchForDeparture(connection)
                    // §3.4 hardening: the user confirms on the Mac before anything is stored or any key material
                    // is sent; then both sides derive the LTK from a fresh X25519 exchange (it never crosses the wire).
                    let generation = self.generation
                    let allowed = await self.approve(request)
                    guard self.generation == generation else { return }   // window closed or expired meanwhile
                    guard self.connections[ObjectIdentifier(connection)] != nil else {
                        self.close()
                        self.status = "\(request.name) disconnected before pairing finished. Open a new window to pair again."
                        return
                    }
                    guard allowed else {
                        self.sendBye(on: connection)
                        self.close()
                        self.status = "Pairing with \(request.name) was not allowed. Open a new window to pair again."
                        return
                    }
                    // Allowed: from here the response decides; the expiry must not cut it off midway.
                    self.deadline?.cancel(); self.deadline = nil
                    let macKey = Curve25519.KeyAgreement.PrivateKey()
                    let shared = try KeyDerivation.sharedSecret(privateKey: macKey, peerPublicKey: request.ephemeralPublicKey)
                    let macPublicKey = macKey.publicKey.rawRepresentation
                    let ltk = try KeyDerivation.pairingLTK(sharedSecret: shared, pairingKey: pairingKey, pairID: pairID,
                                                           phonePeerID: request.peerID, macPeerID: self.identity.peerID,
                                                           phonePublicKey: request.ephemeralPublicKey, macPublicKey: macPublicKey)
                    try self.store.save(PairedPeer(peerID: request.peerID, ltk: ltk.withUnsafeBytes { Data($0) }, name: request.name))
                    self.listenerKey = nil
                    self.refreshPeers()
                    let response = ControlMessage.pairResponse(PairResponseMessage(peerID: self.identity.peerID, name: self.identity.name,
                                                                                   ephemeralPublicKey: macPublicKey))
                    let encoded = try response.encode(sequence: 0, sentAt: MonotonicClock.nanoseconds())
                    let context = NWConnection.ContentContext(identifier: "pairing", metadata: [NWProtocolFramer.Message(definition: TGControlFramer.definition)])
                    connection.send(content: encoded, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self, weak connection] error in
                        Task { @MainActor in
                            guard let self, self.generation == generation else { return }
                            if let connection { self.remove(connection) }
                            if error == nil {
                                self.didPair = true
                                self.status = "Paired with \(request.name)"
                            } else {
                                // The phone never got the response, so it has no key: keep no half pairing.
                                try? self.store.delete(peerID: request.peerID)
                                self.refreshPeers()
                                self.status = "Pairing response failed. Open a new window to retry."
                            }
                        }
                    })
                } catch { self.fail("Pairing failed: \(error.localizedDescription)") }
            }
        }
    }

    /// Tells the phone the pairing was declined (BYE reason 0) before the connection closes.
    private func sendBye(on connection: NWConnection) {
        guard let encoded = try? ControlMessage.bye(ByeMessage(reason: 0)).encode(sequence: 0, sentAt: MonotonicClock.nanoseconds()) else {
            remove(connection); return
        }
        let context = NWConnection.ContentContext(identifier: "pairing", metadata: [NWProtocolFramer.Message(definition: TGControlFramer.definition)])
        connection.stateUpdateHandler = nil
        connections.removeValue(forKey: ObjectIdentifier(connection))
        handshakesReady.remove(ObjectIdentifier(connection))
        connection.send(content: encoded, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func remove(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        handshakesReady.remove(ObjectIdentifier(connection))
        connection.stateUpdateHandler = nil
        connection.cancel()
        // The phone gave up while the Mac was asking: withdraw the question.
        if connections.isEmpty, approvalContinuation != nil { respondToPendingPairing(allow: false) }
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

    private func randomPIN() throws -> String {
        // Rejection sampling avoids modulo bias and preserves leading zeros.
        while true {
            let value = try randomBytes(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            if value < 4_294_000_000 { return String(format: "%06u", value % 1_000_000) }
        }
    }

    private func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard result == errSecSuccess else { throw PairingStoreError.keychain(result) }
        return data
    }
}
