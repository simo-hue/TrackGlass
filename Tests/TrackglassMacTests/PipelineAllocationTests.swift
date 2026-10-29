import Darwin
import Foundation
import TrackglassEngine
import TrackglassKit
import XCTest
@testable import TrackglassMac

/// SPEC §7 "zero allocations on the per-frame path", checked automatically for the Mac pipeline (P4).
///
/// What it measures: `malloc_zone_statistics` `blocks_in_use` across all zones before and after 10 000
/// `InputPipeline.consume` calls (decode → engine → injector, with a stub injector so no CGEvent is built). That
/// catches memory the per-frame path *keeps* (a growing array, a cache, a leaked box) — one block per frame would be
/// 10 000 blocks. Limitations: a transient allocation that is freed within the same frame leaves `blocks_in_use`
/// unchanged and is not detected here (Instruments → Allocations, "Created & Destroyed", remains the check for that,
/// as PLAN M10 requires); other threads of the test process (XCTest, dispatch) allocate concurrently, hence a small
/// tolerance instead of zero; and the frames themselves are encoded before the measurement starts.
final class PipelineAllocationTests: XCTestCase {
    private static func blocksInUse() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return Int(statistics.blocks_in_use)
    }

    /// A finger that lands, moves for 40 frames and lifts, then a two-finger scroll of 40 frames, repeated: pointer,
    /// tap bookkeeping, mode changes, scroll and momentum all run.
    private static func frames(count: Int) -> [Data] {
        var result: [Data] = []
        result.reserveCapacity(count)
        var sequence: UInt32 = 0
        var time: UInt64 = 1_000_000_000
        var storage = [UInt8](repeating: 0, count: TouchFrame.maximumByteCount)
        while result.count < count {
            let cycle = result.count / 42
            let twoFingers = cycle % 2 == 1
            for step in 0..<42 where result.count < count {
                sequence &+= 1; time += 8_333_333
                let phase: Contact.Phase = step == 0 ? .began : (step == 41 ? .ended : .moved)
                var frame = TouchFrame(sequence: sequence, frameTime: time)
                let offset = Float(step) * 0.7
                frame.append(Contact(contactID: 1, phase: phase, x: 20 + offset, y: 30 + offset / 2))
                if twoFingers { frame.append(Contact(contactID: 2, phase: phase, x: 40 + offset, y: 30 + offset / 2)) }
                let written = try! storage.withUnsafeMutableBytes { try TouchFrameEncoder(frame: frame).encode(into: $0) }
                result.append(Data(storage.prefix(written)))
            }
        }
        return result
    }

    func testConsumingFramesDoesNotGrowTheHeap() {
        let queue = DispatchQueue(label: "pipeline-allocation-test")
        let injector = CountingInjector()
        let pipeline = InputPipeline(queue: queue, geometry: EngineGeometry(widthMM: 65, heightMM: 141, isLandscape: false),
                                     injector: injector, acceleration: UnitGainAcceleration())
        let warmUp = 2_000, measured = 10_000
        let frames = Self.frames(count: warmUp + measured)
        var growth = 0
        queue.sync {
            for index in 0..<warmUp { pipeline.consume(frames[index]) }
            let before = Self.blocksInUse()
            for index in warmUp..<(warmUp + measured) { pipeline.consume(frames[index]) }
            growth = Self.blocksInUse() - before
            pipeline.stop()
        }
        XCTAssertGreaterThan(injector.count, measured / 2, "the frames produced events")
        XCTAssertLessThan(growth, 200, "\(growth) heap blocks retained over \(measured) frames")
    }
}

private final class CountingInjector: InputInjector {
    private(set) var count = 0
    func inject(_ event: GestureEvent) { count += 1 }
    func tick() {}
}
