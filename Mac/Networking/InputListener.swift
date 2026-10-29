import Foundation
import Network
import OSLog
import TrackglassKit
import TrackglassEngine

/// STATUS `lossPermille` bookkeeping (§4.5, §4.7): gaps in the frame sequence count as missing, but a late
/// datagram (UDP reordering) fills the gap it was counted in instead of counting twice.
struct FrameLossCounter: Sendable {
    private(set) var lastSequence: UInt32?
    private(set) var received = 0
    private(set) var missing = 0
    /// Newest sequence when the current window started: only gaps above it were counted in this window.
    private var windowStart: UInt32?

    mutating func record(_ sequence: UInt32) {
        received += 1
        guard let last = lastSequence else { lastSequence = sequence; return }
        if let gap = MessageHeader.gap(from: last, to: sequence) {
            missing += gap
            lastSequence = sequence
        } else if sequence != last, missing > 0,
                  windowStart.map({ MessageHeader.sequence(sequence, isNewerThan: $0) }) ?? true {
            missing -= 1   // older than the newest frame: it arrived late, it was not lost (counted in this window)
        }
    }

    /// Per-second window: the counts restart, the sequence position is kept.
    mutating func resetCounts() { received = 0; missing = 0; windowStart = lastSequence }
    mutating func reset() { self = FrameLossCounter() }

    var lossPermille: Int {
        let expected = received + missing
        return expected == 0 ? 0 : missing * 1_000 / expected
    }
}

/// Re-arms `receiveMessage` with one closure built per flow, not a new escaping closure per datagram (§7).
private final class FlowReceiver: @unchecked Sendable {
    var handler: (@Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void)?
}

