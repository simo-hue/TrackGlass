import TrackglassKit
import XCTest
@testable import TrackglassEngine

/// Regression tests from the 2026-10-29 fidelity review (round 2): staggered two-finger lift-off, Tap to click off,
/// force click from the resting zone, two-finger "bigger change wins", touch-down hysteresis, release velocities,
/// late fingers joining a scroll, sub-gesture `.began` travel, the applied-settings snapshot and the shipped scroll
/// model's gain.
final class FidelityTests: XCTestCase {
    private let ms: UInt64 = 1_000_000
    private let portrait = EngineGeometry(widthMM: 65, heightMM: 141, isLandscape: false)

    private func engine(_ settings: TrackpadSettings = TrackpadSettings()) -> GestureEngine {
        GestureEngine(settings: settings, geometry: portrait, acceleration: UnitGainAcceleration(),
                      scrollAcceleration: UnitGainAcceleration())
    }

    private func frame(_ time: UInt64, _ contacts: [(UInt8, Contact.Phase, Float, Float)]) -> TouchFrame {
        var frame = TouchFrame(sequence: UInt32(truncatingIfNeeded: time / ms), frameTime: time)
        for (id, phase, x, y) in contacts { frame.append(Contact(contactID: id, phase: phase, x: x, y: y, majorRadius: 4)) }
        return frame
    }

    @discardableResult
    private func process(_ engine: GestureEngine, _ frame: TouchFrame) -> [GestureEvent] {
        var events = EventBuffer(); engine.process(frame, into: &events); return events.events
    }

    private func tick(_ engine: GestureEngine, _ time: UInt64) -> [GestureEvent] {
        var events = EventBuffer(); engine.tick(now: time, into: &events); return events.events
    }

