import TrackglassKit
import XCTest
@testable import TrackglassEngine

/// Regressions from the 2026-10-29 engine review: second fingers joining a tap-and-a-half, late fingers, reused
/// contact IDs, release velocities and the heartbeat lift-off (SPEC §4.7, §6.5.3, §6.5.6, §6.5.8–§6.5.10, §6.8).
final class EdgeCaseTests: XCTestCase {
    private let ms: UInt64 = 1_000_000
    private let portrait = EngineGeometry(widthMM: 65, heightMM: 141, isLandscape: false)

    private func engine(_ settings: TrackpadSettings = TrackpadSettings()) -> GestureEngine {
        GestureEngine(settings: settings, geometry: portrait, acceleration: UnitGainAcceleration(),
                      scrollAcceleration: UnitGainAcceleration())
    }

    private func frame(_ time: UInt64, _ contacts: [(UInt8, Contact.Phase, Float, Float)], liftoff: Bool = false) -> TouchFrame {
        var frame = TouchFrame(sequence: UInt32(truncatingIfNeeded: time / ms), frameTime: time, isSyntheticLiftoff: liftoff)
        for (id, phase, x, y) in contacts { frame.append(Contact(contactID: id, phase: phase, x: x, y: y, majorRadius: 4)) }
        return frame
    }

    @discardableResult
    private func process(_ engine: GestureEngine, _ frame: TouchFrame) -> [GestureEvent] {
        var events = EventBuffer(); engine.process(frame, into: &events); return events.events
    }

    private func ticks(_ engine: GestureEngine, from start: UInt64, to end: UInt64) -> [GestureEvent] {
        var all: [GestureEvent] = []
        var time = start
        while time < end { var events = EventBuffer(); engine.tick(now: time, into: &events); all += events.events; time += 8 * ms }
        return all
    }

    private func leftButtons(_ events: [GestureEvent]) -> [GestureEvent] {
        events.filter { if case .button(.left, _, _) = $0 { return true } else { return false } }
    }

    private func pointerTravel(_ events: [GestureEvent]) -> (Double, Double) {
        events.reduce((0.0, 0.0)) { if case let .pointerMove(dx, dy) = $1 { return ($0.0 + dx, $0.1 + dy) }; return $0 }
    }

    private let click: [GestureEvent] = [.button(kind: .left, phase: .down, clickCount: 1), .button(kind: .left, phase: .up, clickCount: 1)]

    /// Tap at 0–60 ms, then a contact landing near it at 250 ms joined by a second finger 8 ms later.
    private func tapThenRepeatTapJoinedBySecondFinger(_ engine: GestureEngine) -> [GestureEvent] {
        var events = process(engine, frame(0, [(1, .began, 30, 40)]))
        events += process(engine, frame(60 * ms, [(1, .ended, 30, 40)]))
        events += process(engine, frame(250 * ms, [(1, .began, 31, 41)]))
        events += process(engine, frame(258 * ms, [(1, .stationary, 31, 41), (2, .began, 50, 41)]))
        return events
    }

    func testTapThenTwoFingerScrollHoldsNoButton() {
        for settings in [TrackpadSettings(dragging: true), TrackpadSettings(clicking: false),
                         TrackpadSettings(dragging: true, dragLock: true)] {
            let engine = engine(settings)
            var events = tapThenRepeatTapJoinedBySecondFinger(engine)
            for step in 1...10 {
                let y = 41 + 2 * Float(step)
                events += process(engine, frame(UInt64(258 + 8 * step) * ms, [(1, .moved, 31, y), (2, .moved, 50, y)]))
            }
            events += process(engine, frame(346 * ms, [(1, .ended, 31, 61), (2, .ended, 50, 61)]))
            events += ticks(engine, from: 354 * ms, to: 1_200 * ms)
            XCTAssertEqual(leftButtons(events), click, "\(settings)")
            XCTAssertEqual(pointerTravel(events).1, 0, "\(settings)")
            XCTAssertTrue(events.contains { if case .scroll(_, _, .began, _) = $0 { return true } else { return false } })
            XCTAssertFalse(events.contains(.haptic(.dragLockEngaged)))
            XCTAssertFalse(engine.isDragLockEngaged)
        }
    }

    func testTapThenTwoFingerTapIsASecondaryClickNotADoubleClick() {
        let engine = engine(TrackpadSettings(dragging: true, smartZoomEnabled: false))
        var events = tapThenRepeatTapJoinedBySecondFinger(engine)
        events += process(engine, frame(320 * ms, [(1, .ended, 31, 41), (2, .ended, 50, 41)]))
        events += ticks(engine, from: 328 * ms, to: 1_000 * ms)
        XCTAssertEqual(leftButtons(events), click)
        XCTAssertTrue(events.contains(.button(kind: .right, phase: .down, clickCount: 1)), "\(events)")
    }

