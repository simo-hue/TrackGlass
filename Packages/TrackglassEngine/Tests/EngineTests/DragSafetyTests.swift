import TrackglassKit
import XCTest
@testable import TrackglassEngine

/// §4.7 / §8.8: no way of losing a drag contact may leave the left button held.
final class DragSafetyTests: XCTestCase {
    private let geometry = EngineGeometry(widthMM: 65, heightMM: 141, isLandscape: false)
    private let ms: UInt64 = 1_000_000

    private func engine(_ settings: TrackpadSettings = TrackpadSettings(dragging: true)) -> GestureEngine {
        GestureEngine(settings: settings, geometry: geometry, acceleration: UnitGainAcceleration(), scrollAcceleration: UnitGainAcceleration())
    }

    private func frame(_ time: UInt64, _ contacts: [(UInt8, Contact.Phase, Float, Float)], synthetic: Bool = false) -> TouchFrame {
        var frame = TouchFrame(sequence: UInt32(time / ms), frameTime: time, isSyntheticLiftoff: synthetic)
        for (id, phase, x, y) in contacts { frame.append(Contact(contactID: id, phase: phase, x: x, y: y)) }
        return frame
    }

    @discardableResult
    private func process(_ engine: GestureEngine, _ frame: TouchFrame) -> [GestureEvent] {
        var events = EventBuffer(); engine.process(frame, into: &events); return events.events
    }

    private func tick(_ engine: GestureEngine, _ time: UInt64) -> [GestureEvent] {
        var events = EventBuffer(); engine.tick(now: time, into: &events); return events.events
    }

    /// Tap, then a second touch that moves: the button is down and the second contact is the drag contact.
    private func startTapAndAHalfDrag(_ engine: GestureEngine) {
        process(engine, frame(1_000 * ms, [(1, .began, 30, 50)]))
        process(engine, frame(1_050 * ms, [(1, .ended, 30, 50)]))
        let down = process(engine, frame(1_200 * ms, [(2, .began, 30, 50)]))
        XCTAssertTrue(down.contains(.button(kind: .left, phase: .down, clickCount: 2)))
        process(engine, frame(1_250 * ms, [(2, .moved, 36, 50)]))
    }

    func testVanishedDragContactReleasesAfterGraceWindow() {
        let engine = engine()
        startTapAndAHalfDrag(engine)
        // The `ended` datagram is lost: a newer frame simply no longer lists contact 2.
        let vanished = process(engine, frame(1_300 * ms, []))
        XCTAssertFalse(vanished.contains(.button(kind: .left, phase: .up, clickCount: 2)))
        XCTAssertTrue(engine.needsTick, "the grace window must keep the pipeline ticking")
        XCTAssertEqual(tick(engine, 1_650 * ms), [.button(kind: .left, phase: .up, clickCount: 2)])
        XCTAssertFalse(engine.needsTick)
    }

    func testCancelledDragContactReleasesAfterGraceWindow() {
        let engine = engine()
        startTapAndAHalfDrag(engine)
        process(engine, frame(1_300 * ms, [(2, .cancelled, 36, 50)]))
        XCTAssertTrue(engine.needsTick)
        XCTAssertEqual(tick(engine, 1_650 * ms), [.button(kind: .left, phase: .up, clickCount: 2)])
    }

    func testReusedContactIDEndsTheOldDragAndTheNewContactContinuesIt() {
        let engine = engine()
        startTapAndAHalfDrag(engine)
        // A `began` for the still-tracked ID ends the old contact first (§4.7); landing inside the
        // grace window, the new contact takes over the held drag without a second press.
        let rebegan = process(engine, frame(1_300 * ms, [(2, .began, 10, 10)]))
        XCTAssertFalse(rebegan.contains { if case .button = $0 { return true } else { return false } })
        let moved = process(engine, frame(1_320 * ms, [(2, .moved, 16, 10)]))
        XCTAssertTrue(moved.contains(.pointerMove(dx: 6, dy: 0)))
        process(engine, frame(1_350 * ms, [(2, .ended, 16, 10)]))
        XCTAssertTrue(engine.needsTick)
        XCTAssertEqual(tick(engine, 1_700 * ms), [.button(kind: .left, phase: .up, clickCount: 2)])
    }

