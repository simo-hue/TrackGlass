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
    private var latestSequence: UInt32 = 0
    private let queue: DispatchQueue
    private var recording: TGRecWriter?
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
            frame.header.sentAt = MonotonicClock.nanoseconds()
            let sink = sink
            do {
                try buffer.withUnsafeMutableBytes { bytes in
                    let count = try TouchFrameEncoder(frame: frame).encode(into: bytes)
                    sink.consume(UnsafeRawBufferPointer(rebasing: bytes[..<count]))
                    if recording != nil {
                        try recording?.append(captureTimeNs: frame.frameTime, frameBytes: Data(bytes: bytes.baseAddress!, count: count))
                    }
                }
            } catch {
                logger.error("Touch frame encoding failed")
            }
        }
    }

    func startRecording(widthMM: Double, heightMM: Double) async throws {
        let header = try TGRecHeader(origin: .phone, surfaceWidthMM: widthMM, surfaceHeightMM: heightMM)
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                recording = TGRecWriter(header: header)
                continuation.resume()
            }
        }
    }
    func finishRecording() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                drain()
                guard let writer = recording else {
                    continuation.resume(throwing: CocoaError(.fileNoSuchFile)); return
                }
                recording = nil
                do {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TrackglassRecordings", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent("Trackglass-\(UUID().uuidString).tgrec")
                    try writer.write(to: url)
                    continuation.resume(returning: url)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func sendHeartbeatIfIdle() {
        lock.lock()
        let shouldSend = !hasContacts
        let sequence = latestSequence
        lock.unlock()
        guard shouldSend, let datagramSink = sink as? UDPFrameSink else { return }
        datagramSink.sendHeartbeat(sequence: sequence)
    }
}
