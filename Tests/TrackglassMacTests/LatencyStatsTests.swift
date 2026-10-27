import Foundation
import TrackglassEngine
import TrackglassKit
import XCTest
@testable import TrackglassMac

final class LatencyStatsTests: XCTestCase {
    func testEmptyHistogramReportsZero() {
        let stats = LatencyStats()
        XCTAssertTrue(stats.isEmpty)
        XCTAssertEqual(stats.p50Micros, 0)
        XCTAssertEqual(stats.p95Micros, 0)
    }

    func testPercentilesUseNearestRank() {
        var stats = LatencyStats()
        for micros in 1...100 { stats.record(nanoseconds: UInt64(micros) * 1_000) }
        XCTAssertEqual(stats.count, 100)
        XCTAssertEqual(stats.p50Micros, 50)
        XCTAssertEqual(stats.p95Micros, 95)
        XCTAssertEqual(stats.percentileMicros(1), 100)
        XCTAssertEqual(stats.percentileMicros(0), 1)
    }

    func testRingBufferKeepsOnlyTheLastThousandSamples() {
        var stats = LatencyStats()
        for _ in 0..<1_000 { stats.record(nanoseconds: 2_000_000) }   // 2 ms, all evicted below
        for _ in 0..<1_000 { stats.record(nanoseconds: 100_000) }     // 0.1 ms
        XCTAssertEqual(stats.count, 1_000)
        XCTAssertEqual(stats.p50Micros, 100)
        XCTAssertEqual(stats.p95Micros, 100)
        XCTAssertEqual(stats.percentileMicros(1), 100)
    }

    func testOutOfRangeSamplesClampToLastBucket() {
        var stats = LatencyStats(capacity: 4)
        stats.record(nanoseconds: 10_000_000_000)
        XCTAssertEqual(stats.p95Micros, UInt32(LatencyStats.bucketCount - 1))
        stats.reset()
        XCTAssertTrue(stats.isEmpty)
        XCTAssertEqual(stats.p95Micros, 0)
    }

    func testPipelineRecordsReceiveToPostLatencyAndReportsItInStatus() {
        let queue = DispatchQueue(label: "pipeline-latency-test")
        let pipeline = InputPipeline(queue: queue, geometry: EngineGeometry(widthMM: 100, heightMM: 60, isLandscape: true), injector: SilentInjector())
        queue.sync {
            pipeline.consume(Self.frame(sequence: 1, time: 1_000_000_000, phase: .began))
            pipeline.consume(Self.frame(sequence: 2, time: 1_008_000_000, phase: .ended))
            XCTAssertEqual(pipeline.latency.count, 2)
            XCTAssertLessThan(pipeline.latency.p95Micros, UInt32(LatencyStats.bucketCount - 1), "one frame must process within the histogram range (≈4 ms) even in a debug build")
            pipeline.resetLatency()
            XCTAssertTrue(pipeline.latency.isEmpty)
            pipeline.stop()
        }
    }

    private static func frame(sequence: UInt32, time: UInt64, phase: Contact.Phase) -> Data {
        var frame = TouchFrame(sequence: sequence, frameTime: time)
        frame.append(Contact(contactID: 1, phase: phase, x: 20, y: 20))
        var bytes = [UInt8](repeating: 0, count: TouchFrame.maximumByteCount)
        let count = try! bytes.withUnsafeMutableBytes { try TouchFrameEncoder(frame: frame).encode(into: $0) }
        return Data(bytes.prefix(count))
    }
}

private final class SilentInjector: InputInjector {
    func inject(_ event: GestureEvent) {}
    func tick() {}
}
