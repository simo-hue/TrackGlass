import Foundation
import Network
import OSLog
import TrackglassKit
import TrackglassEngine

/// All receive and counter state is confined to the input queue.
final class InputListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "input-pipeline", qos: .userInteractive)
    private let logger = Logger(subsystem: "app.trackglass.mac", category: "Input")
    private var admittedPeerID: UUID?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var lastSequence: UInt32?
    private var receivedFrames = 0
    private var missingFrames = 0
    private var didLogReady = false
    private var pipeline: InputPipeline?
    private let statsTimer: DispatchSourceTimer

    private let onStatus: @Sendable (UUID, StatusMessage) -> Void
    private let onHaptic: @Sendable (UUID, HapticKind) -> Void
    init(onHaptic: @escaping @Sendable (UUID, HapticKind) -> Void = { _, _ in },
         onStatus: @escaping @Sendable (UUID, StatusMessage) -> Void = { _, _ in }) {
        self.onStatus = onStatus
        self.onHaptic = onHaptic
        statsTimer = DispatchSource.makeTimerSource(queue: queue)
        statsTimer.schedule(deadline: .now() + 1, repeating: 1)
        statsTimer.setEventHandler { [weak self] in self?.logStats() }
        statsTimer.resume()
    }

    func setAdmittedPeer(_ peerID: UUID?, geometry: EngineGeometry? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.admittedPeerID = peerID
            self.didLogReady = false
            self.lastSequence = nil
            self.receivedFrames = 0
            self.missingFrames = 0
            self.pipeline?.stop()
            self.pipeline = nil
            if let peerID, let geometry {
                let pipeline = InputPipeline(queue: self.queue, geometry: geometry)
                pipeline.onHaptic = { [onHaptic = self.onHaptic] kind in onHaptic(peerID, kind) }
                self.pipeline = pipeline
            }
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
        }
    }

    func accept(_ connection: NWConnection) {
        queue.async { [weak self] in
            guard let self, self.admittedPeerID != nil else { connection.cancel(); return }
            let id = ObjectIdentifier(connection)
            self.connections[id] = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, let current = self.connections[id] else { return }
                if case .failed = state { self.connections.removeValue(forKey: ObjectIdentifier(current)) }
                if case .cancelled = state { self.connections.removeValue(forKey: ObjectIdentifier(current)) }
            }
            connection.start(queue: self.queue)
            self.receive(on: connection, id: id)
        }
    }

    private func receive(on connection: NWConnection, id: ObjectIdentifier) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, self.connections[id] === connection else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if error == nil { self.receive(on: connection, id: id) }
            else { connection.cancel(); self.connections.removeValue(forKey: id) }
        }
    }

    private func consume(_ data: Data) {
        do {
            let header = try data.withUnsafeBytes { try MessageHeader.decode($0) }
            switch MessageType(rawValue: header.type) {
            case .inputHeartbeat where data.count == MessageHeader.byteCount:
                if !didLogReady {
                    didLogReady = true
                    logger.info("input ready")
                }
                pipeline?.heartbeat()
            case .touchFrame:
                if let lastSequence {
                    let delta = header.sequence &- lastSequence
                    if delta > 1 && delta < 0x8000_0000 { missingFrames += Int(delta - 1) }
                }
                lastSequence = header.sequence
                receivedFrames += 1
                pipeline?.consume(data)
            default:
                break
            }
        } catch {
            // Invalid and unauthenticated datagrams are ignored without logging payloads.
        }
    }

    private func logStats() {
        guard let peerID = admittedPeerID else { return }
        let expectedFrames = receivedFrames + missingFrames
        let lossPermille = expectedFrames == 0 ? 0 : (missingFrames * 1_000 / expectedFrames)
        let p50 = pipeline?.latency.p50Micros ?? 0
        let p95 = pipeline?.latency.p95Micros ?? 0
        logger.info("framesPerSecond=\(self.receivedFrames) lossPermille=\(lossPermille) pipelineP50us=\(p50) pipelineP95us=\(p95)")
        onStatus(peerID, StatusMessage(lossPermille: UInt16(clamping: lossPermille), rttMicros: 0,
            framesPerSecond: UInt16(clamping: receivedFrames), pipelineP50Micros: p50, pipelineP95Micros: p95,
            engineState: pipeline?.diagnosticEngineState ?? 0))
        receivedFrames = 0
        missingFrames = 0
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
