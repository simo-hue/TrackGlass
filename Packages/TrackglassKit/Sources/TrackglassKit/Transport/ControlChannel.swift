import Foundation
import Network
import OSLog

/// User-facing close messages shared by both apps.
public enum ControlCloseMessage {
    public static let pairAgain = "Pair again"
    public static let incompatible = "Incompatible version"
    /// BYE reason 5: the Mac's user disconnected this phone; it does not reconnect by itself (2026-10-29).
    public static let disconnectedOnMac = "Disconnected on the Mac"
}

/// Low-rate control traffic only; touch datagrams never enter this channel.
@MainActor
public final class ControlChannel {
    public let connection: NWConnection
    public var onReady: (() -> Void)?
    public var onMessage: ((ControlPacket) async -> Void)?
    public var onClose: ((String) -> Void)?
    public var onRTT: ((UInt32) -> Void)?
    private var sequence: UInt32 = 0
    private var nonce: UInt32 = 0
    private var pending: [UInt32: UInt64] = [:]
    private var timer: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    /// A connection that never becomes ready or never completes HELLO/WELCOME (i.e. `startHeartbeat()`
    /// is never called) is closed after this long; before the heartbeat there is no other liveness check.
    public var handshakeTimeout: Duration = .seconds(10)
    /// PING cadence (Appendix A: 1 s). Tests shorten it; the dead threshold is always three missed pings,
    /// i.e. the oldest of three *consecutive* unanswered pings is ≥ 3 × this interval old (§4.6).
    public var heartbeatInterval: Duration = .seconds(1)
    /// `MonotonicClock.nanoseconds()` time of the last message received (or of `start()`); local only, never sent.
    /// Both sides PING every second, so a live peer is never silent for much longer than that.
    public private(set) var lastReceivedAt: UInt64 = MonotonicClock.nanoseconds()
    /// True when the peer said retrying cannot help: BYE `unpaired`, `incompatible` or `disconnected on the Mac` (§4.5), or a message this
    /// side could not understand. A failed TLS handshake is not final: the Mac also aborts handshakes while it
    /// goes to sleep or restarts its listener, which a reconnect must survive.
    public private(set) var closedFinally = false
    private var closed = false
    private var closing = false
    private var unknownTypes: Set<UInt8> = []
    private let logger = Logger(subsystem: "app.trackglass", category: "Control")

    public init(connection: NWConnection) { self.connection = connection }

    deinit { connection.cancel() }

