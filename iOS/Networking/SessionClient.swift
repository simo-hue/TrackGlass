import CryptoKit
import Foundation
import Network
import Observation
import TrackglassKit

// Sendable stated here (main-actor isolated, so it holds): ConnectionManager.swift's `ConnectionSession` refines
// Sendable, and a conformance made in another file may not add it retroactively.
@MainActor @Observable
final class SessionClient: Sendable {
    private(set) var isConnected = false
    private(set) var status = "No Mac connected"
    private(set) var macName = ""
    private(set) var rttMicros: UInt32 = 0
    private(set) var diagnostics: StatusMessage?
    private(set) var diagnosticsSequence: UInt64 = 0
    private(set) var settings: SettingsMessage?
    /// WELCOME `injectorMode` (§4.5): 1 Quartz, 2 driver (Phase 2). Mirrored into `ConnectionState` (§5.5).
    private(set) var injectorMode: UInt8 = 0
    /// The paired Mac this session is connected to (nil while disconnected).
    private(set) var connectedPeerID: UUID?
    private var connectionChanged: (@MainActor @Sendable () -> Void)?
    private var sessionClosed: (@MainActor @Sendable () -> Void)?
    #if canImport(UIKit)
    private let haptics = HapticEngine()
    #endif
    private var channel: ControlChannel?
    private var surface: SurfaceMessage?
    let inputSink: UDPFrameSink
    private var inputBrowser: NWBrowser?
    private var inputConnection: NWConnection?
    private var inputDeadline: Task<Void, Never>?
    /// The latest `_trackglass._udp` results with a TXT `id`, and whether a record with another instance name than the
    /// control service's may be used yet (see `inputEndpoint`).
    private var inputRecords: [InputRecord] = []
    private var inputAcceptsOtherNames = false
    private var inputNameGraceTask: Task<Void, Never>?
    /// How long the DTLS input path may take to come up before the session is ended (tests raise it).
    var inputPathTimeout: Duration = .seconds(5)
    /// The current session's input path reached `.ready`; stays set after it closes, until the next `connect`. The
    /// reconnect loop resets its backoff only after a session got this far (M1, 2026-10-31).
    private(set) var inputPathWasReady = false
    private var connectContinuation: CheckedContinuation<Bool, Never>?
    /// The last session ended with a final answer (unpaired, incompatible): retrying cannot succeed.
    private(set) var lastCloseWasFinal = false
    /// The user chose to reconnect after a final answer; the panel and the loop treat the Mac as reachable again.
    func clearFinalClose() { lastCloseWasFinal = false }

    init(inputSink: UDPFrameSink) { self.inputSink = inputSink }

    /// Everything the UI mirrors, read in one actor hop. `sequence` increases with every snapshot so a
    /// consumer can discard one that was taken earlier but delivered later (actor reentrancy).
    struct Snapshot: Sendable {
        let isConnected: Bool
        /// `var`: `ConnectionManager` may show a round's outcome instead of the last attempt's (M1, M2).
        var status: String
        let macName: String
        let rttMicros: UInt32
        let settings: SettingsMessage?
        let diagnostics: StatusMessage?
        let diagnosticsSequence: UInt64
        let sequence: UInt64
        var injectorMode: UInt8 = 0
        var connectedPeerID: UUID?
        var lastCloseWasFinal = false
        var inputPathWasReady = false
    }
    private var snapshotSequence: UInt64 = 0
    func snapshot() -> Snapshot {
        snapshotSequence &+= 1
        return Snapshot(isConnected: isConnected, status: status, macName: macName, rttMicros: rttMicros, settings: settings,
                        diagnostics: diagnostics, diagnosticsSequence: diagnosticsSequence, sequence: snapshotSequence,
                        injectorMode: injectorMode, connectedPeerID: connectedPeerID, lastCloseWasFinal: lastCloseWasFinal,
                        inputPathWasReady: inputPathWasReady)
    }

    func setCallbacks(connectionChanged: (@MainActor @Sendable () -> Void)?,
                      sessionClosed: (@MainActor @Sendable () -> Void)?) {
        self.connectionChanged = connectionChanged
        self.sessionClosed = sessionClosed
    }

    func setTrackingOverride(_ value: Float) { trackingOverride = value.isFinite ? min(1, max(-1, value)) : 0 }

    var trackingOverride: Float = 0 {
        didSet {
            guard trackingOverride != oldValue else { return }
            surface?.trackingOverride = trackingOverride
            if let surface, isConnected { channel?.send(.surface(surface)) }
        }
    }