    private func pointerMoves(_ events: [GestureEvent]) -> [GestureEvent] {
        events.filter { if case .pointerMove = $0 { return true } else { return false } }
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

    private func scrollPhases(_ events: [GestureEvent]) -> [GesturePhase] {
        events.compactMap { if case let .scroll(_, _, phase, _) = $0 { return phase } else { return nil } }
    }

    private func momentumBegins(_ events: [GestureEvent]) -> Int {
        events.filter { if case .scrollMomentum(.begin, _, _) = $0 { return true } else { return false } }.count
    }

    private func magnifyCount(_ events: [GestureEvent]) -> Int {
        events.filter { if case .magnify = $0 { return true } else { return false } }.count
    }

    // MARK: F1 staggered two-finger lift-off (§6.5.3)

    func testLastFingerOfAScrollDoesNotMoveThePointerAndMomentumStillStarts() {
        let engine = engine()
        process(engine, frame(0, [(1, .began, 20, 40), (2, .began, 40, 40)]))
        for step in 1...6 {
            let y = 40 + 2 * Float(step)
            process(engine, frame(UInt64(step) * 8 * ms, [(1, .moved, 20, y), (2, .moved, 40, y)]))
        }
        // The first finger leaves the glass; the second keeps moving for three frames before it lifts too.
        var after = process(engine, frame(56 * ms, [(1, .ended, 20, 52), (2, .moved, 40, 54)]))
        after += process(engine, frame(64 * ms, [(2, .moved, 40, 58)]))
        after += process(engine, frame(72 * ms, [(2, .moved, 40, 62)]))
        after += process(engine, frame(80 * ms, [(2, .ended, 40, 62)]))
        XCTAssertTrue(pointerMoves(after).isEmpty, "\(after)")
        XCTAssertEqual(scrollPhases(after), [.ended])
        XCTAssertEqual(momentumBegins(tick(engine, 88 * ms)), 1, "the scroll still coasts")
    }

    func testFingerLeftFromAPossibleTwoFingerTapDoesNotMoveThePointer() {
        let engine = engine()
        process(engine, frame(0, [(1, .began, 20, 40), (2, .began, 40, 40)]))
        var after = process(engine, frame(80 * ms, [(1, .ended, 20, 40), (2, .stationary, 40, 40)]))
        after += process(engine, frame(100 * ms, [(2, .moved, 40, 46)]))
        after += process(engine, frame(120 * ms, [(2, .moved, 40, 52)]))
        after += process(engine, frame(140 * ms, [(2, .ended, 40, 52)]))
        XCTAssertTrue(pointerMoves(after).isEmpty, "\(after)")
        XCTAssertTrue(buttons(after).isEmpty, "12 mm of travel is no two-finger tap")
    }

    func testFingerLeftAfterAnIdleTwoFingerRestStillPoints() {
        // Beyond TAP_MAX_DURATION with nothing activated the pair cannot be a tap: the remaining finger points.
        let engine = engine()
        process(engine, frame(0, [(1, .began, 20, 40), (2, .began, 40, 40)]))
        process(engine, frame(400 * ms, [(1, .ended, 20, 40), (2, .stationary, 40, 40)]))
        let after = process(engine, frame(420 * ms, [(2, .moved, 40, 46)]))
        XCTAssertEqual(pointerTravel(after).1, 6, accuracy: 1e-9)
    }

    // MARK: F3 Tap to click off (§6.4: "Trackglass still clicks on tap") keeps tap-and-a-half dragging

    private func tapAndAHalf(_ settings: TrackpadSettings) -> [GestureEvent] {
        let engine = engine(settings)
        var events = process(engine, frame(0, [(1, .began, 30, 40)]))
        events += process(engine, frame(50 * ms, [(1, .ended, 30, 40)]))
        events += process(engine, frame(150 * ms, [(1, .began, 30, 40)]))
        events += process(engine, frame(200 * ms, [(1, .moved, 35, 40)]))
        events += process(engine, frame(250 * ms, [(1, .moved, 40, 40)]))
        events += process(engine, frame(300 * ms, [(1, .ended, 40, 40)]))
        events += tick(engine, 700 * ms)
        return events
    }

    func testTapAndAHalfDragsWhenTapToClickIsOffEvenWithDraggingOff() {
        let drag: [GestureEvent] = [.button(kind: .left, phase: .down, clickCount: 1), .button(kind: .left, phase: .up, clickCount: 1),
                                    .button(kind: .left, phase: .down, clickCount: 2), .button(kind: .left, phase: .up, clickCount: 2)]
        for dragging in [false, true] {
            let events = tapAndAHalf(TrackpadSettings(clicking: false, dragging: dragging))
            XCTAssertEqual(buttons(events), drag, "dragging \(dragging)")
            XCTAssertFalse(events.contains(.haptic(.dragLockEngaged)), "no drag lock unless DragLock is on")
        }
        // Tap to click on with Dragging off: the second touch is plain pointer motion.
        let events = tapAndAHalf(TrackpadSettings(clicking: true, dragging: false))
        XCTAssertEqual(buttons(events), Array(drag.prefix(2)))
    }

    // MARK: F4 no force click from the resting zone (§6.5.2, §6.5.9)

    func testAContactThatBeganInTheRestingZoneNeverForceClicks() {
        for (y, expected) in [(Float(130), 0), (Float(60), 1)] {
            let engine = engine()
            var events = process(engine, frame(0, [(1, .began, 30, y)]))
            for time in stride(from: UInt64(50), through: 900, by: 50) { events += tick(engine, time * ms) }
            let forceClicks = events.filter { $0 == .forceClick(stage: 2) }.count
            XCTAssertEqual(forceClicks, expected, "contact at y = \(y)")
            if expected == 0 { XCTAssertTrue(buttons(events).isEmpty) }
        }
    }

    // MARK: F5 two-finger "bigger change wins", no momentum after a zoom

    func testThumbAnchoredTwoFingerPinchNeitherScrollsNorCoasts() {
        let engine = engine()
        var events = process(engine, frame(0, [(1, .began, 20, 60), (2, .began, 40, 60)]))
        for step in 1...10 {
            events += process(engine, frame(UInt64(step) * 8 * ms, [(1, .stationary, 20, 60), (2, .moved, 40 + 2 * Float(step), 60)]))
        }
        events += process(engine, frame(88 * ms, [(1, .ended, 20, 60), (2, .ended, 60, 60)]))
        for time in [UInt64(96), 104, 112] { events += tick(engine, time * ms) }
        XCTAssertEqual(scrollPhases(events), [.mayBegin, .cancelled], "\(events)")
        XCTAssertGreaterThan(magnifyCount(events), 0)
        XCTAssertEqual(momentumBegins(events), 0)
    }

    func testLongScrollWhoseSpacingDriftsNeverZooms() {
        // 60 mm of scrolling while the finger spacing drifts by 3 mm (> PINCH_ACTIVATION 2.5 mm).
        let engine = engine()
        var events = process(engine, frame(0, [(1, .began, 20, 20), (2, .began, 40, 20)]))
        for step in 1...30 {
            let y = 20 + 2 * Float(step)
            events += process(engine, frame(UInt64(step) * 8 * ms, [(1, .moved, 20, y), (2, .moved, 40 + 0.1 * Float(step), y)]))
        }
        events += process(engine, frame(248 * ms, [(1, .ended, 20, 80), (2, .ended, 43, 80)]))
        XCTAssertEqual(magnifyCount(events), 0)
        XCTAssertTrue(scrollPhases(events).contains(.changed))
    }

    func testAScrollThatTurnsIntoAZoomDoesNotCoast() {
        let engine = engine()
        var events = process(engine, frame(0, [(1, .began, 20, 40), (2, .began, 40, 40)]))
        var x1: Float = 20, x2: Float = 40, y: Float = 40
        for step in 1...6 {
            y += 2
            if step > 2 { x1 -= 3; x2 += 3 }   // the spread overtakes the travel at step 4
            events += process(engine, frame(UInt64(step) * 8 * ms, [(1, .moved, x1, y), (2, .moved, x2, y)]))
        }
        events += process(engine, frame(56 * ms, [(1, .ended, x1, y), (2, .ended, x2, y)]))
        for time in [UInt64(64), 72] { events += tick(engine, time * ms) }
        XCTAssertTrue(scrollPhases(events).contains(.began))
        XCTAssertGreaterThan(magnifyCount(events), 0)
        XCTAssertEqual(momentumBegins(events), 0)
    }

    // MARK: F6 touch-down hysteresis (TAP_HYSTERESIS 0.5 mm)

    func testATapThatWobblesDoesNotMoveThePointer() {
        let engine = engine()
        var events = process(engine, frame(0, [(1, .began, 30, 40)]))
        events += process(engine, frame(16 * ms, [(1, .moved, 30.3, 40)]))
        events += process(engine, frame(32 * ms, [(1, .moved, 30.4, 40.1)]))
        events += process(engine, frame(60 * ms, [(1, .ended, 30.4, 40.1)]))
        XCTAssertTrue(pointerMoves(events).isEmpty, "\(events)")
        XCTAssertEqual(buttons(events), [.button(kind: .left, phase: .down, clickCount: 1), .button(kind: .left, phase: .up, clickCount: 1)])
    }

    func testHeldMotionIsReleasedOnceTheContactLeavesTheHysteresis() {
        let engine = engine()
        process(engine, frame(0, [(1, .began, 30, 40)]))
        XCTAssertTrue(pointerMoves(process(engine, frame(16 * ms, [(1, .moved, 30.3, 40)]))).isEmpty)
        let released = process(engine, frame(32 * ms, [(1, .moved, 31.3, 40)]))
        XCTAssertEqual(pointerTravel(released).0, 1.3, accuracy: 1e-6, "nothing is lost")
    }

    // MARK: F7 / F8 release velocities: the last 50 ms of motion

    func testDockExitVelocityIsProgressPerSecondAndZeroAfterAPause() {
        for (interval, expected) in [(UInt64(8_333_333), 0.5 / 110 * 1_000), (16_666_667, 0.5 / 110 * 1_000)] {
            // 0.5 mm/ms to the left (progress −dx / 110 mm), sampled at 120 Hz and at 60 Hz; the lift follows the
            // last frame.
            var recognizer = MultiFingerRecognizer(), events = EventBuffer()
            recognizer.begin(fingers: 3, sample: .init(x: 100, y: 100, radius: 20), time: 0)
            var time: UInt64 = 0
            while time < 150 * ms {
                time += interval
                recognizer.update(.init(x: 100 - 0.5 * Double(time) / 1e6, y: 100, radius: 20), time: time,
                                  settings: TrackpadSettings(), into: &events)
            }
            events.clear(); recognizer.end(cancelled: false, now: time + interval, into: &events)
            guard case let .dockSwipe(_, _, .ended, exit)? = events.events.first else { return XCTFail("\(events.events)") }
            XCTAssertEqual(exit, expected, accuracy: abs(expected) * 0.01, "interval \(interval)")
        }
        // The fingers stop 60 ms before lifting (stationary frames): nothing to carry over.
        var recognizer = MultiFingerRecognizer(), events = EventBuffer()
        recognizer.begin(fingers: 3, sample: .init(x: 100, y: 100, radius: 20), time: 0)
        for step in 1...10 { recognizer.update(.init(x: 100 - 4 * Double(step), y: 100, radius: 20), time: UInt64(step) * 8 * ms, settings: TrackpadSettings(), into: &events) }
        for step in 11...18 { recognizer.update(.init(x: 60, y: 100, radius: 20), time: UInt64(step) * 8 * ms, settings: TrackpadSettings(), into: &events) }
        events.clear(); recognizer.end(cancelled: false, now: 152 * ms, into: &events)
        XCTAssertEqual(events.events.first, .dockSwipe(kind: .horizontal, progressDelta: 0, phase: .ended, exitVelocity: 0))
    }

    func testMomentumVelocityIsTheLastFiftyMillisecondsOfScrolling() {
        // 120 Hz and 60 Hz sampling of the same 250 mm/s scroll give the same release velocity.
        var first: [Double] = []
        for interval in [UInt64(8_333_333), 16_666_667] {
            var momentum = ScrollMomentum(), events = EventBuffer()
            var time: UInt64 = 0
            while time < 150 * ms { time += interval; momentum.record(dx: 0, dy: 0.25 * Double(interval) / 1e6, dt: interval, at: time) }
            momentum.start(now: time + interval, enabled: true)
            momentum.tick(now: time + interval + 8 * ms, into: &events)
            guard case let .scrollMomentum(.begin, _, dy)? = events.events.first else { return XCTFail("\(events.events)") }
            first.append(dy)
        }
        XCTAssertEqual(first[0], 2.0, accuracy: 0.02)
        XCTAssertEqual(first[1], first[0], accuracy: first[0] * 0.01)
        // The fingers paused 30 ms before lifting: only 20 ms of the last 50 ms moved, so it coasts at 100 mm/s.
        var momentum = ScrollMomentum(), events = EventBuffer()
        for step in 1...12 { momentum.record(dx: 0, dy: 2, dt: 8 * ms, at: UInt64(step) * 8 * ms) }
        momentum.start(now: 126 * ms, enabled: true)
        momentum.tick(now: 134 * ms, into: &events)
        guard case let .scrollMomentum(.begin, _, dy)? = events.events.first else { return XCTFail("\(events.events)") }
        XCTAssertEqual(dy, 100 * 0.008, accuracy: 1e-6)
    }

    // MARK: F9 a late finger moving with the pointing finger joins a scroll (§6.5.3)

    private func lateFinger(lateStartY: Float, primaryMoves: Bool) -> [GestureEvent] {
        let engine = engine()
        process(engine, frame(0, [(1, .began, 20, 40)]))
        process(engine, frame(200 * ms, [(1, .stationary, 20, 40), (2, .began, 40, lateStartY)]))
        var events: [GestureEvent] = []
        for step in 1...6 {
            let d = Float(step)
            events += process(engine, frame((200 + UInt64(step) * 8) * ms,
                [(1, primaryMoves ? .moved : .stationary, 20, primaryMoves ? 40 + d : 40), (2, .moved, 40, lateStartY + d)]))
        }
        return events
    }

    func testLateFingerMovingTogetherWithThePrimaryStartsAScroll() {
        let events = lateFinger(lateStartY: 40, primaryMoves: true)
        XCTAssertTrue(scrollPhases(events).contains(.began), "\(events)")
        // Pointer motion stops once the pair is recognised.
        if let scrollStart = events.firstIndex(where: { if case .scroll = $0 { return true } else { return false } }) {
            XCTAssertTrue(pointerMoves(Array(events[scrollStart...])).isEmpty)
        }
    }

    func testLateFingerMovingAloneOrFromTheRestingZoneKeepsTheLateFingerRules() {
        XCTAssertTrue(scrollPhases(lateFinger(lateStartY: 40, primaryMoves: false)).isEmpty)
        XCTAssertTrue(scrollPhases(lateFinger(lateStartY: 128, primaryMoves: true)).isEmpty)
    }

    // MARK: F10 pinch / rotate `.began` carries the change since the fingers landed

    func testPinchAndRotateBeganCarryTheActivationTravel() {
        var recognizer = TwoFingerRecognizer(), events = EventBuffer()
        recognizer.begin(x: 30, y: 40, distance: 20, angle: 0, time: 0)
        let degree = Double.pi / 180
        for (step, (distance, angle)) in [(21.0, 3 * degree), (23.0, 6 * degree)].enumerated() {
            recognizer.update(x: 30, y: 40, distance: distance, angle: angle, time: UInt64(step + 1) * 8 * ms,
                              settings: TrackpadSettings(), acceleration: UnitGainAcceleration(), into: &events)
        }
        XCTAssertTrue(GestureEvent.approximatelyEqual(events.events,
            [.gestureBegin, .magnify(delta: 23.0 / 20 - 1, phase: .began), .rotate(deltaDegrees: 6, phase: .began)]), "\(events.events)")
    }

    // MARK: F11 the applied settings snapshot

    func testAppliedSettingsAndGenerationFollowWhatTheEngineApplies() {
        let engine = engine()
        let start = engine.settingsGeneration
        engine.setSettings(TrackpadSettings())
        XCTAssertEqual(engine.settingsGeneration, start, "the same settings are no change")
        process(engine, frame(0, [(1, .began, 30, 40)]))
        engine.setSettings(TrackpadSettings(naturalScrolling: false))
        XCTAssertTrue(engine.appliedSettings.naturalScrolling, "deferred while a finger is down (§6.4)")
        XCTAssertEqual(engine.settingsGeneration, start)
        process(engine, frame(400 * ms, [(1, .ended, 30, 40)]))
        XCTAssertFalse(engine.appliedSettings.naturalScrolling)
        XCTAssertEqual(engine.settingsGeneration, start + 1)
    }

    // MARK: F2 the shipped scroll model (ScrollFallbackAcceleration)

    func testShippedScrollModelGainIsSaneAndFrameRateIndependent() {
        let model = ScrollFallbackAcceleration()
        for speed in [5.0, 30, 150, 600] {
            var gains: [Double] = []
            for interval in [UInt64(16_666_667), 8_333_333] {
                let mm = speed * Double(interval) / 1e9
                var points = 0.0
                for _ in 0..<12 { points += model.accelerate(dxMM: 0, dyMM: mm, dtNanoseconds: interval).1 }
                gains.append(points / (12 * mm))
            }
            for gain in gains { XCTAssertTrue((3.5...6.0).contains(gain), "\(speed) mm/s: \(gain) pt/mm") }
            XCTAssertEqual(gains[1], gains[0], accuracy: gains[0] * 0.1, "60 vs 120 Hz at \(speed) mm/s")
        }
    }
}
