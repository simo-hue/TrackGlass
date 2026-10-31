import Foundation
import XCTest
import TrackglassKit
@testable import TrackglassiOS

final class FrameSenderTests: XCTestCase {
    func testPhoneRecordingExportsReplayableFrames() async throws {
        let sender = FrameSender(sink: DiscardingRecordingSink())
        try await sender.startRecording(widthMM: 65, heightMM: 140)
        var frame = TouchFrame(sequence: 1, frameTime: 123_000_000)
        frame.append(Contact(contactID: 1, phase: .began, x: 10, y: 20))
        sender.enqueue(frame)
        let url = try await sender.finishRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        var reader = try TGRecReader(contentsOf: url)
        XCTAssertEqual(reader.header.origin, .phone)
        XCTAssertEqual(reader.header.surfaceWidthMM, 65)
        let record = try XCTUnwrap(reader.next())
        XCTAssertEqual(record.captureTimeNs, frame.frameTime)
        let decoded = try record.frameBytes.withUnsafeBytes { try TouchFrameDecoder.decode($0) }
        XCTAssertEqual(decoded[0].x, 10)
        XCTAssertEqual(decoded.header.sequence, 1)
        XCTAssertNil(try reader.next())
    }
    func testRingDropsOldestAndWraps() {
        var ring = FrameRing()
        XCTAssertNil(ring.dequeue())
        for sequence in 0..<40 { ring.enqueue(TouchFrame(sequence: UInt32(sequence))) }
        XCTAssertEqual(ring.count, 16)
        for sequence in 24..<40 { XCTAssertEqual(ring.dequeue()?.header.sequence, UInt32(sequence)) }
        XCTAssertNil(ring.dequeue())
        for sequence in 40..<100 {
            ring.enqueue(TouchFrame(sequence: UInt32(sequence)))
            XCTAssertEqual(ring.dequeue()?.header.sequence, UInt32(sequence))
        }
    }

    func testSenderOverflowEncodingAndReusableBuffer() {
        let first = expectation(description: "First frame reaches sink")
        let finished = expectation(description: "All retained frames delivered")
        let release = DispatchSemaphore(value: 0)
        let sink = CapturingSink(first: first, finished: finished, release: release)
        let sender = FrameSender(sink: sink)
        let before = MonotonicClock.wireNanoseconds()
        sender.enqueue(TouchFrame(sequence: 0))
        wait(for: [first], timeout: 5)
        for sequence in 1...20 {
            var frame = TouchFrame(sequence: UInt32(sequence), frameTime: UInt64(sequence))
            for id in 0..<10 {
                frame.append(Contact(contactID: UInt8(id), phase: .moved, x: Float(sequence), y: Float(id)))
            }
            sender.enqueue(frame)
        }
        release.signal()
        wait(for: [finished], timeout: 5)
        let captured = sink.snapshot()
        XCTAssertEqual(captured.frames.map { $0.header.sequence }, [0] + Array(5...20).map(UInt32.init))
        XCTAssertEqual(Set(captured.addresses).count, 1, "Encoding buffer must be reused")
        XCTAssertEqual(captured.sizes, [28] + Array(repeating: 188, count: 16))
        XCTAssertEqual(captured.frames.last?.contactCount, 10)
        XCTAssertEqual(captured.frames.last?[9].y, 9)
        XCTAssertEqual(captured.frames.last?.frameTime, 20)
        // M8 / C2: `sentAt` is the wire clock (time since this process's epoch), stamped when the frame is sent;
        // device uptime would be later than `after` by the whole epoch.
        let after = MonotonicClock.wireNanoseconds()
        XCTAssertGreaterThan(MonotonicClock.wireEpochNanoseconds, 0)
        for frame in captured.frames {
            XCTAssertGreaterThanOrEqual(frame.header.sentAt, before)
            XCTAssertLessThanOrEqual(frame.header.sentAt, after)
        }
        XCTAssertEqual(captured.frames.map(\.header.sentAt), captured.frames.map(\.header.sentAt).sorted())
        withExtendedLifetime(sender) {}
    }
}

private final class CapturingSink: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [TouchFrame] = []
    private var addresses: [UInt] = []
    private var sizes: [Int] = []
    private let first: XCTestExpectation
    private let finished: XCTestExpectation
    private let release: DispatchSemaphore

    init(first: XCTestExpectation, finished: XCTestExpectation, release: DispatchSemaphore) {
        self.first = first
        self.finished = finished
        self.release = release
    }

    func consume(_ bytes: UnsafeRawBufferPointer) {
        guard let frame = try? TouchFrameDecoder.decode(bytes) else { return }
        lock.lock()
        frames.append(frame)
        addresses.append(UInt(bitPattern: bytes.baseAddress!))
        sizes.append(bytes.count)
        let count = frames.count
        lock.unlock()
        if count == 1 {
            first.fulfill()
            _ = release.wait(timeout: .now() + 10)
        }
        if count == 17 { finished.fulfill() }
    }

    func snapshot() -> (frames: [TouchFrame], addresses: [UInt], sizes: [Int]) {
        lock.lock()
        defer { lock.unlock() }
        return (frames, addresses, sizes)
    }
}

private final class DiscardingRecordingSink: FrameSink, @unchecked Sendable {
    func consume(_ bytes: UnsafeRawBufferPointer) {}
}