    func connect(endpoint: NWEndpoint, mac: PairedPeer, hello: HelloMessage) async -> Bool {
        trackingOverride = hello.trackingOverride
        // Replacing a channel is not a lost session: the attempt it belonged to is answered `false` here, and its
        // `onClose` (which sees another current channel) stays quiet, so `sessionClosed` — the reconnect loop's
        // trigger — never fires for a channel this method retires itself.
        if let previous = channel {
            channel = nil
            if let continuation = connectContinuation { connectContinuation = nil; continuation.resume(returning: false) }
            previous.close("Replaced by a new connection")
        }
    #if canImport(UIKit)
        haptics.stop()
    #endif
        stopInput()
        isConnected = false; connectedPeerID = nil; rttMicros = 0; settings = nil; diagnostics = nil; lastCloseWasFinal = false
        inputPathWasReady = false
        status = "Connecting to \(mac.name)…"
        macName = mac.name
        let instanceName = Self.instanceName(of: endpoint)
        let options = TLSConfig.tlsOptions(psk: SymmetricKey(data: mac.ltk), identity: hello.peerID.uuidString.lowercased())
        let channel = ControlChannel(connection: NWConnection(to: endpoint, using: TLSConfig.parameters(control: options)))
        self.channel = channel
        channel.onReady = { [weak channel] in channel?.send(.hello(hello)) }
        channel.onMessage = { [weak self, weak channel] packet in
            guard let self, let channel, self.channel === channel else { return }
            switch packet.message {
            case .welcome(let welcome):
                guard welcome.macPeerID == mac.peerID else { channel.end(reason: 1, message: "Unexpected Mac identity"); return }
                switch welcome.status {
                case 0:
                    self.isConnected = true; self.connectedPeerID = mac.peerID; self.macName = welcome.macName
                    self.settings = welcome.settings; self.injectorMode = welcome.injectorMode
    #if canImport(UIKit)
                    self.haptics.start()
    #endif
                    self.status = "Connected to \(welcome.macName)"
                    channel.startHeartbeat()
                    self.startInput(mac: mac, phonePeerID: hello.peerID, instanceName: instanceName)
                    if let surface = self.surface { channel.send(.surface(surface)) }
                    self.connectionChanged?()
                    self.connectContinuation?.resume(returning: true)
                    self.connectContinuation = nil
                case 1:
                    // An empty name: busy with this very phone — the Mac has not released its previous, silent session
                    // yet (§3.5, released after 1.5 s). The retry joins; nothing for the user to do (§4.5, 2026-10-29).
                    channel.close(welcome.activePhoneName.isEmpty ? "Reconnecting to \(welcome.macName)…"
                                  : "\(welcome.macName) is being used by \(welcome.activePhoneName)")
                case 3: self.lastCloseWasFinal = true; channel.close(ControlCloseMessage.pairAgain)
                default: self.lastCloseWasFinal = true; channel.close(ControlCloseMessage.incompatible)
                }
            case .status(let status):
                self.diagnostics = status; self.diagnosticsSequence &+= 1; self.connectionChanged?()
            case .settings(let settings): self.settings = settings; self.connectionChanged?()
            case .haptic(let message):
                #if canImport(UIKit)
                if self.isConnected { self.haptics.play(message) }
                #else
                _ = message
                #endif
            default: break
            }
        }
        channel.onRTT = { [weak self] value in self?.rttMicros = value; self?.connectionChanged?() }
        channel.onClose = { [weak self, weak channel] message in
            guard let self, let channel, self.channel === channel else { return }
            self.lastCloseWasFinal = self.lastCloseWasFinal || channel.closedFinally
            self.isConnected = false; self.connectedPeerID = nil; self.status = message; self.channel = nil
            self.stopInput()
    #if canImport(UIKit)
            self.haptics.stop()
    #endif
            if let continuation = self.connectContinuation {
                continuation.resume(returning: false)
                self.connectContinuation = nil
            } else {
                self.sessionClosed?()
            }
            self.connectionChanged?()
        }
        connectionChanged?()
        return await withCheckedContinuation { continuation in
            connectContinuation = continuation
            channel.start()
        }
    }

    func updateSurface(_ value: SurfaceMessage) {
        var value = value
        value.trackingOverride = trackingOverride
        surface = value
        if isConnected { channel?.send(.surface(value)) }
    }

    func disconnect(reason: UInt8 = 0) {
        endLocally()
        channel?.end(reason: reason, message: Self.byeMessage(reason))
    }

