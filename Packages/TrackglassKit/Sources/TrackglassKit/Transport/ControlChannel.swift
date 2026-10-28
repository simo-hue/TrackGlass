import Foundation
import Network
import OSLog

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
    private var closed = false
    private var closing = false
    private var unknownTypes: Set<UInt8> = []
    private let logger = Logger(subsystem: "app.trackglass", category: "Control")

    public init(connection: NWConnection) { self.connection = connection }

    deinit { connection.cancel() }

    public func start() {
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
                    if case .tls = error { self.close("Pair again") }
                    else { self.close("Connection lost") }
                case .cancelled: self.close("Disconnected")
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    public func send(_ message: ControlMessage) {
        transmit(message, sentAt: MonotonicClock.nanoseconds())
    }

    private func transmit(_ message: ControlMessage, sentAt: UInt64, terminal: String? = nil) {
        guard !closed, !closing else { return }
        do {
            let data = try message.encode(sequence: sequence, sentAt: sentAt)
            sequence &+= 1
            if terminal != nil { closing = true; timer?.cancel() }
            let context = NWConnection.ContentContext(identifier: "control", metadata: [
                NWProtocolFramer.Message(definition: TGControlFramer.definition)
            ])
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    if let terminal { self.close(terminal) }
                    else if error != nil { self.close("Connection lost") }
                }
            })
        } catch { close("Invalid control message") }
    }

    public func end(reason: UInt8 = 0, message: String = "Disconnected") {
        transmit(.bye(ByeMessage(reason: reason)), sentAt: MonotonicClock.nanoseconds(), terminal: message)
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
                let now = MonotonicClock.nanoseconds()
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
                            let now = MonotonicClock.nanoseconds()
                            if now >= pong.echoSentAt { self.onRTT?(UInt32(clamping: (now - pong.echoSentAt) / 1_000)) }
                        }
                    case .bye(let bye):
                        self.close(bye.reason == 3 ? "Pair again" : bye.reason == 1 ? "Incompatible version" : "Disconnected")
                        return
                    case .unknown(let type):
                        if self.unknownTypes.insert(type).inserted { self.logger.info("Unknown control type \(type)") }
                    default: await self.onMessage?(packet)
                    }
                    self.receive()
                } catch ProtocolError.incompatibleVersion {
                    self.end(reason: 1, message: "Incompatible version")
                } catch { self.close("Invalid control message") }
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
