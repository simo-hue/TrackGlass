import AppKit
import CryptoKit
import Network
import Observation
import OSLog
import TrackglassKit

@MainActor @Observable
final class BonjourAdvertiser {
    private(set) var status = "Starting discovery…"
    let name: String
    let peerID: UUID
    let accessibilityPermission = AccessibilityPermission()
    var permissionRevoked: (() -> Void)?
    var controlHandler: ((NWConnection) -> Void)?
    var inputHandler: ((NWConnection) -> Void)?
    private let store: PairingStore
    private var control: NWListener?
    private var input: NWListener?
    /// The phone whose LTK the input listener carries; survives listener restarts (§6.3).
    private var admittedInputPeer: UUID?
    private var ready = Set<String>()
    private var registered = Set<String>()
    private let logger = Logger(subsystem: "app.trackglass.mac", category: "Input")

    init(defaults: UserDefaults = .standard, store: PairingStore = PairingStore()) {
        self.store = store
        name = Host.current().localizedName ?? "Mac"
        if let stored = defaults.string(forKey: "peerID"), let id = UUID(uuidString: stored) {
            peerID = id
        } else {
            peerID = UUID()
            defaults.set(peerID.uuidString, forKey: "peerID")
        }
        accessibilityPermission.onChange = { [weak self] trusted in
            guard let self else { return }
            if trusted { self.startListeners() }
            else {
                self.stop(monitorPermission: false)
                self.status = "Accessibility permission required"
                self.permissionRevoked?()
            }
        }
    }

    func start() {
        guard control == nil else { return }
        accessibilityPermission.requestAndMonitor()
        if accessibilityPermission.isTrusted {
            startListeners()
        } else {
            status = "Accessibility permission required"
        }
    }

    static func txtRecord(peerID: UUID, name: String) -> NWTXTRecord {
        NWTXTRecord(["v": "1", "id": peerID.uuidString.lowercased(), "nm": name, "pr": "0", "im": "1"])
    }

    private func startListeners() {
        guard control == nil else { return }
        do {
            let keys = try store.all().map { (SymmetricKey(data: $0.ltk), $0.peerID.uuidString.lowercased()) }
            let tcp = try NWListener(using: TLSConfig.parameters(control: TLSConfig.listenerOptions(keys: keys)))
            let udp = try makeInputListener(peerID: admittedInputPeer, port: input?.port)
            control = tcp
            input = udp
            attach(tcp, kind: "tcp")
            attach(udp, kind: "udp")
        } catch {
            status = "Discovery failed: \(error.localizedDescription)"
        }
    }

    private func attach(_ listener: NWListener, kind: String) {
        listener.service = NWListener.Service(name: name, type: kind == "tcp" ? "_trackglass._tcp" : "_trackglass._udp",
                                              txtRecord: Self.txtRecord(peerID: peerID, name: name))
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor in
                guard let self, let listener else { connection.cancel(); return }
                let handler: ((NWConnection) -> Void)?
                if self.control === listener { handler = self.controlHandler }
                else if self.input === listener { handler = self.inputHandler }
                else { handler = nil }
                guard let handler else { connection.cancel(); return }
                handler(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.control === listener || self.input === listener else { return }
                self.update(state, kind: kind)
            }
        }
        listener.serviceRegistrationUpdateHandler = { [weak self, weak listener] change in
            Task { @MainActor in
                guard let self, let listener, self.control === listener || self.input === listener else { return }
                self.registrationChanged(change, kind: kind)
            }
        }
        listener.start(queue: .main)
    }

    func update(_ state: NWListener.State, kind: String) {
        switch state {
        case .ready:
            ready.insert(kind)
            if kind == "udp", let port = input?.port?.rawValue {
                logger.info("input listener ready udpPort=\(port)")
            }
            refreshStatus()
        case .waiting(let error):
            ready.remove(kind)
            status = "Discovery waiting: \(error.localizedDescription)"
        case .failed(let error):
            ready.remove(kind)
            status = "Discovery failed: \(error.localizedDescription)"
        default: break
        }
    }

    func registrationChanged(_ change: NWListener.ServiceRegistrationChange, kind: String) {
        switch change {
        case .add: registered.insert(kind)
        case .remove: registered.remove(kind)
        @unknown default: break
        }
        refreshStatus()
    }

    private func refreshStatus() {
        if ready.count == 2 && registered.count == 2 {
            status = "Advertising as \(name)"
        } else {
            status = "Waiting for Bonjour. Check Local Network permission."
        }
    }

    /// The paired-key set changed: only the control (TLS) listener carries every paired key, so only it
    /// is recreated. The input listener (admitted phone's key) and the Accessibility monitor are untouched,
    /// so a live session survives pairing another device or forgetting a different one.
    func pairingSetChanged() {
        guard let current = control else { return }
        current.cancel()
        ready.remove("tcp"); registered.remove("tcp")
        do {
            let keys = try store.all().map { (SymmetricKey(data: $0.ltk), $0.peerID.uuidString.lowercased()) }
            let replacement = try NWListener(using: TLSConfig.parameters(control: TLSConfig.listenerOptions(keys: keys)))
            control = replacement
            attach(replacement, kind: "tcp")
        } catch {
            control = nil
            status = "Discovery failed: \(error.localizedDescription)"
        }
    }

    func setInputIdentity(_ peerID: UUID?) {
        admittedInputPeer = peerID
        guard let current = input else { return }
        let port = current.port
        current.cancel()
        ready.remove("udp"); registered.remove("udp")
        do {
            let replacement = try makeInputListener(peerID: peerID, port: port)
            input = replacement
            attach(replacement, kind: "udp")
        } catch {
            input = nil
            status = "Input listener failed: \(error.localizedDescription)"
        }
    }

    /// Keeps the previous UDP port when possible so the advertised SRV record stays valid across
    /// the admission swap (the phone resolves `_trackglass._udp` right after WELCOME).
    private func makeInputListener(peerID: UUID?, port: NWEndpoint.Port?) throws -> NWListener {
        let keys: [(SymmetricKey, String)]
        if let peerID, let peer = try store.load(peerID: peerID) {
            keys = [(SymmetricKey(data: peer.ltk), peerID.uuidString.lowercased())]
        } else {
            keys = []
        }
        let parameters = TLSConfig.parameters(input: TLSConfig.listenerOptions(keys: keys))
        if let port, let reused = try? NWListener(using: parameters, on: port) { return reused }
        return try NWListener(using: parameters)
    }

    func stop(monitorPermission: Bool = true) {
        if monitorPermission { accessibilityPermission.stopMonitoring() }
        control?.cancel()
        input?.cancel()
        control = nil
        input = nil
        ready.removeAll()
        registered.removeAll()
        status = "Discovery stopped"
    }
}
