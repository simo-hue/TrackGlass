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
    var peersChanged: (() -> Void)?
    var windowExpired: (() -> Void)?

    init(identity: PeerIdentity, store: PairingStore = PairingStore(),
         authorized: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
         windowLifetime: Duration = .seconds(120)) {
        self.identity = identity
        self.store = store
        self.authorized = authorized
        self.windowLifetime = windowLifetime
        refreshPeers()
    }

    func open() {
        close()
        guard authorized() else { status = "Grant Accessibility permission before pairing."; return }
        isOpen = true
        consumed = false
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
                        if !self.isAdvertised { self.status = "Waiting for Bonjour. Allow Local Network access for Trackglass." }
                    case .failed(let error): self.fail(error.localizedDescription)
                    case .waiting(let error): self.status = "Waiting: \(error.localizedDescription)"
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
        guard isOpen, !consumed, connections.isEmpty else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection, self.connections[ObjectIdentifier(connection)] != nil else { return }
                switch state {
                case .ready:
                    self.handshakesReady.insert(ObjectIdentifier(connection))
                    self.receive(connection)
                case .failed, .waiting:
                    let handshakeFailed = !self.handshakesReady.contains(ObjectIdentifier(connection))
                    self.remove(connection)
                    if handshakeFailed { self.rotateCredentials() }
                case .cancelled: self.remove(connection)
                default: break
                }
            }
        }
        connection.start(queue: .main)
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
                          request.protocolVersion == MessageHeader.protocolVersion else {
                        self.remove(connection); return
                    }
                    // Consume on the main actor before any response is queued, excluding concurrent requests.
                    self.consumed = true
                    self.isAdvertised = false
                    self.listener?.cancel()
                    self.listener = nil
                    self.payload = nil
                    self.pin = nil
                    self.port = nil
                    for other in Array(self.connections.values) where other !== connection { self.remove(other) }
                    let ltk = try self.randomBytes(32)
                    try self.store.save(PairedPeer(peerID: request.peerID, ltk: ltk, name: request.name))
                    self.refreshPeers()
                    let response = ControlMessage.pairResponse(PairResponseMessage(peerID: self.identity.peerID, name: self.identity.name, ltk: ltk))
                    let encoded = try response.encode(sequence: 0, sentAt: MonotonicClock.nanoseconds())
                    let context = NWConnection.ContentContext(identifier: "pairing", metadata: [NWProtocolFramer.Message(definition: TGControlFramer.definition)])
                    let generation = self.generation
                    connection.send(content: encoded, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self, weak connection] error in
                        Task { @MainActor in
                            guard let self, self.generation == generation else { return }
                            if let connection { self.remove(connection) }
                            self.status = error == nil ? "Paired with \(request.name)" : "Pairing response failed. Open a new window to retry."
                        }
                    })
                } catch { self.fail("Pairing failed: \(error.localizedDescription)") }
            }
        }
    }

    private func remove(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        handshakesReady.remove(ObjectIdentifier(connection))
        connection.stateUpdateHandler = nil
        connection.cancel()
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