    func testTapThenThreeFingerSwipeHoldsNoButton() {
        let engine = engine(TrackpadSettings(dragging: true))
        var events = process(engine, frame(0, [(1, .began, 30, 40)]))
        events += process(engine, frame(60 * ms, [(1, .ended, 30, 40)]))
        events += process(engine, frame(250 * ms, [(1, .began, 31, 41)]))
        events += process(engine, frame(258 * ms, [(1, .stationary, 31, 41), (2, .began, 45, 38), (3, .began, 55, 41)]))
        for step in 1...20 {
            let x = Float(step) * 3
            events += process(engine, frame(UInt64(258 + 8 * step) * ms, [(1, .moved, 31 + x, 41), (2, .moved, 45 + x, 38), (3, .moved, 55 + x, 41)]))
        }
        events += process(engine, frame(426 * ms, [(1, .ended, 91, 41), (2, .ended, 105, 38), (3, .ended, 115, 41)]))
        events += ticks(engine, from: 434 * ms, to: 1_000 * ms)
        XCTAssertEqual(leftButtons(events), click)
        XCTAssertEqual(pointerTravel(events).0, 0)
    }

    func testRepeatTapStillDragsAndDoubleClicks() {
        // Held still: the press goes out when the settle window has closed — from a tick, TAP_HALF_PRESS_MARGIN
        // (35 ms) after it on the estimated clock (2026-10-31) — then motion drags.
        let drag = engine(TrackpadSettings(dragging: true))
        var events = process(drag, frame(0, [(1, .began, 30, 40)]))
        events += process(drag, frame(60 * ms, [(1, .ended, 30, 40)]))
        events += process(drag, frame(250 * ms, [(1, .began, 30, 40)]))
        events += ticks(drag, from: 258 * ms, to: 350 * ms)
        XCTAssertEqual(leftButtons(events), click + [.button(kind: .left, phase: .down, clickCount: 2)])
        events = process(drag, frame(360 * ms, [(1, .moved, 36, 40)]))
        XCTAssertEqual(pointerTravel(events).0, 6, accuracy: 1e-9)
        // A quick repeat tap is a double-click: down and up on its lift.
        let double = engine(TrackpadSettings(dragging: true))
        events = process(double, frame(0, [(1, .began, 30, 40)]))
        events += process(double, frame(60 * ms, [(1, .ended, 30, 40)]))
        events += process(double, frame(250 * ms, [(1, .began, 30, 40)]))
        events += process(double, frame(290 * ms, [(1, .ended, 30, 40)]))
        XCTAssertEqual(leftButtons(events), click + [.button(kind: .left, phase: .down, clickCount: 2), .button(kind: .left, phase: .up, clickCount: 2)])
        XCTAssertFalse(double.needsTick)
    }

    func testTwoFingersInsideTheDragGraceWindowEndTheDragInsteadOfDraggingWhileScrolling() {
        let engine = engine(TrackpadSettings(dragging: true))
        process(engine, frame(0, [(1, .began, 30, 40)]))
        process(engine, frame(60 * ms, [(1, .ended, 30, 40)]))
        process(engine, frame(250 * ms, [(1, .began, 30, 40)]))
        process(engine, frame(260 * ms, [(1, .moved, 40, 40)]))
        process(engine, frame(300 * ms, [(1, .ended, 40, 40)]))   // grace window opens
        var events = process(engine, frame(400 * ms, [(2, .began, 40, 40), (3, .began, 60, 40)]))
        XCTAssertEqual(leftButtons(events), [.button(kind: .left, phase: .up, clickCount: 2)])
        for step in 1...10 {
            let y = 40 + 2 * Float(step)
            events += process(engine, frame(UInt64(400 + 8 * step) * ms, [(2, .moved, 40, y), (3, .moved, 60, y)]))
        }
        XCTAssertEqual(pointerTravel(events).1, 0)
    }

    func testNoSecondPressWhileAThreeFingerDragHoldsTheButton() {
        let engine = engine(TrackpadSettings(dragging: true, threeFingerDrag: true))
        var events = process(engine, frame(0, [(1, .began, 30, 40)]))
        events += process(engine, frame(50 * ms, [(1, .ended, 30, 40)]))
        events += process(engine, frame(100 * ms, [(2, .began, 10, 70), (3, .began, 20, 70), (4, .began, 50, 70)]))
        for step in 1...4 {
            let y = 70 + Float(step)
            events += process(engine, frame(UInt64(100 + 8 * step) * ms, [(2, .moved, 10, y), (3, .moved, 20, y), (4, .moved, 50, y)]))
        }
        events += process(engine, frame(200 * ms, [(2, .stationary, 10, 74), (3, .stationary, 20, 74), (4, .stationary, 50, 74), (5, .began, 31, 41)]))
        events += process(engine, frame(300 * ms, [(2, .ended, 10, 74), (3, .ended, 20, 74), (4, .ended, 50, 74), (5, .ended, 31, 41)]))
        events += ticks(engine, from: 308 * ms, to: 1_000 * ms)
        let downs = leftButtons(events).filter { if case .button(_, .down, _) = $0 { return true } else { return false } }
        let ups = leftButtons(events).filter { if case .button(_, .up, _) = $0 { return true } else { return false } }
        XCTAssertEqual(downs.count, ups.count, "\(leftButtons(events))")
        XCTAssertEqual(downs.count, 2)   // the tap's click and the three-finger drag
    }

