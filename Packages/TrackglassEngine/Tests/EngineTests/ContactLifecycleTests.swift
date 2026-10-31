import TrackglassKit
import XCTest
@testable import TrackglassEngine

/// Regression tests from the 2026-10-29 review: late fingers, lost `ended` frames, resting thumbs and palms,
/// three-finger drag during a staggered lift-off, and the Dock travel before the axis locks.
final class ContactLifecycleTests: XCTestCase {
    private let ms: UInt64 = 1_000_000
    private let portrait = EngineGeometry(widthMM: 65, heightMM: 141, isLandscape: false)
    private let landscape = EngineGeometry(widthMM: 146, heightMM: 68, isLandscape: true)

    private func engine(_ settings: TrackpadSettings = TrackpadSettings(), geometry: EngineGeometry? = nil) -> GestureEngine {
        GestureEngine(settings: settings, geometry: geometry ?? portrait, acceleration: UnitGainAcceleration(),
                      scrollAcceleration: UnitGainAcceleration())
    }

    private func frame(_ time: UInt64, _ contacts: [(UInt8, Contact.Phase, Float, Float)], radius: [UInt8: Float] = [:]) -> TouchFrame {
        var frame = TouchFrame(sequence: UInt32(truncatingIfNeeded: time / ms), frameTime: time)
        for (id, phase, x, y) in contacts {
            frame.append(Contact(contactID: id, phase: phase, x: x, y: y, majorRadius: radius[id] ?? 4))
        }
        return frame
    }

    @discardableResult
    private func process(_ engine: GestureEngine, _ frame: TouchFrame) -> [GestureEvent] {
        var events = EventBuffer(); engine.process(frame, into: &events); return events.events
    }

    private func liftoff(_ engine: GestureEngine, _ time: UInt64) -> [GestureEvent] {
        process(engine, TouchFrame(frameTime: time, isSyntheticLiftoff: true))
    }

    private func tick(_ engine: GestureEngine, _ time: UInt64) -> [GestureEvent] {
        var events = EventBuffer(); engine.tick(now: time, into: &events); return events.events
    }

    private func pointerTravel(_ events: [GestureEvent]) -> (Double, Double) {
        events.reduce((0, 0)) { sum, event in
            if case let .pointerMove(dx, dy) = event { return (sum.0 + dx, sum.1 + dy) }
            return sum
        }
    }

    private func buttons(_ events: [GestureEvent]) -> [GestureEvent] {
        events.filter { if case .button = $0 { return true } else { return false } }
    }

    private func dockPhases(_ events: [GestureEvent]) -> [GesturePhase] {
        events.compactMap { if case let .dockSwipe(_, _, phase, _) = $0 { return phase } else { return nil } }
    }

    // MARK: Late fingers (§6.5.2 / §6.5.3)

    func testLateFingerTakesOverWhenThePrimaryLifts() {
        let engine = engine()
        process(engine, frame(0, [(1, .began, 30, 40)]))
        for step in 1...5 { process(engine, frame(UInt64(step) * 10 * ms, [(1, .moved, 30 + Float(step), 40)])) }
        process(engine, frame(500 * ms, [(1, .stationary, 35, 40), (2, .began, 45, 70)]))
        process(engine, frame(600 * ms, [(1, .ended, 35, 40), (2, .stationary, 45, 70)]))
        var events: [GestureEvent] = []
        for step in 1...10 {
            events += process(engine, frame((600 + UInt64(step) * 10) * ms, [(2, .moved, 45 + 2 * Float(step), 70)]))
        }
        XCTAssertEqual(pointerTravel(events).0, 20, accuracy: 1e-9, "\(events)")
    }

    func testFingerLandingBesideAThumbThatLandedFirstDrivesThePointer() {
        let engine = engine()
        // The thumb lands first in the bottom 18 mm and stays put; the index lands after the settle window.
        process(engine, frame(0, [(1, .began, 20, 135)]))
        process(engine, frame(100 * ms, [(1, .stationary, 20, 135)]))
        process(engine, frame(200 * ms, [(1, .stationary, 20, 135), (2, .began, 30, 60)]))
        var events: [GestureEvent] = []
        for step in 1...20 {
            events += process(engine, frame((200 + UInt64(step) * 10) * ms,
                                           [(1, .stationary, 20, 135), (2, .moved, 30 + Float(step), 60)]))
        }
        // The index landed after the settle window (a late finger), so its first motion rests the thumb (§6.5.2,
        // 2026-10-31) and the index points from the next frame on.
        XCTAssertEqual(pointerTravel(events).0, 19, accuracy: 1e-9, "the index drives the pointer once the thumb rests")
        XCTAssertFalse(events.contains { if case .scroll = $0 { return true } else { return false } })
    }

    // MARK: Lost `ended` frames (§4.7 / §6.5.10)

    func testTapWhoseEndedFrameWasLostStillClicksOnTheLiftoff() {
        let engine = engine()
        process(engine, frame(0, [(1, .began, 30, 40)]))
        XCTAssertEqual(liftoff(engine, 50 * ms),
                       [.button(kind: .left, phase: .down, clickCount: 1), .button(kind: .left, phase: .up, clickCount: 1), .haptic(.click)])
        XCTAssertFalse(engine.hasActiveContacts)
    }