/// All receive and counter state is confined to the input queue.
final class InputListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "input-pipeline", qos: .userInteractive)
    private let logger = Logger(subsystem: "app.trackglass.mac", category: "net")
    /// Fires on the input queue whenever a pipeline starts or stops recording (including when it is torn down).
    var onRecordingChanged: (@Sendable (Bool) -> Void)?
    private var admittedPeerID: UUID?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var receivers: [ObjectIdentifier: FlowReceiver] = [:]
    /// Uptime each flow was accepted and the flows whose DTLS handshake completed. Every UDP source becomes a flow,
    /// so unauthenticated ones are bounded: at most `maximumFlows`, none older than `handshakeTimeoutNs` unless ready.
    private var flowStarted: [ObjectIdentifier: UInt64] = [:]
    private var readyFlows = Set<ObjectIdentifier>()
    static let maximumFlows = 4
    static let handshakeTimeoutNs: UInt64 = 5_000_000_000
    /// Open flows (tests).
    var flowCount: Int { queue.sync { connections.count } }
    private var loss = FrameLossCounter()
    private var didLogReady = false
    private var pipeline: InputPipeline?
    /// Held while a phone is admitted: a menu-bar agent with no visible window is otherwise eligible for App Nap,
    /// which coalesces the pipeline's 8 ms timer and lowers its priority (§2.4, §7).
    private var activity: NSObjectProtocol?
    /// Runs only while a phone is admitted (flows are only accepted then), so an idle Mac has no 1 s wake-up.
    private let statsTimer: DispatchSourceTimer
    private var statsTimerRunning = false

    private let onStatus: @Sendable (UUID, StatusMessage) -> Void
    private let onHaptic: @Sendable (UUID, HapticKind) -> Void
    /// Fires once per admission, on the input queue, when `InputPipeline.inputPathIsDead` turns true.
    private let onInputPathDead: @Sendable (UUID) -> Void
    private var inputPathDeadReported = false
    init(onHaptic: @escaping @Sendable (UUID, HapticKind) -> Void = { _, _ in },
         onStatus: @escaping @Sendable (UUID, StatusMessage) -> Void = { _, _ in },
         onInputPathDead: @escaping @Sendable (UUID) -> Void = { _ in }) {
        self.onStatus = onStatus
        self.onHaptic = onHaptic
        self.onInputPathDead = onInputPathDead
        statsTimer = DispatchSource.makeTimerSource(queue: queue)
        statsTimer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        statsTimer.setEventHandler { [weak self] in self?.logStats() }
        // Created suspended; `setAdmittedPeer` resumes it. A suspended source must be resumed before release.
    }

    deinit {
        if !statsTimerRunning { statsTimer.resume() }
        statsTimer.cancel()
    }

    private func setStatsTimerRunning(_ running: Bool) {
        guard running != statsTimerRunning else { return }
        statsTimerRunning = running
        if running {
            statsTimer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
            statsTimer.resume()
        } else {
            statsTimer.suspend()
        }
    }

    func setAdmittedPeer(_ peerID: UUID?, geometry: EngineGeometry? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.admittedPeerID = peerID
            self.didLogReady = false
            self.inputPathDeadReported = false
            self.loss.reset()
            self.pipeline?.stop()
            self.pipeline = nil
            if let activity = self.activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
            if let peerID, let geometry {
                let pipeline = InputPipeline(queue: self.queue, geometry: geometry)
                pipeline.onHaptic = { [onHaptic = self.onHaptic] kind in onHaptic(peerID, kind) }
                pipeline.onRecordingChanged = { [weak self] recording in self?.onRecordingChanged?(recording) }
                self.pipeline = pipeline
                self.activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                    reason: "Trackglass is turning a phone's touches into trackpad input")
            }
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll(); self.flowStarted.removeAll(); self.readyFlows.removeAll(); self.receivers.removeAll()
            self.setStatsTimerRunning(peerID != nil)
        }
    }

    /// Quitting (§6.1): the pipeline stops now, on its queue — every held button is released, a recording is
    /// finished, pending Dock ends are posted — before the process exits.
    func shutdown() {
        queue.sync {
            admittedPeerID = nil
            pipeline?.stop()
            pipeline = nil
            if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
            for connection in connections.values { connection.cancel() }
            connections.removeAll(); flowStarted.removeAll(); readyFlows.removeAll(); receivers.removeAll()
            setStatsTimerRunning(false)
        }
    }

    func accept(_ connection: NWConnection) {
        queue.async { [weak self] in
            guard let self, self.admittedPeerID != nil else { connection.cancel(); return }
            if self.connections.count >= Self.maximumFlows { self.evictOneFlow() }
            let id = ObjectIdentifier(connection)
            self.connections[id] = connection
            self.flowStarted[id] = DispatchTime.now().uptimeNanoseconds
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, let current = self.connections[id] else { return }
                switch state {
                case .ready: self.readyFlows.insert(id)
                case .failed: current.cancel(); self.forgetFlow(id)
                case .cancelled: self.forgetFlow(id)
                default: break
                }
            }
            connection.start(queue: self.queue)
            self.receive(on: connection, id: id)
        }
    }

    private func receive(on connection: NWConnection, id: ObjectIdentifier) {
        let receiver = FlowReceiver()
        receiver.handler = { [weak self, weak connection, weak receiver] data, _, _, error in
            guard let self, let connection, self.connections[id] === connection else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if error == nil, let handler = receiver?.handler { connection.receiveMessage(completion: handler) }
            else { connection.cancel(); self.forgetFlow(id) }
        }
        receivers[id] = receiver
        if let handler = receiver.handler { connection.receiveMessage(completion: handler) }
    }

    private func forgetFlow(_ id: ObjectIdentifier) {
        connections.removeValue(forKey: id); flowStarted.removeValue(forKey: id); readyFlows.remove(id)
        receivers.removeValue(forKey: id)
    }

    /// Makes room for a new flow: the oldest one still handshaking goes first, else the oldest of all (a phone
    /// that rebuilt its input connection leaves its previous, now silent, flow behind).
    private func evictOneFlow() {
        var victim: ObjectIdentifier?
        var victimStarted = UInt64.max
        var victimReady = true
        for (id, started) in flowStarted {
            let ready = readyFlows.contains(id)
            if (victimReady && !ready) || (ready == victimReady && started < victimStarted) {
                victim = id; victimStarted = started; victimReady = ready
            }
        }
        guard let victim else { return }
        connections[victim]?.cancel()
        forgetFlow(victim)
    }

    /// Cancels flows whose DTLS handshake has not completed within `handshakeTimeoutNs` (called once a second).
    func expireStalledHandshakes(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        dispatchPrecondition(condition: .onQueue(queue))
        for (id, started) in flowStarted where !readyFlows.contains(id) && now >= started && now - started >= Self.handshakeTimeoutNs {
            connections[id]?.cancel()
            forgetFlow(id)
        }
    }

    private func consume(_ data: Data) {
        do {
            let header = try data.withUnsafeBytes { try MessageHeader.decode($0) }
            switch MessageType(rawValue: header.type) {
            case .inputHeartbeat:   // §4.1: bytes a newer phone appends are ignored
                if !didLogReady {
                    didLogReady = true
                    logger.info("input ready")
                }
                pipeline?.heartbeat(sequence: header.sequence)
            case .touchFrame:
                loss.record(header.sequence)
                pipeline?.consume(data)
            default:
                break
            }
        } catch {
            // Invalid and unauthenticated datagrams are ignored without logging payloads.
        }
    }

    private func logStats() {
        expireStalledHandshakes()
        guard let peerID = admittedPeerID else { return }
        pipeline?.idleCheck()   // §6.3: 3 s without datagrams → engine reset, state reported idle
        if let pipeline, !inputPathDeadReported, pipeline.inputPathIsDead() {
            inputPathDeadReported = true
            logger.error("input path silent; ending the session so the phone rebuilds it")
            onInputPathDead(peerID)
        }
        let lossPermille = loss.lossPermille
        let framesPerSecond = loss.received
        let p50 = pipeline?.latency.p50Micros ?? 0
        let p95 = pipeline?.latency.p95Micros ?? 0
        logger.info("framesPerSecond=\(framesPerSecond) lossPermille=\(lossPermille) pipelineP50us=\(p50) pipelineP95us=\(p95)")
        onStatus(peerID, StatusMessage(lossPermille: UInt16(clamping: lossPermille), rttMicros: 0,
            framesPerSecond: UInt16(clamping: framesPerSecond), pipelineP50Micros: p50, pipelineP95Micros: p95,
            engineState: pipeline?.diagnosticEngineState ?? 0))
        loss.resetCounts()
    }

    func updateGeometry(_ geometry: EngineGeometry) {
        queue.async { [weak self] in self?.pipeline?.setGeometry(geometry) }
    }

    func updateSettings(_ settings: TrackpadSettings) {
        queue.async { [weak self] in self?.pipeline?.setSettings(settings) }
    }

    func displayDidSleep() { queue.async { [weak self] in self?.pipeline?.displayDidSleep() } }

    func startRecording() { queue.async { [weak self] in self?.pipeline?.startRecording() } }
    func stopRecording() { queue.async { [weak self] in self?.pipeline?.stopRecording() } }
}
