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

    /// One coalesced sample, as `UIEvent.coalescedTouches(for:)` would return it.
    @MainActor private final class FakeSample: NSObject, TouchSampleLike {
        let phase: UITouch.Phase
        let type: UITouch.TouchType = .direct
        let location: CGPoint
        let majorRadius: CGFloat = 4
        let timestamp: TimeInterval
        init(_ phase: UITouch.Phase = .moved, at location: CGPoint, time: TimeInterval) {
            self.phase = phase; self.location = location; self.timestamp = time
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
        XCTAssertEqual(TouchSurfaceView.launchEpochNs, MonotonicClock.wireEpochNanoseconds,
                       "frameTime and every header's sentAt count from one epoch (M8)")
    }

    func testCoalescedSamplesHoldTheOtherContactsStationaryUntilTheEventsOwnFrame() {
        // M7: only the moving touches take per-sample values. A finger lifting in the same UIEvent is `.stationary`
        // in the intermediate frames and sends `.ended` once, in the event's own frame (not at the first sample).
        let (surface, sink) = makeSurface()
        let moving = FakeTouch(at: CGPoint(x: 100, y: 100)), lifting = FakeTouch(at: CGPoint(x: 200, y: 100))
        surface.ingestBegan([moving, lifting], at: 20.0)
        moving.phase = .moved; moving.location = CGPoint(x: 103, y: 100)
        lifting.phase = .ended
        let samples = [FakeSample(at: CGPoint(x: 101, y: 100), time: 20.0625),
                       FakeSample(at: CGPoint(x: 102, y: 100), time: 20.125),
                       FakeSample(at: CGPoint(x: 103, y: 100), time: 20.25)]
        // UIKit's order for one event: touchesMoved (the coalesced samples, then the event's frame), touchesEnded.
        surface.ingestCoalescedSamples(at: 20.25) { (touch: any TouchLike) -> [FakeSample]? in
            touch === moving ? samples : nil   // only `moving` is in this event's `touchesMoved` set
        }
        surface.ingestMoved([moving], at: 20.25)
        surface.ingestEnded([lifting], at: 20.25)
        let frames = sink.settle(expecting: 4)
        XCTAssertEqual(frames.count, 4, "began, two intermediate samples, the event's own frame; the lift is not repeated")
        XCTAssertEqual(frames.map(\.frameTime), [20_000_000_000, 20_062_500_000, 20_125_000_000, 20_250_000_000])
        XCTAssertTrue(frames.allSatisfy { $0.contactCount == 2 })
        XCTAssertEqual(frames.map { $0[1].phase }, [.began, .stationary, .stationary, .ended])
        XCTAssertEqual(frames.map { $0[0].phase }, [.began, .moved, .moved, .moved])
        for (index, x) in [100.0, 101, 102, 103].enumerated() {
            XCTAssertEqual(Double(frames[index][0].x), x * geometry.mmPerPoint, accuracy: 0.01)
            XCTAssertEqual(Double(frames[index][1].x), 200 * geometry.mmPerPoint, accuracy: 0.01)
        }
        XCTAssertFalse(frames.contains { $0.isSyntheticLiftoff }, "the moving finger is still down")
    }

    func testCoalescedSamplesOfAnEventWhoseFrameAlreadyWentOutAreNotSent() {
        // M7: a finger landing in the same UIEvent made `ingestBegan` send that event's frame with the live positions;
        // older samples after it would move the contacts backwards, and the new finger's `.began` goes out once.
        let (surface, sink) = makeSurface()
        let moving = FakeTouch(at: CGPoint(x: 100, y: 100)), landing = FakeTouch(at: CGPoint(x: 200, y: 100))
        surface.ingestBegan([moving], at: 30.0)
        moving.phase = .moved; moving.location = CGPoint(x: 103, y: 100)
        surface.ingestBegan([landing], at: 30.25)
        let first = [FakeSample(at: CGPoint(x: 101, y: 100), time: 30.0625),
                     FakeSample(at: CGPoint(x: 102, y: 100), time: 30.125),
                     FakeSample(at: CGPoint(x: 103, y: 100), time: 30.25)]
        surface.ingestCoalescedSamples(at: 30.25) { (touch: any TouchLike) -> [FakeSample]? in
            touch === moving ? first : nil
        }
        surface.ingestMoved([moving], at: 30.25)
        // The next event: the new finger holds still while the first keeps moving.
        landing.phase = .stationary; moving.location = CGPoint(x: 106, y: 100)
        let next = [FakeSample(at: CGPoint(x: 104, y: 100), time: 30.3125),
                    FakeSample(at: CGPoint(x: 105, y: 100), time: 30.375),
                    FakeSample(at: CGPoint(x: 106, y: 100), time: 30.5)]
        surface.ingestCoalescedSamples(at: 30.5) { (touch: any TouchLike) -> [FakeSample]? in
            touch === moving ? next : nil
        }
        surface.ingestMoved([moving], at: 30.5)
        let frames = sink.settle(expecting: 5)
        XCTAssertEqual(frames.count, 5)
        XCTAssertEqual(frames.map(\.frameTime), [30_000_000_000, 30_250_000_000, 30_312_500_000, 30_375_000_000, 30_500_000_000])
        XCTAssertEqual(frames[1][1].phase, .began)
        XCTAssertEqual(frames[2...].map { $0[1].phase }, [.stationary, .stationary, .stationary])
        let xs = frames.map { $0[0].x }
        XCTAssertEqual(xs, xs.sorted(), "the moving finger never goes backwards")
        XCTAssertEqual(Double(xs[1]), 103 * geometry.mmPerPoint, accuracy: 0.01)
    }

    func testRotatingWithFingersDownCancelsThemAndIgnoresThemUntilTheyLift() {
        // L10: the Mac still has the old SURFACE, so the live contacts end as cancelled where they were last sent, in
        // the old orientation; the rotated coordinates of those touches never leave the phone.
        let (surface, sink) = makeSurface()
        var reported: [SurfaceGeometry] = []
        surface.geometryDidChange = { reported.append($0) }
        let a = FakeTouch(at: CGPoint(x: 100, y: 200)), b = FakeTouch(at: CGPoint(x: 200, y: 200))
        surface.ingestBegan([a, b], at: 40.0)
        a.phase = .moved; a.location = CGPoint(x: 110, y: 200); b.phase = .stationary
        surface.ingestMoved([a], at: 40.25)
        surface.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
        a.location = CGPoint(x: 600, y: 90); b.location = CGPoint(x: 600, y: 190)
        let landscape = SurfaceGeometry(ppi: 460, nativeScale: 3, boundsInPoints: SurfaceSize(width: 852, height: 393))
        surface.updateGeometry(landscape, now: 40_500_000_000)
        XCTAssertEqual(reported, [landscape])
        a.location = CGPoint(x: 620, y: 90)
        surface.ingestMoved([a], at: 40.75)
        surface.emitStationaryKeepAliveIfNeeded(now: 41_500_000_000)
        a.phase = .ended; b.phase = .ended
        surface.ingestEnded([a, b], at: 42.0)
        let c = FakeTouch(at: CGPoint(x: 300, y: 100))
        surface.ingestBegan([c], at: 42.25)
        let frames = sink.settle(expecting: 5)
        XCTAssertEqual(frames.count, 5, "began, moved, cancelled, lift-off, then only the new finger")
        let cancel = frames[2]
        XCTAssertEqual(cancel.contactCount, 2)
        XCTAssertEqual(Set((0..<2).map { cancel[$0].phase }), [.cancelled])
        XCTAssertEqual(Double(cancel[0].x), 110 * geometry.mmPerPoint, accuracy: 0.01, "at the last sent position")
        XCTAssertEqual(Double(cancel[1].x), 200 * geometry.mmPerPoint, accuracy: 0.01)
        XCTAssertFalse(cancel.surfaceIsLandscape, "flagged with the orientation the Mac still has")
        XCTAssertEqual(cancel.frameTime, 40_500_000_000)
        XCTAssertTrue(frames[3].isSyntheticLiftoff)
        XCTAssertFalse(frames[3].surfaceIsLandscape)
        XCTAssertEqual(frames[4].contactCount, 1)
        XCTAssertEqual(frames[4][0].phase, .began)
        XCTAssertTrue(frames[4].surfaceIsLandscape)
        XCTAssertFalse([frames[0][0].contactID, frames[0][1].contactID].contains(frames[4][0].contactID))
    }

    func testAZeroSizeGeometryIsNeverReported() {
        // C3 (L9): a zero-size layout pass never becomes SURFACE or HELLO; frames keep the last valid geometry.
        let (surface, sink) = makeSurface()
        var reported: [SurfaceGeometry] = []
        surface.geometryDidChange = { reported.append($0) }
        surface.updateGeometry(SurfaceGeometry(ppi: 460, nativeScale: 3, boundsInPoints: SurfaceSize(width: 0, height: 852)))
        XCTAssertTrue(reported.isEmpty)
        let touch = FakeTouch(at: CGPoint(x: 100, y: 100))
        surface.ingestBegan([touch], at: 50.0)
        let frames = sink.settle(expecting: 1)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(Double(frames[0][0].x), 100 * geometry.mmPerPoint, accuracy: 0.01)
    }

    func testTheNextFingerAfterALiftGetsAFreshContactID() {
        // M5: if the lift's datagrams are lost, the Mac must not see the next finger as the old one moving.
        let (surface, sink) = makeSurface()
        let first = FakeTouch(at: CGPoint(x: 10, y: 10))
        surface.ingestBegan([first], at: 60.0)
        first.phase = .ended
        surface.ingestEnded([first], at: 60.25)
        surface.ingestBegan([FakeTouch(at: CGPoint(x: 90, y: 90))], at: 60.5)
        let frames = sink.settle(expecting: 4)
        XCTAssertEqual(frames.count, 4)
        XCTAssertNotEqual(frames[3][0].contactID, frames[0][0].contactID)
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