    func testSpacesSwipeWhoseEndedFrameWasLostEndsInsteadOfSnappingBack() {
        let engine = engine()
        process(engine, frame(0, [(1, .began, 20, 60), (2, .began, 30, 60), (3, .began, 40, 60)]))
        for step in 1...10 {
            let dx = -3 * Float(step)
            process(engine, frame(UInt64(step) * 10 * ms, [(1, .moved, 20 + dx, 60), (2, .moved, 30 + dx, 60), (3, .moved, 40 + dx, 60)]))
        }
        XCTAssertEqual(dockPhases(liftoff(engine, 110 * ms)), [.ended])
    }

    func testScrollWhoseEndedFrameWasLostEndsWithMomentum() {
        let engine = engine()
        process(engine, frame(0, [(1, .began, 25, 60), (2, .began, 40, 60)]))
        for step in 1...10 {
            let dy = 2 * Float(step)
            process(engine, frame(UInt64(step) * 10 * ms, [(1, .moved, 25, 60 + dy), (2, .moved, 40, 60 + dy)]))
        }
        let events = liftoff(engine, 110 * ms)
        XCTAssertTrue(events.contains(.scroll(dxPoints: 0, dyPoints: 0, phase: .ended, naturalInverted: true)), "\(events)")
        XCTAssertTrue(engine.needsTick, "momentum coasts after the lift-off")
    }

    func testForcedLiftoffEndsAnActivatedGestureAndAGeometryChangeCancelsIt() {
        for cancelByGeometry in [false, true] {
            let engine = engine()
            process(engine, frame(0, [(1, .began, 20, 60), (2, .began, 30, 60), (3, .began, 40, 60)]))
            for step in 1...10 {
                let dx = -3 * Float(step)
                process(engine, frame(UInt64(step) * 10 * ms, [(1, .moved, 20 + dx, 60), (2, .moved, 30 + dx, 60), (3, .moved, 40 + dx, 60)]))
            }
            var events = EventBuffer()
            if cancelByGeometry { engine.setGeometry(landscape, into: &events) } else { engine.forceLiftoff(releaseDragLock: false, into: &events) }
            XCTAssertEqual(dockPhases(events.events), [cancelByGeometry ? .cancelled : .ended])
        }
    }

    // MARK: Three-finger drag (§6.5.6) during a staggered lift-off (§6.5.8)

    func testThreeFingersLeftFromAFourFingerSwipeNeverPressTheButton() {
        let engine = engine(TrackpadSettings(dragLock: true, threeFingerDrag: true))
        let xs: [Float] = [20, 30, 40, 50]
        process(engine, frame(0, xs.enumerated().map { (UInt8($0.offset + 1), .began, $0.element, 60) }))
        var events: [GestureEvent] = []
        for step in 1...8 {
            let dx = -3 * Float(step)
            events += process(engine, frame(UInt64(step) * 10 * ms, xs.enumerated().map { (UInt8($0.offset + 1), .moved, $0.element + dx, 60) }))
        }
        // Finger 4 lifts; the other three keep sliding 6 mm before they leave the glass.
        events += process(engine, frame(90 * ms, [(1, .moved, -7, 60), (2, .moved, 3, 60), (3, .moved, 13, 60), (4, .ended, 23, 60)]))
        for step in 1...3 {
            let dx = -7 - 2 * Float(step)
            events += process(engine, frame((90 + UInt64(step) * 10) * ms, [(1, .moved, dx, 60), (2, .moved, dx + 10, 60), (3, .moved, dx + 20, 60)]))
        }
        events += process(engine, frame(130 * ms, [(1, .ended, -13, 60), (2, .ended, -3, 60), (3, .ended, 7, 60)]))
        events += liftoff(engine, 130 * ms)
        events += tick(engine, 600 * ms)
        XCTAssertEqual(buttons(events), [], "\(events)")
        XCTAssertFalse(engine.isDragLockEngaged)
    }

    // MARK: Resting thumbs and palms (§6.5.2, §6.5.9)

    /// Index lands and moves; a thumb lands inside the settle window in the bottom 18 mm and is flagged resting.
    private func restThumb(_ engine: GestureEngine) {
        process(engine, frame(0, [(1, .began, 30, 60)]))
        process(engine, frame(20 * ms, [(1, .moved, 31, 60), (2, .began, 20, 135)]))
        for step in 2...20 {
            process(engine, frame(UInt64(step) * 10 * ms, [(1, .moved, 30 + Float(step), 60), (2, .stationary, 20, 135)]))
        }
        process(engine, frame(250 * ms, [(1, .ended, 50, 60), (2, .stationary, 20, 135)]))
    }

