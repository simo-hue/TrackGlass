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
        surface.timeEpochNs = 0   // assert raw event times; `testFrameTimesAreTimeSinceTheLaunchEpoch` covers the offset
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

    func testAFingerLiftingWhileAnotherMovesIsSentOnce() {
        let (surface, sink) = makeSurface()
        let first = FakeTouch(at: CGPoint(x: 50, y: 50)), second = FakeTouch(at: CGPoint(x: 150, y: 50))
        surface.ingestBegan([first, second], at: 30.0)
        // One UIEvent: the second finger moved and the first lifted; UIKit calls touchesMoved, then touchesEnded.
        first.phase = .ended
        second.phase = .moved; second.location = CGPoint(x: 160, y: 50)
        surface.ingestMoved([second], at: 30.25)
        surface.ingestEnded([first], at: 30.25)
        second.phase = .ended
        surface.ingestEnded([second], at: 30.5)
        let frames = sink.settle(expecting: 4)
        XCTAssertEqual(frames.count, 4, "began, moved + ended, ended, lift-off")
        XCTAssertEqual(frames[1].contactCount, 2)
        XCTAssertTrue((0..<2).contains { frames[1][$0].phase == .ended })
        XCTAssertEqual(frames[2].contactCount, 1)
        XCTAssertEqual(frames[2][0].phase, .ended)
        XCTAssertTrue(frames[3].isSyntheticLiftoff)
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

    func testFrameTimesAreTimeSinceTheLaunchEpoch() {
        let (surface, sink) = makeSurface()
        surface.timeEpochNs = 9_000_000_000
        let touch = FakeTouch(at: CGPoint(x: 60, y: 60))
        surface.ingestBegan([touch], at: 10.0)
        surface.emitStationaryKeepAliveIfNeeded(now: 10_300_000_000)   // 300 ms after the last frame: too early
        surface.emitStationaryKeepAliveIfNeeded(now: 10_600_000_000)
        touch.phase = .ended
        surface.ingestEnded([touch], at: 10.75)
        let frames = sink.settle(expecting: 4)
        XCTAssertEqual(frames.map(\.frameTime), [1_000_000_000, 1_600_000_000, 1_750_000_000, 1_750_000_000],
                       "uptime never leaves the device; keep-alive cadence and monotonicity are unchanged")
        XCTAssertTrue(frames[3].isSyntheticLiftoff)
        // Anything stamped before the epoch is clamped to 0 instead of wrapping around.
        let (early, earlySink) = makeSurface()
        early.timeEpochNs = 20_000_000_000
        early.ingestBegan([FakeTouch(at: CGPoint(x: 5, y: 5))], at: 19.5)
        XCTAssertEqual(earlySink.settle(expecting: 1).first?.frameTime, 0)
        XCTAssertGreaterThan(TouchSurfaceView.launchEpochNs, 0)
    }

    func testKeepAliveSendsAnUndeliveredEndOnceAndLiftsOff() {
        let (surface, sink) = makeSurface()
        let touch = FakeTouch(at: CGPoint(x: 60, y: 60))
        surface.ingestBegan([touch], at: 100.0)
        touch.phase = .cancelled   // UIKit cancelled the touch but never called touchesCancelled
        surface.emitStationaryKeepAliveIfNeeded(now: 100_600_000_000)
        surface.emitStationaryKeepAliveIfNeeded(now: 101_200_000_000)   // nothing is down any more
        let frames = sink.settle(expecting: 3)
        XCTAssertEqual(frames.count, 3, "began, the terminal phase once, lift-off; no phantom keep-alives")
        XCTAssertEqual(frames[1][0].phase, .cancelled)
        XCTAssertTrue(frames[2].isSyntheticLiftoff)
        XCTAssertGreaterThanOrEqual(frames[2].frameTime, frames[1].frameTime)
    }

    func testKeepAliveDropsOnlyTheEndedContact() {
        let (surface, sink) = makeSurface()
        let held = FakeTouch(at: CGPoint(x: 60, y: 60)), lifted = FakeTouch(at: CGPoint(x: 160, y: 60))
        surface.ingestBegan([held, lifted], at: 110.0)
        lifted.phase = .ended
        surface.emitStationaryKeepAliveIfNeeded(now: 110_600_000_000)
        surface.emitStationaryKeepAliveIfNeeded(now: 111_200_000_000)
        let frames = sink.settle(expecting: 3)
        XCTAssertEqual(frames.count, 3, "no lift-off while a finger is still down")
        XCTAssertEqual(frames[1].contactCount, 2)
        XCTAssertEqual(Set((0..<2).map { frames[1][$0].phase }), [.stationary, .ended])
        XCTAssertEqual(frames[2].contactCount, 1)
        XCTAssertEqual(frames[2][0].phase, .stationary)
        XCTAssertFalse(frames[2].isSyntheticLiftoff)
    }

    func testFirstContactOfASequenceIsReportedOnce() {
        let (surface, _) = makeSurface()
        var began = 0
        surface.onFirstContactBegan = { began += 1 }
        let first = FakeTouch(at: CGPoint(x: 10, y: 10)), second = FakeTouch(at: CGPoint(x: 90, y: 10))
        surface.ingestBegan([first], at: 120.0)
        surface.ingestBegan([second], at: 120.1)
        XCTAssertEqual(began, 1, "a second finger joining is not a new sequence")
        first.phase = .ended; second.phase = .ended
        surface.ingestEnded([first, second], at: 120.2)
        first.phase = .began
        surface.ingestBegan([first], at: 121.0)
        XCTAssertEqual(began, 2)
    }
}
