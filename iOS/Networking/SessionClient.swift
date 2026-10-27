import CryptoKit
import Foundation
import Network
import Observation
import TrackglassKit

@MainActor @Observable
final class SessionClient {
    private(set) var isConnected = false
    private(set) var status = "No Mac connected"
    private(set) var macName = ""
    private(set) var rttMicros: UInt32 = 0
    private(set) var diagnostics: StatusMessage?
    private(set) var diagnosticsSequence: UInt64 = 0
    private(set) var settings: SettingsMessage?
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
    /// How long the DTLS input path may take to come up before the session is ended (tests raise it).
    var inputPathTimeout: Duration = .seconds(5)
    private var connectContinuation: CheckedContinuation<Bool, Never>?

    init(inputSink: UDPFrameSink) { self.inputSink = inputSink }

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
        channel?.close()
    #if canImport(UIKit)
        haptics.stop()
    #endif
        stopInput()
        isConnected = false; rttMicros = 0; settings = nil; diagnostics = nil
        status = "Connecting to \(mac.name)…"
        macName = mac.name
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
                    self.isConnected = true; self.macName = welcome.macName
                    self.settings = welcome.settings
    #if canImport(UIKit)
                    self.haptics.start()
    #endif
                    self.status = "Connected to \(welcome.macName)"
                    channel.startHeartbeat()
                    self.startInput(mac: mac, phonePeerID: hello.peerID)
                    if let surface = self.surface { channel.send(.surface(surface)) }
                    self.connectionChanged?()
                    self.connectContinuation?.resume(returning: true)
                    self.connectContinuation = nil
                case 1:
                    channel.close("\(welcome.macName) is being used by \(welcome.activePhoneName)")
                case 3: channel.close("Pair again")
                default: channel.close("Incompatible version")
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
            guard let self, self.channel === channel else { return }
            self.isConnected = false; self.status = message; self.channel = nil
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
        isConnected = false
    #if canImport(UIKit)
        haptics.stop()
    #endif
        stopInput()
        connectionChanged?()
        channel?.end(reason: reason, message: reason == 4 ? "Mac sleeping" : "Disconnected")
    }

    private func startInput(mac: PairedPeer, phonePeerID: UUID) {
        stopInput()
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        parameters.prohibitedInterfaceTypes = [.cellular]
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_trackglass._udp", domain: nil), using: parameters)
        inputBrowser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            Task { @MainActor in
                guard let self, let browser, self.inputBrowser === browser,
                      self.inputConnection == nil else { return }
                for result in results {
                    guard case let .bonjour(txt) = result.metadata,
                          let idData = txt.getEntry(for: "id")?.data,
                          let idText = String(data: idData, encoding: .utf8),
                          UUID(uuidString: idText) == mac.peerID else { continue }
                    let tls = TLSConfig.tlsOptions(psk: SymmetricKey(data: mac.ltk), identity: phonePeerID.uuidString.lowercased())
                    let connection = NWConnection(to: result.endpoint, using: TLSConfig.parameters(input: tls))
                    self.inputConnection = connection
                    browser.cancel()
                    self.inputBrowser = nil
                    connection.stateUpdateHandler = { [weak self, weak connection] state in
                        Task { @MainActor in
                            guard let self, let connection, self.inputConnection === connection else { return }
                            switch state {
                            case .ready:
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
                    return
                }
            }
        }
        browser.start(queue: .main)
        armInputDeadline("Mac input service not found")
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
        inputDeadline?.cancel(); inputDeadline = nil
        inputSink.setConnection(nil)
        inputConnection?.cancel(); inputConnection = nil
        inputBrowser?.cancel(); inputBrowser = nil
        channel?.close(message)
    }

    private func stopInput() {
        inputDeadline?.cancel()
        inputDeadline = nil
        inputBrowser?.cancel()
        inputBrowser = nil
        inputSink.setConnection(nil)
        inputConnection?.cancel()
        inputConnection = nil
    }
}