    public func start() {
        lastReceivedAt = MonotonicClock.nanoseconds()
        watchdog = Task { [weak self] in
            guard let timeout = self?.handshakeTimeout else { return }
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.close("Connection timed out")
        }
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                switch state {
                case .ready: self.onReady?(); self.receive()
                case .failed(let error), .waiting(let error):
                    // A refused key is "Pair again" (§3.2); a handshake the peer merely closed or aborted
                    // (errSSLClosedGraceful −9805, errSSLClosedAbort −9806, errSSLClosedNoNotify −9816: a Mac going
                    // to sleep or restarting its listener) is a lost connection that a reconnect survives.
                    if case let .tls(status) = error, ![-9805, -9806, -9816].contains(status) {
                        self.close(ControlCloseMessage.pairAgain)
                    } else { self.close("Connection lost") }
                case .cancelled: self.close("Disconnected")
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    /// Headers carry the wire clock (§4.2, §5.10); PING times and the RTT use it too, so the echo compares alike.
    public func send(_ message: ControlMessage) {
        transmit(message, sentAt: MonotonicClock.wireNanoseconds())
    }

    private func transmit(_ message: ControlMessage, sentAt: UInt64, terminal: String? = nil,
                          sent: (@MainActor @Sendable () -> Void)? = nil) {
        guard !closed, !closing else { sent?(); return }
        do {
            let data = try message.encode(sequence: sequence, sentAt: sentAt)
            sequence &+= 1
            if terminal != nil { closing = true; timer?.cancel() }
            let context = NWConnection.ContentContext(identifier: "control", metadata: [
                NWProtocolFramer.Message(definition: TGControlFramer.definition)
            ])
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    defer { sent?() }
                    guard let self else { return }
                    if let terminal { self.close(terminal) }
                    else if error != nil { self.close("Connection lost") }
                }
            })
        } catch { close("Invalid control message"); sent?() }
    }

    /// §4.5 BYE reasons: 0 user, 1 incompatible, 2 busy, 3 unpaired, 4 sleeping, 5 disconnected on the Mac.
    static func message(forBye reason: UInt8) -> String {
        switch reason {
        case 1: return ControlCloseMessage.incompatible
        case 2: return "The Mac is busy"
        case 3: return ControlCloseMessage.pairAgain
        case 4: return "The Mac went to sleep"
        case 5: return ControlCloseMessage.disconnectedOnMac
        default: return "Disconnected"
        }
    }

    public func end(reason: UInt8 = 0, message: String = "Disconnected") {
        transmit(.bye(ByeMessage(reason: reason)), sentAt: MonotonicClock.wireNanoseconds(), terminal: message)
    }

    /// `end(reason:message:)` that calls `sent` once the BYE has been processed by the network stack — or right away
    /// when it cannot be sent (channel already closing) — so a caller can end a background task after it.
    public func end(reason: UInt8 = 0, message: String = "Disconnected", sent: @escaping @MainActor @Sendable () -> Void) {
        transmit(.bye(ByeMessage(reason: reason)), sentAt: MonotonicClock.wireNanoseconds(), terminal: message, sent: sent)
    }

    public func startHeartbeat() {
        guard timer == nil, !closed else { return }
        watchdog?.cancel(); watchdog = nil
        let interval = heartbeatInterval
        let deadAfterNs = Self.nanoseconds(of: interval) &* 3
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, !self.closed, !self.closing else { return }
                let now = MonotonicClock.wireNanoseconds()
                self.nonce &+= 1
                self.pending[self.nonce] = now
                self.transmit(.ping(PingMessage(nonce: self.nonce)), sentAt: now)
                // Appendix A: three misses. `pending` holds only the *consecutive* unanswered pings (a PONG
                // clears every older one, see `receive`), so three entries with the oldest ≥ 3 intervals old
                // means the last three pings in a row went unanswered.
                if self.pending.count >= 3 && self.pending.values.contains(where: { now >= $0 && now - $0 >= deadAfterNs }) {
                    self.close("Connection timed out"); return
                }
            }
        }
    }

    private static func nanoseconds(of duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        return UInt64(max(0, seconds)) &* 1_000_000_000 &+ UInt64(max(0, attoseconds)) / 1_000_000_000
    }

    private func receive() {
        guard !closed, !closing else { return }
        connection.receiveMessage { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed, !self.closing else { return }
                guard error == nil, complete, let data else { self.close("Connection lost"); return }
                self.lastReceivedAt = MonotonicClock.nanoseconds()
                do {
                    let packet = try ControlMessage.decode(data)
                    switch packet.message {
                    case .ping(let ping):
                        self.send(.pong(PongMessage(nonce: ping.nonce, echoSentAt: packet.header.sentAt)))
                    case .pong(let pong):
                        if self.pending[pong.nonce] == pong.echoSentAt {
                            // A PONG proves the peer is alive: it clears its own ping and every older one
                            // still pending, so misses are counted consecutively (§4.6 "3 missed = dead").
                            let answered = pong.nonce
                            self.pending = self.pending.filter { answered &- $0.key >= 0x8000_0000 }
                            let now = MonotonicClock.wireNanoseconds()   // the PING's `sentAt` domain
                            if now >= pong.echoSentAt { self.onRTT?(UInt32(clamping: (now - pong.echoSentAt) / 1_000)) }
                        }
                    case .bye(let bye):
                        self.closedFinally = bye.reason == 1 || bye.reason == 3 || bye.reason == 5
                        self.close(Self.message(forBye: bye.reason))
                        return
                    case .unknown(let type):
                        if self.unknownTypes.insert(type).inserted { self.logger.info("Unknown control type \(type)") }
                    default: await self.onMessage?(packet)
                    }
                    self.receive()
                } catch ProtocolError.incompatibleVersion {
                    self.closedFinally = true
                    self.end(reason: 1, message: ControlCloseMessage.incompatible)
                } catch {
                    self.closedFinally = true
                    // A message this version cannot parse at all (appended fields are already ignored, §4.1): tell
                    // the peer why before closing, so it shows "Incompatible version" instead of "Connection lost".
                    self.end(reason: 1, message: "Invalid control message")
                }
            }
        }
    }

    public func close(_ message: String = "Disconnected") {
        guard !closed else { return }
        closed = true
        timer?.cancel(); timer = nil
        watchdog?.cancel(); watchdog = nil
        pending.removeAll()
        connection.stateUpdateHandler = nil
        connection.cancel()
        let callback = onClose
        onReady = nil; onMessage = nil; onClose = nil; onRTT = nil
        callback?(message)
    }
}