    func testTapAfterAScrollClicksWhileAThumbRests() {
        let engine = engine(TrackpadSettings(momentumScrollEnabled: false))
        restThumb(engine)
        process(engine, frame(400 * ms, [(2, .stationary, 20, 135), (3, .began, 30, 60), (4, .began, 45, 60)]))
        for step in 1...8 {
            let dy = 2 * Float(step)
            process(engine, frame((400 + UInt64(step) * 10) * ms, [(2, .stationary, 20, 135), (3, .moved, 30, 60 + dy), (4, .moved, 45, 60 + dy)]))
        }
        process(engine, frame(500 * ms, [(2, .stationary, 20, 135), (3, .ended, 30, 76), (4, .ended, 45, 76)]))
        process(engine, frame(800 * ms, [(2, .stationary, 20, 135), (5, .began, 40, 60)]))
        let events = process(engine, frame(850 * ms, [(2, .stationary, 20, 135), (5, .ended, 40, 60)]))
        XCTAssertEqual(buttons(events), [.button(kind: .left, phase: .down, clickCount: 1), .button(kind: .left, phase: .up, clickCount: 1)])
    }

    func testForceClickFiresWhileAThumbRests() {
        let engine = engine()
        restThumb(engine)
        var events: [GestureEvent] = []
        for step in 0...15 {
            let phase: Contact.Phase = step == 0 ? .began : .stationary
            events += process(engine, frame((400 + UInt64(step) * 50) * ms, [(2, .stationary, 20, 135), (5, phase, 40, 60)]))
        }
        XCTAssertTrue(events.contains(.forceClick(stage: 2)), "\(events)")
    }

    func testThumbAnchoredPinchOnALandscapePhoneSurvivesTheRestingRule() {
        let engine = engine(geometry: landscape)
        // Thumb in the bottom 18 mm (y ≥ 50); three fingers above it close in quickly (the pinch activates well
        // before the thumb's 150 ms resting check), then keep pinching slowly until 300 ms.
        var events = process(engine, frame(0, [(1, .began, 40, 60), (2, .began, 100, 15), (3, .began, 100, 25), (4, .began, 100, 35)]))
        for step in 1...30 {
            let x: Float = step <= 12 ? 100 - 3 * Float(step) : 64 - 0.5 * Float(step - 12)
            events += process(engine, frame(UInt64(step) * 10 * ms, [(1, .stationary, 40, 60), (2, .moved, x, 15), (3, .moved, x, 25), (4, .moved, x, 35)]))
        }
        XCTAssertFalse(dockPhases(events).contains(.ended), "the pinch must not end before the fingers lift: \(events)")
        events += process(engine, frame(310 * ms, [(1, .ended, 40, 60), (2, .ended, 55, 15), (3, .ended, 55, 25), (4, .ended, 55, 35)]))
        XCTAssertEqual(dockPhases(events).first, .began)
        XCTAssertEqual(dockPhases(events).last, .ended)
        XCTAssertTrue(events.allSatisfy { if case let .dockSwipe(kind, _, _, _) = $0 { return kind == .pinch } else { return true } })
    }

    // MARK: Duplicate terminal phases (phone: UIKit's moved + ended split)

    func testRepeatedEndedForAnUntrackedContactDoesNotSpoilATwoFingerTap() {
        let engine = engine(TrackpadSettings(smartZoomEnabled: false))
        // A palm wanders 10 mm and lifts, leaving a stale free slot below the tapping fingers.
        process(engine, frame(0, [(9, .began, 10, 100)], radius: [9: 12]))
        for step in 1...10 { process(engine, frame(UInt64(step) * 10 * ms, [(9, .moved, 10 + Float(step), 100)], radius: [9: 12])) }
        process(engine, frame(200 * ms, [(9, .stationary, 20, 100), (1, .began, 30, 60), (2, .began, 45, 60)], radius: [9: 12]))
        process(engine, frame(220 * ms, [(9, .ended, 20, 100), (1, .stationary, 30, 60), (2, .stationary, 45, 60)], radius: [9: 12]))
        let lift = frame(250 * ms, [(1, .ended, 30, 60), (2, .moved, 45.1, 60)])
        var events = process(engine, lift)
        events += process(engine, lift)
        events += process(engine, frame(280 * ms, [(2, .ended, 45.1, 60)]))
        XCTAssertEqual(buttons(events), [.button(kind: .right, phase: .down, clickCount: 1), .button(kind: .right, phase: .up, clickCount: 1)])
    }

    // MARK: Dock travel before the axis locks (§6.5.8, §10.3 C7)

    func testSpacesProgressIncludesTheTravelBeforeTheAxisLocked() {
        let engine = engine()
        var events = process(engine, frame(0, [(1, .began, 60, 60), (2, .began, 70, 60), (3, .began, 80, 60)]))
        for step in 1...10 {
            let dx = -2 * Float(step)
            events += process(engine, frame(UInt64(step) * 10 * ms, [(1, .moved, 60 + dx, 60), (2, .moved, 70 + dx, 60), (3, .moved, 80 + dx, 60)]))
        }
        let progress = events.reduce(0.0) { if case let .dockSwipe(_, delta, _, _) = $1 { return $0 + delta } else { return $0 } }
        XCTAssertEqual(progress, 20.0 / 110, accuracy: 1e-9)
    }
}
