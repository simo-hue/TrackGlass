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
    private(set) var admittedInputPeer: UUID?
    private var ready = Set<String>()
    private var registered = Set<String>()
    /// Consecutive listener failures; drives the restart backoff (1, 2, 4 … 30 s) and resets once a listener is ready.
    private var restartAttempts = 0
    /// True between a start and `stop()`: retries after failures only rebuild listeners the app still wants
    /// (not while the Mac is going to sleep or Accessibility was revoked).
    private var wantsListeners = false
    private var creationRetryPending = false
    private let logger = Logger(subsystem: "app.trackglass.mac", category: "net")

    init(defaults: UserDefaults = .standard, store: PairingStore = PairingStore()) {
        self.store = store
        name = Host.current().localizedName ?? "Mac"
        // L7: a new peerID when the stored one was made on other hardware (Migration Assistant copies UserDefaults).
        peerID = MacIdentity.resolve(defaults: defaults, store: store)
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

    /// `promptForAccessibility`: only the launch shows the system's Accessibility prompt (§6.2); wake and
    /// fast-user-switch restarts check silently, so an untrusted app does not re-raise it every time.
    func start(promptForAccessibility: Bool = true) {
        guard control == nil else { return }
        accessibilityPermission.requestAndMonitor(prompt: promptForAccessibility)
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
        wantsListeners = true
        do {
            let tcp = try makeControlListener(port: nil)
            let previousInput = input
            previousInput?.cancel()   // never two `_trackglass._udp` listeners
            input = nil
            ready.remove("udp"); registered.remove("udp")
            let udp = try makeInputListener(peerID: admittedInputPeer, port: previousInput?.port)
            control = tcp
            input = udp
            attach(tcp, kind: "tcp")
            attach(udp, kind: "udp")
        } catch {
            status = "Discovery failed: \(error.localizedDescription)"
            scheduleCreationRetry()
        }
    }

    /// Every paired phone's key on one TLS listener (§3.3).
    private func makeControlListener(port: NWEndpoint.Port?) throws -> NWListener {
        let keys = try store.all().map { (SymmetricKey(data: $0.ltk), $0.peerID.uuidString.lowercased()) }
        let parameters = TLSConfig.parameters(control: TLSConfig.listenerOptions(keys: keys))
        if let port, let reused = try? NWListener(using: parameters, on: port) { return reused }
        return try NWListener(using: parameters)
    }

    /// A listener could not even be created (a Keychain error, a port problem): try again with the same backoff as
    /// a failed listener, rebuilding only what is missing, instead of leaving the Mac unreachable until relaunch.
    private func scheduleCreationRetry() {
        guard !creationRetryPending else { return }
        creationRetryPending = true
        let delay = min(30, 1 << min(restartAttempts, 5))
        restartAttempts += 1
        logger.error("listener creation failed; retrying in \(delay) s")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.creationRetryPending = false
            guard self.wantsListeners, self.accessibilityPermission.isTrusted else { return }
            if self.control == nil && self.input == nil { self.startListeners(); return }
            do {
                if self.control == nil {
                    let tcp = try self.makeControlListener(port: nil)
                    self.control = tcp; self.attach(tcp, kind: "tcp")
                }
                if self.input == nil {
                    let udp = try self.makeInputListener(peerID: self.admittedInputPeer, port: nil)
                    self.input = udp; self.attach(udp, kind: "udp")
                }
            } catch {
                self.status = "Discovery failed: \(error.localizedDescription)"
                self.scheduleCreationRetry()
            }
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
            restartAttempts = 0
            if kind == "udp", let port = input?.port?.rawValue {
                logger.info("input listener ready udpPort=\(port)")
            }
            refreshStatus()
        case .waiting(let error):
            ready.remove(kind)
            status = LocalNetworkPermission.message(for: error, failed: false)
            LocalNetworkPermission.shared.report(error)
        case .failed(let error):
            ready.remove(kind); registered.remove(kind)
            status = LocalNetworkPermission.message(for: error, failed: true)
            LocalNetworkPermission.shared.report(error)
            scheduleRestart(kind)
        default: break
        }
    }

    /// A failed listener is terminal (e.g. mDNSResponder restarted under it): rebuild it with backoff instead of
    /// leaving the Mac unreachable until sleep/wake or a relaunch.
    private func scheduleRestart(_ kind: String) {
        let failed = kind == "tcp" ? control : input
        let delay = min(30, 1 << min(restartAttempts, 5))
        restartAttempts += 1
        logger.error("\(kind, privacy: .public) listener failed; restarting in \(delay) s")
        Task { @MainActor [weak self, weak failed] in
            try? await Task.sleep(for: .seconds(delay))
            // Only the listener that failed is rebuilt: a stop(), a pairing change or a new admission may have
            // replaced it meanwhile.
            guard let self, let failed, self.accessibilityPermission.isTrusted else { return }
            if kind == "tcp", self.control === failed { self.pairingSetChanged() }
            else if kind == "udp", self.input === failed { self.setInputIdentity(self.admittedInputPeer) }
        }
    }

    func registrationChanged(_ change: NWListener.ServiceRegistrationChange, kind: String) {
        switch change {
        case .add: registered.insert(kind); LocalNetworkPermission.shared.reportRegistered()
        case .remove: registered.remove(kind)
        @unknown default: break
        }
        refreshStatus()
    }

    private func refreshStatus() {
        if ready.count == 2 && registered.count == 2 {
            status = "Advertising as \(name)"
        } else if LocalNetworkPermission.shared.isDenied {
            status = "Local Network access is off for Trackglass for Mac. Turn it on in System Settings → Privacy & Security → Local Network."
        } else {
            status = "Waiting for Bonjour. Check Local Network permission."
        }
    }

    /// The paired-key set changed: only the control (TLS) listener carries every paired key, so only it
    /// is recreated. The input listener (admitted phone's key) and the Accessibility monitor are untouched,
    /// so a live session survives pairing another device or forgetting a different one.
    func pairingSetChanged() {
        guard let current = control else { return }
        let port = current.port
        current.cancel()
        ready.remove("tcp"); registered.remove("tcp")
        do {
            // Same port when possible: a phone that just paired may connect through the SRV record it cached.
            let replacement = try makeControlListener(port: port)
            control = replacement
            attach(replacement, kind: "tcp")
        } catch {
            control = nil
            status = "Discovery failed: \(error.localizedDescription)"
            scheduleCreationRetry()
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
            scheduleCreationRetry()
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
        wantsListeners = false
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