    func testSyntheticLiftoffNeverLeavesAButtonHeld() {
        let engine = engine(TrackpadSettings(dragging: true, dragLock: true))
        startTapAndAHalfDrag(engine)
        process(engine, frame(1_300 * ms, [(2, .cancelled, 36, 50)]))
        // Cancel with Drag Lock on engages the lock deliberately; the synthetic lift-off keeps it (§6.5).
        XCTAssertTrue(process(engine, frame(1_310 * ms, [], synthetic: true)).isEmpty)
        // Releasing the lock with a tap emits the up.
        process(engine, frame(2_000 * ms, [(3, .began, 30, 50)]))
        let released = process(engine, frame(2_050 * ms, [(3, .ended, 30, 50)]))
        XCTAssertTrue(released.contains(.button(kind: .left, phase: .up, clickCount: 2)))
        XCTAssertTrue(released.contains(.haptic(.dragLockReleased)))
    }

    func testThreeFingerDragRelandingInsideGraceDoesNotPressTwice() {
        let engine = engine(TrackpadSettings(threeFingerDrag: true))
        var events = process(engine, frame(1_000 * ms, [(1, .began, 20, 50), (2, .began, 25, 50), (3, .began, 30, 50)]))
        events += process(engine, frame(1_050 * ms, [(1, .moved, 24, 50), (2, .moved, 29, 50), (3, .moved, 34, 50)]))
        XCTAssertEqual(events.filter { $0 == .button(kind: .left, phase: .down, clickCount: 1) }.count, 1)
        process(engine, frame(1_100 * ms, [(1, .ended, 24, 50), (2, .ended, 29, 50), (3, .ended, 34, 50)]))
        // Re-land within 300 ms and keep dragging: the button stays down, no second press.
        events = process(engine, frame(1_200 * ms, [(4, .began, 20, 60), (5, .began, 25, 60), (6, .began, 30, 60)]))
        events += process(engine, frame(1_250 * ms, [(4, .moved, 24, 60), (5, .moved, 29, 60), (6, .moved, 34, 60)]))
        XCTAssertFalse(events.contains(.button(kind: .left, phase: .down, clickCount: 1)))
        XCTAssertFalse(events.contains(.button(kind: .left, phase: .up, clickCount: 1)))
        process(engine, frame(1_300 * ms, [(4, .ended, 24, 60), (5, .ended, 29, 60), (6, .ended, 34, 60)]))
        XCTAssertEqual(tick(engine, 1_650 * ms), [.button(kind: .left, phase: .up, clickCount: 1)])
    }

    func testIndexFingerTapClicksWhileThumbRests() {
        let engine = engine(TrackpadSettings())
        // Thumb lands at the bottom edge and stays still; the index finger moves so the thumb classifies as resting.
        process(engine, frame(0, [(1, .began, 30, 70)]))
        var time: UInt64 = 20 * ms
        var x: Float = 30
        process(engine, frame(time, [(1, .moved, 31.5, 70), (2, .began, 30, 130)]))
        while time < 400 * ms {
            time += 20 * ms; x += 1.5
            process(engine, frame(time, [(1, .moved, x, 70), (2, .stationary, 30, 130)]))
        }
        process(engine, frame(420 * ms, [(1, .ended, x, 70), (2, .stationary, 30, 130)]))
        process(engine, frame(600 * ms, [(3, .began, 40, 70), (2, .stationary, 30, 130)]))
        let events = process(engine, frame(650 * ms, [(3, .ended, 40, 70), (2, .stationary, 30, 130)]))
        XCTAssertTrue(events.contains(.button(kind: .left, phase: .down, clickCount: 1)), "\(events)")
        XCTAssertTrue(events.contains(.button(kind: .left, phase: .up, clickCount: 1)))
    }

    func testSlowMotionAccumulatesInsteadOfBeingDropped() {
        let engine = engine(TrackpadSettings())
        process(engine, frame(0, [(1, .began, 30, 50)]))
        var total = 0.0
        var x: Float = 30
        for step in 1...50 {
            x += 0.04
            for event in process(engine, frame(UInt64(step) * 8 * ms, [(1, .moved, x, 50)])) {
                if case let .pointerMove(dx, _) = event { total += dx }
            }
        }
        XCTAssertEqual(total, 2.0, accuracy: 0.1)
    }
}