    func testForceClickNeedsTheOnlyFingerOnTheGlass() {
        let engine = engine()
        var events = process(engine, frame(0, [(1, .began, 30, 40)]))
        events += process(engine, frame(80 * ms, [(1, .stationary, 30, 40), (2, .began, 50, 42)]))
        events += ticks(engine, from: 88 * ms, to: 800 * ms)
        XCTAssertFalse(events.contains(.forceClick(stage: 2)), "\(events)")
    }

    func testSlowThreeFingerDragAccumulates() {
        let engine = engine(TrackpadSettings(threeFingerDrag: true))
        for step in 0...3 {
            let y = 40 + Float(step)
            process(engine, frame(UInt64(step) * 8 * ms, [(1, step == 0 ? .began : .moved, 20, y), (2, step == 0 ? .began : .moved, 30, y), (3, step == 0 ? .began : .moved, 40, y)]))
        }
        var slow: [GestureEvent] = []
        for step in 1...100 {
            let y = 43 + 0.03 * Float(step)
            slow += process(engine, frame(UInt64(24 + 8 * step) * ms, [(1, .moved, 20, y), (2, .moved, 30, y), (3, .moved, 40, y)]))
        }
        XCTAssertEqual(pointerTravel(slow).1, 3, accuracy: 0.06)
    }

    func testLateFingerIsNotPromotedByTravelItDidNotShare() {
        let engine = engine()
        process(engine, frame(0, [(1, .began, 20, 40)]))
        process(engine, frame(100 * ms, [(1, .stationary, 20, 40), (2, .began, 30, 70)]))
        for step in 1...20 {
            process(engine, frame(UInt64(100 + 8 * step) * ms, [(1, .moved, 20 + Float(step), 40), (2, .stationary, 30, 70)]))
        }
        var drift: [GestureEvent] = []
        for step in 1...4 {
            drift += process(engine, frame(UInt64(300 + 8 * step) * ms, [(1, .stationary, 40, 40), (2, .moved, 30 + 0.5 * Float(step), 70)]))
        }
        for step in 1...10 {
            drift += process(engine, frame(UInt64(332 + 8 * step) * ms, [(1, .moved, 40, 40 + Float(step)), (2, .stationary, 32, 70)]))
        }
        XCTAssertFalse(drift.contains { if case .scroll = $0 { return true } else { return false } }, "\(drift)")
        XCTAssertEqual(pointerTravel(drift).1, 10, accuracy: 1e-9)
    }

    func testLateFingerMovingTogetherWithThePointerStillStartsAScroll() {
        let engine = engine()
        process(engine, frame(0, [(1, .began, 20, 40)]))
        var events = process(engine, frame(100 * ms, [(1, .stationary, 20, 40), (2, .began, 40, 42)]))
        for step in 1...10 {
            let y = Float(step)
            events += process(engine, frame(UInt64(100 + 8 * step) * ms, [(1, .moved, 20, 40 + y), (2, .moved, 40, 42 + y)]))
        }
        XCTAssertTrue(events.contains(.scroll(dxPoints: 0, dyPoints: 0, phase: .mayBegin, naturalInverted: true)), "\(events)")
    }

    func testFingerLeftAfterAGestureWithALateFingerPoints() {
        let engine = engine()
        process(engine, frame(0, [(1, .began, 20, 40), (2, .began, 40, 40)]))
        for step in 1...10 {
            let y = 40 + 2 * Float(step)
            process(engine, frame(UInt64(step) * 8 * ms, [(1, .moved, 20, y), (2, .moved, 40, y)]))
        }
        process(engine, frame(88 * ms, [(1, .stationary, 20, 60), (2, .stationary, 40, 60), (3, .began, 30, 90)]))
        process(engine, frame(200 * ms, [(1, .ended, 20, 60), (2, .stationary, 40, 60), (3, .stationary, 30, 90)]))
        process(engine, frame(216 * ms, [(2, .ended, 40, 60), (3, .stationary, 30, 90)]))
        var move: [GestureEvent] = []
        for step in 1...20 {
            move += process(engine, frame(UInt64(300 + 8 * step) * ms, [(3, .moved, 30 + Float(step), 90)]))
        }
        XCTAssertEqual(pointerTravel(move).0, 20, accuracy: 1e-9)
        XCTAssertEqual(engine.diagnosticState, 1)
    }

