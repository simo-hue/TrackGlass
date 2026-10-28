import UIKit
import XCTest
import TrackglassKit
@testable import TrackglassiOS

/// Drives `TouchSurfaceView` through its ingest API with fake touches (§5.2 capture rules).
@MainActor
final class TouchSurfaceTests: XCTestCase {
    @MainActor private final class FakeTouch: NSObject, TouchLike {
        var phase: UITouch.Phase
        let type: UITouch.TouchType
        var location: CGPoint
        var majorRadius: CGFloat = 4
        init(_ phase: UITouch.Phase = .began, type: UITouch.TouchType = .direct, at location: CGPoint) {
            self.phase = phase; self.type = type; self.location = location
            super.init()
        }
        func preciseLocation(in view: UIView?) -> CGPoint { location }
    }

    private final class CapturingSink: FrameSink, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [TouchFrame] = []
        func consume(_ bytes: UnsafeRawBufferPointer) {
            guard let frame = try? TouchFrameDecoder.decode(bytes) else { return }
            lock.lock(); stored.append(frame); lock.unlock()
        }
        var frames: [TouchFrame] { lock.lock(); defer { lock.unlock() }; return stored }
        /// The sender drains on its own queue; wait briefly for `count` frames (or for none to arrive).
        func settle(expecting count: Int) -> [TouchFrame] {
            for _ in 0..<100 {
                if frames.count >= count { break }
                usleep(10_000)
            }
            usleep(30_000)
            return frames
        }
    }

    private let geometry = SurfaceGeometry(ppi: 460, nativeScale: 3, boundsInPoints: SurfaceSize(width: 393, height: 852))

    private func makeSurface() -> (TouchSurfaceView, CapturingSink) {
        let sink = CapturingSink()
        let surface = TouchSurfaceView(frame: CGRect(x: 0, y: 0, width: 393, height: 852), sink: sink)
        surface.coalescedSamplesEnabled = false
        surface.updateGeometry(geometry)
        return (surface, sink)
    }

    func testBeganMovedEndedProduceSequencedFramesAndASyntheticLiftoff() {
        let (surface, sink) = makeSurface()
        let touch = FakeTouch(at: CGPoint(x: 100, y: 200))
        surface.ingestBegan([touch], at: 10.000)
        touch.phase = .moved; touch.location = CGPoint(x: 110, y: 200)
        surface.ingestMoved([touch], at: 10.25)   // exact binary fractions: frameTime must match to the nanosecond
        touch.phase = .ended
        surface.ingestEnded([touch], at: 10.5)
        let frames = sink.settle(expecting: 4)
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames.map(\.header.sequence), [0, 1, 2, 3])
        XCTAssertEqual(frames[0].contactCount, 1)
        XCTAssertEqual(frames[0][0].phase, .began)
        XCTAssertEqual(frames[0][0].kind, .finger)
        XCTAssertEqual(Double(frames[0][0].x), 100 * geometry.mmPerPoint, accuracy: 0.01)
        XCTAssertEqual(Double(frames[0][0].majorRadius), 4 * geometry.mmPerPoint, accuracy: 0.01)
        XCTAssertEqual(frames[0].frameTime, 10_000_000_000)
        XCTAssertEqual(frames[1][0].phase, .moved)
        XCTAssertEqual(Double(frames[1][0].x), 110 * geometry.mmPerPoint, accuracy: 0.01)
        XCTAssertEqual(frames[2][0].phase, .ended, "the terminal phase ships before the contact is released")
        XCTAssertEqual(frames[2][0].contactID, frames[0][0].contactID, "IDs stay stable for the contact's lifetime")
        XCTAssertTrue(frames[3].isSyntheticLiftoff)
        XCTAssertEqual(frames[3].contactCount, 0)
        XCTAssertFalse(frames[0].surfaceIsLandscape)
    }

    func testMovedForTheSameEventTimestampIsNotSentTwice() {
        let (surface, sink) = makeSurface()
        let touch = FakeTouch(at: CGPoint(x: 50, y: 50))
        surface.ingestBegan([touch], at: 20.0)
        touch.phase = .moved
        surface.ingestMoved([touch], at: 20.0)          // same UIEvent: suppressed
        surface.ingestMoved([touch], at: 20.25)         // next event: sent
        let frames = sink.settle(expecting: 2)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.last?.frameTime, 20_250_000_000)
    }

    func testPencilIsSentAsStylusAndIndirectTouchesAreIgnored() {
        let (surface, sink) = makeSurface()
        let pencil = FakeTouch(type: .pencil, at: CGPoint(x: 10, y: 10))
        let pointer = FakeTouch(type: .indirectPointer, at: CGPoint(x: 20, y: 20))
        surface.ingestBegan([pencil, pointer], at: 30.0)
        let frames = sink.settle(expecting: 1)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].contactCount, 1)
        XCTAssertEqual(frames[0][0].kind, .stylus)
    }

    func testEleventhContactIsIgnored() {
        let (surface, sink) = makeSurface()
        let touches = (0..<11).map { FakeTouch(at: CGPoint(x: 10 * $0 + 5, y: 100)) }
        surface.ingestBegan(touches, at: 40.0)
        let frames = sink.settle(expecting: 1)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].contactCount, 10)
        XCTAssertEqual(Set((0..<10).map { frames[0][$0].contactID }).count, 10)
    }

    func testStationaryKeepAliveRepeatsEveryHalfSecondWhileAFingerHoldsStill() {
        let (surface, sink) = makeSurface()
        let touch = FakeTouch(at: CGPoint(x: 60, y: 60))
        surface.ingestBegan([touch], at: 50.0)
        surface.emitStationaryKeepAliveIfNeeded(now: 50_300_000_000)   // 300 ms later: too early
        surface.emitStationaryKeepAliveIfNeeded(now: 50_600_000_000)   // 600 ms later: sent
        surface.emitStationaryKeepAliveIfNeeded(now: 50_700_000_000)   // 100 ms after that: too early
        let frames = sink.settle(expecting: 2)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[1][0].phase, .stationary)
        XCTAssertEqual(frames[1].frameTime, 50_600_000_000)
        XCTAssertFalse(frames[1].isSyntheticLiftoff)
        touch.phase = .ended
        surface.ingestEnded([touch], at: 51.0)
        XCTAssertEqual(sink.settle(expecting: 4).count, 4)
        surface.emitStationaryKeepAliveIfNeeded(now: 60_000_000_000)   // nothing down: nothing sent
        XCTAssertEqual(sink.settle(expecting: 5).count, 4)
    }

    func testFrameTimesNeverGoBackwardsAfterAKeepAlive() {
        let (surface, sink) = makeSurface()
        let touch = FakeTouch(at: CGPoint(x: 60, y: 60))
        surface.ingestBegan([touch], at: 80.0)
        surface.emitStationaryKeepAliveIfNeeded(now: 80_600_000_000)
        // The digitizer sampled the lift 2 ms before the display-link tick that sent the keep-alive;
        // UIKit delivers it afterwards. Without the clamp the Mac would drop both the `ended` frame
        // and the synthetic lift-off (§4.7) and keep a phantom finger for up to 1.5 s.
        touch.phase = .ended
        surface.ingestEnded([touch], at: 80.598)
        let frames = sink.settle(expecting: 4)
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames.map(\.header.sequence), [0, 1, 2, 3])
        XCTAssertEqual(frames[1][0].phase, .stationary)
        XCTAssertEqual(frames[2][0].phase, .ended)
        XCTAssertGreaterThanOrEqual(frames[2].frameTime, frames[1].frameTime)
        XCTAssertTrue(frames[3].isSyntheticLiftoff)
        XCTAssertGreaterThanOrEqual(frames[3].frameTime, frames[2].frameTime)
        // A later event with a genuinely newer timestamp is stamped as-is again.
        let next = FakeTouch(at: CGPoint(x: 70, y: 70))
        surface.ingestBegan([next], at: 81.0)
        let more = sink.settle(expecting: 5)
        XCTAssertEqual(more.count, 5)
        XCTAssertEqual(more[4].frameTime, 81_000_000_000)
    }

    func testMovedWithAnOlderSampleTimeAfterAKeepAliveIsStillSent() {
        let (surface, sink) = makeSurface()
        let touch = FakeTouch(at: CGPoint(x: 60, y: 60))
        surface.ingestBegan([touch], at: 90.0)
        surface.emitStationaryKeepAliveIfNeeded(now: 90_600_000_000)
        touch.phase = .moved; touch.location = CGPoint(x: 64, y: 60)
        surface.ingestMoved([touch], at: 90.597)
        let frames = sink.settle(expecting: 3)
        XCTAssertEqual(frames.count, 3, "an older sample is clamped, not suppressed as a duplicate")
        XCTAssertEqual(frames[2][0].phase, .moved)
        XCTAssertEqual(frames[2].frameTime, frames[1].frameTime)
    }

    func testCancelledContactsShipTheirPhaseThenLiftOff() {
        let (surface, sink) = makeSurface()
        let a = FakeTouch(at: CGPoint(x: 30, y: 30)), b = FakeTouch(at: CGPoint(x: 80, y: 30))
        surface.ingestBegan([a, b], at: 70.0)
        a.phase = .cancelled; b.phase = .cancelled
        surface.ingestEnded([a, b], at: 70.5)
        let frames = sink.settle(expecting: 3)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames[1].contactCount, 2)
        XCTAssertEqual(frames[1][0].phase, .cancelled)
        XCTAssertTrue(frames[2].isSyntheticLiftoff)
    }
}
