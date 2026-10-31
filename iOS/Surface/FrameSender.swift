import Foundation
import OSLog
import TrackglassKit

/// Access is serialized by FrameSender's lock; storage never grows.
struct FrameRing {
    static let capacity = 16
    private var frames = Array(repeating: TouchFrame(), count: capacity)
    private var head = 0
    private(set) var count = 0

    mutating func enqueue(_ frame: TouchFrame) {
        if count == Self.capacity {
            head = (head + 1) % Self.capacity
            count -= 1
        }
        frames[(head + count) % Self.capacity] = frame
        count += 1
    }

    mutating func dequeue() -> TouchFrame? {
        guard count > 0 else { return nil }
        let frame = frames[head]
        head = (head + 1) % Self.capacity
        count -= 1
        return frame
    }
}

/// The lock protects the ring. Encoding storage and the sink are used only by
/// the serial queue. The event source avoids creating a dispatch block per frame.
final class FrameSender: @unchecked Sendable {
    private let lock = NSLock()
    private var ring = FrameRing()
    private var buffer = Data(count: TouchFrame.maximumByteCount)
    private var hasContacts = false
    /// Sequence of the newest frame; `.max` until the first one, i.e. "before frame 0" in wrap-around order, so a
    /// heartbeat sent before the first touch can never be mistaken for one sent after it (§4.7).
    private var latestSequence: UInt32 = .max
    private let queue: DispatchQueue
    private var recording: TGRecFileWriter?
    /// Why the running recording stopped by itself (a failed write); reported by `finishRecording`.
    private var recordingFailure: (any Error)?
    private let sink: any FrameSink
    private let source: any DispatchSourceUserDataAdd
    private let heartbeatTimer: DispatchSourceTimer
    private let logger = Logger(subsystem: "app.trackglass.ios", category: "FrameSender")

    init(sink: any FrameSink) {
        self.sink = sink
        let queue = DispatchQueue(label: "app.trackglass.frame-sender", qos: .userInteractive)
        self.queue = queue
        source = DispatchSource.makeUserDataAddSource(queue: queue)
        heartbeatTimer = DispatchSource.makeTimerSource(queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
        heartbeatTimer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        heartbeatTimer.setEventHandler { [weak self] in self?.sendHeartbeatIfIdle() }
        heartbeatTimer.resume()
    }

    deinit { source.cancel(); heartbeatTimer.cancel() }

    func enqueue(_ frame: TouchFrame) {
        lock.lock()
        ring.enqueue(frame)
        hasContacts = frame.contactCount > 0
        latestSequence = frame.header.sequence
        lock.unlock()
        source.add(data: 1)
    }

    private func nextFrame() -> TouchFrame? {
        lock.lock()
        defer { lock.unlock() }
        return ring.dequeue()
    }

    private func drain() {
        while var frame = nextFrame() {
            frame.header.sentAt = MonotonicClock.wireNanoseconds()   // time since launch, never uptime (§4.2, §5.10)
            let sink = sink
            let count: Int
            do {
                count = try buffer.withUnsafeMutableBytes { bytes in
                    let count = try TouchFrameEncoder(frame: frame).encode(into: bytes)
                    sink.consume(UnsafeRawBufferPointer(rebasing: bytes[..<count]))
                    return count
                }
            } catch {
                logger.error("Touch frame encoding failed")
                continue
            }
            guard let recording else { continue }
            do {
                // Streamed straight from the encode buffer: no per-frame `Data` even while recording (§7).
                try buffer.withUnsafeBytes { bytes in
                    try recording.append(captureTimeNs: frame.frameTime, frameBytes: UnsafeRawBufferPointer(rebasing: bytes[..<count]))
                }
            } catch {
                // Disk full or similar: the writer closed itself. Stop recording once instead of failing every frame.
                self.recording = nil
                recordingFailure = error
                logger.error("Recording stopped: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func startRecording(widthMM: Double, heightMM: Double) async throws {
        let header = try TGRecHeader(origin: .phone, surfaceWidthMM: widthMM, surfaceHeightMM: heightMM)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TrackglassRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Trackglass-\(UUID().uuidString).tgrec")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    try recording?.finish()
                    recordingFailure = nil
                    recording = try TGRecFileWriter(header: header, url: url)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func finishRecording() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                drain()
                guard let writer = recording else {
                    continuation.resume(throwing: recordingFailure ?? CocoaError(.fileNoSuchFile)); return
                }
                recording = nil
                do {
                    try writer.finish()
                    continuation.resume(returning: writer.url)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func sendHeartbeatIfIdle() {
        lock.lock()
        // §4.7: a heartbeat means "no finger is down as of the last frame"; it is only sent once every queued
        // frame has gone out, so it can never overtake the `ended` frame and lift-off it summarizes.
        let shouldSend = !hasContacts && ring.count == 0
        let sequence = latestSequence
        lock.unlock()
        guard shouldSend, let datagramSink = sink as? UDPFrameSink else { return }
        datagramSink.sendHeartbeat(sequence: sequence)
    }
}