    func testReusedIDInsideAPinchEndsTheOldFingerInsteadOfJumping() {
        let engine = engine()
        process(engine, frame(0, [(1, .began, 30, 100), (2, .began, 40, 80)]))
        for step in 1...8 {
            process(engine, frame(UInt64(step) * 8 * ms, [(1, .stationary, 30, 100), (2, .moved, 40 + Float(step), 80 - Float(step))]))
        }
        // Contact 2's `ended` was lost; it re-lands with the same ID 250 ms later.
        var events = process(engine, frame(250 * ms, [(1, .stationary, 30, 100), (2, .began, 38, 82)]))
        events += process(engine, frame(258 * ms, [(1, .stationary, 30, 100), (2, .moved, 39, 81)]))
        for event in events {
            switch event {
            case .magnify(_, .changed), .rotate(_, .changed), .scroll(_, _, .began, _), .scroll(_, _, .changed, _):
                XCTFail("the re-landed finger continued the gesture: \(events)")
            default: break
            }
        }
        XCTAssertTrue(events.contains { if case .magnify(_, .ended) = $0 { return true } else { return false } }, "\(events)")
    }

    func testReusedIDAfterAQuickTapClicks() {
        let engine = engine()
        var events = process(engine, frame(0, [(1, .began, 30, 50)]))
        events += process(engine, frame(50 * ms, [(1, .began, 40, 50)]))
        XCTAssertEqual(leftButtons(events), click)
    }

    func testDockExitVelocityDoesNotDependOnARestBeforeTheSwipe() {
        func flick(restMS: UInt64) -> Double {
            let engine = engine()
            var events = process(engine, frame(0, [(1, .began, 20, 60), (2, .began, 30, 58), (3, .began, 40, 60)]))
            if restMS > 0 { events += process(engine, frame(restMS * ms, [(1, .stationary, 20, 60), (2, .stationary, 30, 58), (3, .stationary, 40, 60)])) }
            for step in 1...4 {
                let dx = Float(step) * 10
                events += process(engine, frame((restMS + UInt64(8 * step)) * ms, [(1, .moved, 20 - dx, 60), (2, .moved, 30 - dx, 58), (3, .moved, 40 - dx, 60)]))
            }
            events += process(engine, frame((restMS + 40) * ms, [(1, .ended, -20, 60), (2, .ended, -10, 58), (3, .ended, 0, 60)]))
            for event in events { if case let .dockSwipe(_, _, .ended, velocity) = event { return velocity } }
            XCTFail("no dock swipe end: \(events)"); return 0
        }
        let rested = flick(restMS: 500), immediate = flick(restMS: 0)
        XCTAssertGreaterThan(immediate, 5)
        XCTAssertEqual(rested, immediate, accuracy: immediate * 0.05)
    }

    func testHeartbeatLiftoffClicksLikeTheSyntheticLiftoff() {
        for viaLiftoffFrame in [true, false] {
            let engine = engine(TrackpadSettings(dragging: true, dragLock: true))
            var events = process(engine, frame(0, [(1, .began, 30, 40)]))
            if viaLiftoffFrame {
                events += process(engine, frame(68 * ms, [], liftoff: true))
            } else {
                events += process(engine, frame(60 * ms, [(1, .stationary, 30, 40)]))
                var buffer = EventBuffer(); engine.forceLiftoff(releaseDragLock: false, into: &buffer); events += buffer.events
            }
            XCTAssertEqual(leftButtons(events), click, "lift-off frame \(viaLiftoffFrame)")
            XCTAssertFalse(engine.hasActiveContacts)
        }
    }

    func testMomentumStoppedBeforeItsFirstStepEmitsNoEnd() {
        let engine = engine()
        var events = process(engine, frame(0, [(1, .began, 20, 40), (2, .began, 40, 40)]))
        for step in 1...6 {
            let y = 40 + 3 * Float(step)
            events += process(engine, frame(UInt64(step) * 8 * ms, [(1, .moved, 20, y), (2, .moved, 40, y)]))
        }
        events += process(engine, frame(56 * ms, [(1, .ended, 20, 58), (2, .ended, 40, 58)]))
        var buffer = EventBuffer(); engine.forceLiftoff(releaseDragLock: true, into: &buffer); events += buffer.events
        XCTAssertFalse(events.contains { if case .scrollMomentum = $0 { return true } else { return false } }, "\(events)")
    }
}