    /// §5.9: the background BYE must leave the device before the app is suspended. Returns once the network stack
    /// has processed the BYE, or after `timeout` at the latest, so the caller can end its background task right then.
    func disconnectAndWait(reason: UInt8 = 0, timeout: Duration = .seconds(1)) async {
        endLocally()
        guard let channel else { return }
        let gate = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.continuation = continuation
            channel.end(reason: reason, message: Self.byeMessage(reason)) { gate.resume() }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                gate.resume()
            }
        }
    }

    #if canImport(UIKit)
    /// Starts the haptic engine ahead of the first Mac haptic (first finger down), off the main thread.
    func prewarmHaptics() { if isConnected { haptics.prewarm() } }
    #endif

    private func endLocally() {
        isConnected = false; connectedPeerID = nil
    #if canImport(UIKit)
        haptics.stop()
    #endif
        stopInput()
        connectionChanged?()
    }

    private static func byeMessage(_ reason: UInt8) -> String { reason == 4 ? "The Mac went to sleep" : "Disconnected" }

    /// A `_trackglass._udp` browse result reduced to what choosing the input service needs.
    struct InputRecord: Sendable {
        let endpoint: NWEndpoint
        let peerID: UUID
    }

    /// §5.5: the input service is the `_trackglass._udp` record with the control service's instance name and the
    /// Mac's `id`. A record that only claims the `id` is used once `acceptOtherNames` (after `inputNameGrace` without
    /// a same-name record: Bonjour renames each service type on its own when two Macs share a name). Names are not
    /// authenticated (the DTLS key is), but a decoy record can no longer be picked over the Mac's own (M2).
    /// Without an instance name (a host:port control endpoint) the `id` decides.
    nonisolated static func inputEndpoint(in records: [InputRecord], peerID: UUID, instanceName: String?,
                                          acceptOtherNames: Bool) -> NWEndpoint? {
        let mine = records.filter { $0.peerID == peerID }
        guard let instanceName else { return mine.first?.endpoint }
        if let same = mine.first(where: { Self.instanceName(of: $0.endpoint) == instanceName }) { return same.endpoint }
        return acceptOtherNames ? mine.first?.endpoint : nil
    }

    nonisolated static let inputNameGrace: Duration = .seconds(1)

    nonisolated static func instanceName(of endpoint: NWEndpoint) -> String? {
        guard case let .service(name, _, _, _) = endpoint else { return nil }
        return name
    }

    private func startInput(mac: PairedPeer, phonePeerID: UUID, instanceName: String?) {
        stopInput()
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        parameters.prohibitedInterfaceTypes = [.cellular]
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_trackglass._udp", domain: nil), using: parameters)
        inputBrowser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            let records = results.compactMap { result -> InputRecord? in
                guard case let .bonjour(txt) = result.metadata,
                      let idData = txt.getEntry(for: "id")?.data,
                      let idText = String(data: idData, encoding: .utf8),
                      let id = UUID(uuidString: idText) else { return nil }
                return InputRecord(endpoint: result.endpoint, peerID: id)
            }
            Task { @MainActor in
                guard let self, let browser, self.inputBrowser === browser else { return }
                self.inputRecords = records
                self.connectInput(mac: mac, phonePeerID: phonePeerID, instanceName: instanceName)
            }
        }
        browser.start(queue: .main)
        armInputDeadline("Mac input service not found")
        guard instanceName != nil else { return }
        inputNameGraceTask = Task { [weak self, weak browser] in
            do { try await Task.sleep(for: Self.inputNameGrace) } catch { return }
            guard let self, let browser, self.inputBrowser === browser else { return }
            self.inputAcceptsOtherNames = true
            self.connectInput(mac: mac, phonePeerID: phonePeerID, instanceName: instanceName)
        }
    }

    /// Opens the DTLS input path to the record `inputEndpoint` picks, once there is one.
    private func connectInput(mac: PairedPeer, phonePeerID: UUID, instanceName: String?) {
        guard inputConnection == nil, let browser = inputBrowser,
              let endpoint = Self.inputEndpoint(in: inputRecords, peerID: mac.peerID, instanceName: instanceName,
                                                acceptOtherNames: inputAcceptsOtherNames) else { return }
        let tls = TLSConfig.tlsOptions(psk: SymmetricKey(data: mac.ltk), identity: phonePeerID.uuidString.lowercased())
        let connection = NWConnection(to: endpoint, using: TLSConfig.parameters(input: tls))
        inputConnection = connection
        browser.cancel()
        inputBrowser = nil
        inputNameGraceTask?.cancel(); inputNameGraceTask = nil
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection, self.inputConnection === connection else { return }
                switch state {
                case .ready:
                    self.inputPathWasReady = true
                    self.inputSink.setConnection(connection)
                    self.inputDeadline?.cancel(); self.inputDeadline = nil
                case .failed:
                    // A session without an input path is useless: end it so the reconnect loop
                    // re-establishes both channels instead of showing "Connected" with no frames.
                    self.failInput("Input connection failed")
                case .waiting:
                    self.armInputDeadline("Input connection stalled")
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    /// Gives the DTLS path `inputPathTimeout` (service resolution, handshake retries) before the session is torn down.
    private func armInputDeadline(_ message: String) {
        inputDeadline?.cancel()
        inputDeadline = Task { [weak self] in
            guard let timeout = self?.inputPathTimeout else { return }
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.failInput(message)
        }
    }

    private func failInput(_ message: String) {
        stopInput()
        channel?.close(message)
    }

    private func stopInput() {
        inputDeadline?.cancel()
        inputDeadline = nil
        inputNameGraceTask?.cancel()
        inputNameGraceTask = nil
        inputBrowser?.cancel()
        inputBrowser = nil
        inputRecords = []
        inputAcceptsOtherNames = false
        inputSink.setConnection(nil)
        inputConnection?.cancel()
        inputConnection = nil
    }
}

/// Resumes a continuation exactly once, whichever of its callers (BYE sent, timeout) comes first.
@MainActor
private final class ResumeOnce {
    var continuation: CheckedContinuation<Void, Never>?
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
