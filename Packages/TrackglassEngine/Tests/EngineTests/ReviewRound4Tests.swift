import Foundation
import TrackglassKit
import XCTest
@testable import TrackglassEngine

/// Regressions from the round-4 engine review (2026-10-31): tap-and-a-half press timing (H2), multi-finger
/// count changes (M9–M11), momentum (M12, M13), the resting rule (M14), rotation before SURFACE (L10), the pending
/// secondary click (L11), Drag Lock and multi-finger taps (L12) and the drag's lift sample (L13).
final class ReviewRound4Tests: XCTestCase {
    private let ms: UInt64 = 1_000_000
    private let portrait = EngineGeometry(widthMM: 65, heightMM: 141, isLandscape: false)
    private let pad = EngineGeometry(widthMM: 200, heightMM: 200, isLandscape: false)

    private func engine(_ settings: TrackpadSettings = TrackpadSettings(), geometry: EngineGeometry? = nil) -> GestureEngine {
        GestureEngine(settings: settings, geometry: geometry ?? portrait, acceleration: UnitGainAcceleration(),
                      scrollAcceleration: UnitGainAcceleration())
    }

    private func frame(_ time: UInt64, _ contacts: [(UInt8, Contact.Phase, Float, Float)], landscape: Bool = false) -> TouchFrame {
        var frame = TouchFrame(sequence: UInt32(truncatingIfNeeded: time / ms), frameTime: time, surfaceIsLandscape: landscape)
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

    private func ticks(_ engine: GestureEngine, from start: UInt64, to end: UInt64) -> [GestureEvent] {
        var all: [GestureEvent] = []
        var time = start
        while time < end { all += tick(engine, time); time += 8 * ms }
        return all
    }

    private func buttons(_ events: [GestureEvent]) -> [GestureEvent] {
        events.filter { if case .button = $0 { return true } else { return false } }
    }

    private func leftButtons(_ events: [GestureEvent]) -> [GestureEvent] {
        events.filter { if case .button(.left, _, _) = $0 { return true } else { return false } }
    }

    private func pointerTravel(_ events: [GestureEvent]) -> (Double, Double) {
        events.reduce((0.0, 0.0)) { if case let .pointerMove(dx, dy) = $1 { return ($0.0 + dx, $0.1 + dy) }; return $0 }
    }

    private func scrollPhases(_ events: [GestureEvent]) -> [GesturePhase] {
        events.compactMap { if case let .scroll(_, _, phase, _) = $0 { return phase } else { return nil } }
    }

    private func momentumPhases(_ events: [GestureEvent]) -> [MomentumPhase] {
        events.compactMap { if case let .scrollMomentum(phase, _, _) = $0 { return phase } else { return nil } }
    }

    private func dockSwipes(_ events: [GestureEvent]) -> [(kind: DockSwipeKind, delta: Double, phase: GesturePhase)] {
        events.compactMap {
            if case let .dockSwipe(kind, delta, phase, _) = $0 { return (kind: kind, delta: delta, phase: phase) } else { return nil }
        }
    }

    private let click: [GestureEvent] = [.button(kind: .left, phase: .down, clickCount: 1), .button(kind: .left, phase: .up, clickCount: 1)]
    private let secondaryClick: [GestureEvent] = [.button(kind: .right, phase: .down, clickCount: 1),
                                                  .button(kind: .right, phase: .up, clickCount: 1), .haptic(.secondaryClick)]

    /// A tap at 0–60 ms where the repeat tap lands at 250 ms: its press is due at 310 ms (settle window).
    private func tapBeforeRepeat(_ engine: GestureEngine) -> [GestureEvent] {
        process(engine, frame(0, [(1, .began, 30, 40)])) + process(engine, frame(60 * ms, [(1, .ended, 30, 40)]))
    }

    // MARK: H2 tap-and-a-half press timing (§6.5.6)

    func testMovingRepeatTapJoinedBySecondFingerInsideTheWindowPressesNothing() {
        for settings in [TrackpadSettings(dragging: true), TrackpadSettings(clicking: false),
                         TrackpadSettings(dragging: true, dragLock: true)] {
            let engine = engine(settings)
            var events = tapBeforeRepeat(engine)
            // The repeat tap is the first finger of a two-finger scroll and is already moving: 1 mm by 258 ms
            // (beyond TAP_HYSTERESIS); the second finger lands at 266 ms, inside the window.
            events += process(engine, frame(250 * ms, [(1, .began, 31, 41)]))
            events += process(engine, frame(258 * ms, [(1, .moved, 32, 41)]))
            XCTAssertTrue(leftButtons(events).elementsEqual(click), "no press on motion: \(events)")
            events += process(engine, frame(266 * ms, [(1, .moved, 33, 41), (2, .began, 50, 41)]))
            for step in 1...10 {
                let y = 41 + 2 * Float(step)
                events += process(engine, frame(UInt64(266 + 8 * step) * ms, [(1, .moved, 33, y), (2, .moved, 50, y)]))
            }
            events += process(engine, frame(354 * ms, [(1, .ended, 33, 61), (2, .ended, 50, 61)]))
            events += ticks(engine, from: 362 * ms, to: 1_200 * ms)
            XCTAssertEqual(leftButtons(events), click, "\(settings)")
            XCTAssertEqual(pointerTravel(events).0, 0, "\(settings)")
            XCTAssertEqual(pointerTravel(events).1, 0, "\(settings)")
            XCTAssertTrue(scrollPhases(events).contains(.began), "\(settings): \(events)")
            XCTAssertFalse(events.contains(.haptic(.dragLockEngaged)))
            XCTAssertFalse(engine.isDragLockEngaged)
        }
    }

    func testTickAheadOfAFrameStillInFlightDoesNotPress() {
        let engine = engine(TrackpadSettings(dragging: true))
        var events = tapBeforeRepeat(engine)
        events += process(engine, frame(250 * ms, [(1, .began, 30, 40)]))
        // The second finger landed at 290 ms (phone clock) but its frame is late: the pipeline's tick on the
        // estimated clock reaches 320 ms (press due + 10 ms) first.
        XCTAssertEqual(tick(engine, 320 * ms), [])
        events += process(engine, frame(290 * ms, [(1, .stationary, 30, 40), (2, .began, 50, 40)]))
        for step in 1...10 {
            let y = 40 + 2 * Float(step)
            events += process(engine, frame(UInt64(290 + 8 * step) * ms, [(1, .moved, 30, y), (2, .moved, 50, y)]))
        }
        events += process(engine, frame(378 * ms, [(1, .ended, 30, 60), (2, .ended, 50, 60)]))
        events += ticks(engine, from: 386 * ms, to: 1_200 * ms)
        XCTAssertEqual(leftButtons(events), click, "\(events)")
        XCTAssertTrue(scrollPhases(events).contains(.began))
    }

    func testRepeatTapPressWaitsForTheMarginOnTheEstimatedClockButNotOnAFrame() {
        let ticked = engine(TrackpadSettings(dragging: true))
        _ = tapBeforeRepeat(ticked)
        process(ticked, frame(250 * ms, [(1, .began, 30, 40)]))
        XCTAssertEqual(tick(ticked, 310 * ms), [])
        XCTAssertEqual(tick(ticked, 344 * ms), [])
        XCTAssertEqual(tick(ticked, 345 * ms), [.button(kind: .left, phase: .down, clickCount: 2)])
        // A frame stamped at the window's end that shows the contact alone presses at once.
        let framed = engine(TrackpadSettings(dragging: true))
        _ = tapBeforeRepeat(framed)
        process(framed, frame(250 * ms, [(1, .began, 30, 40)]))
        XCTAssertEqual(process(framed, frame(310 * ms, [(1, .stationary, 30, 40)])), [.button(kind: .left, phase: .down, clickCount: 2)])
    }

    func testMotionHeldWhileThePressWaitedFollowsAsDragMotion() {
        let engine = engine(TrackpadSettings(dragging: true))
        _ = tapBeforeRepeat(engine)
        var early = process(engine, frame(250 * ms, [(1, .began, 30, 40)]))
        early += process(engine, frame(258 * ms, [(1, .moved, 31, 40)]))
        early += process(engine, frame(274 * ms, [(1, .moved, 33, 40)]))
        early += process(engine, frame(290 * ms, [(1, .moved, 35, 40)]))
        XCTAssertEqual(early, [], "nothing moves or presses before the window closes")
        XCTAssertEqual(process(engine, frame(318 * ms, [(1, .moved, 37, 40)])),
                       [.button(kind: .left, phase: .down, clickCount: 2), .pointerMove(dx: 5, dy: 0), .pointerMove(dx: 2, dy: 0)])
        // A repeat tap that moved and lifted before the window closed is pressed and dragged on its lift.
        let quick = self.engine(TrackpadSettings(dragging: true))
        _ = tapBeforeRepeat(quick)
        process(quick, frame(250 * ms, [(1, .began, 30, 40)]))
        process(quick, frame(266 * ms, [(1, .moved, 34, 40)]))
        XCTAssertEqual(process(quick, frame(282 * ms, [(1, .ended, 34, 40)])),
                       [.button(kind: .left, phase: .down, clickCount: 2), .pointerMove(dx: 4, dy: 0)])
        XCTAssertEqual(tick(quick, 582 * ms), [.button(kind: .left, phase: .up, clickCount: 2)])
    }

    // MARK: M9 three-finger drag taken over by a fourth finger (§6.5.6)

    func testFourthFingerInsideTheWindowReleasesAThreeFingerDragAtOnce() {
        let engine = engine(TrackpadSettings(dragLock: true, threeFingerDrag: true), geometry: pad)
        var events = process(engine, frame(0, [(1, .began, 60, 100), (2, .began, 70, 100), (3, .began, 80, 100)]))
        events += process(engine, frame(8 * ms, [(1, .moved, 61.5, 100), (2, .moved, 71.5, 100), (3, .moved, 81.5, 100)]))
        events += process(engine, frame(16 * ms, [(1, .moved, 63, 100), (2, .moved, 73, 100), (3, .moved, 83, 100)]))
        XCTAssertEqual(leftButtons(events), [.button(kind: .left, phase: .down, clickCount: 1)], "the three-finger drag started")
        events += process(engine, frame(24 * ms, [(1, .stationary, 63, 100), (2, .stationary, 73, 100), (3, .stationary, 83, 100),
                                                  (4, .began, 90, 100)]))
        XCTAssertEqual(leftButtons(events), [.button(kind: .left, phase: .down, clickCount: 1), .button(kind: .left, phase: .up, clickCount: 1)])
        for step in 1...6 {
            let dx = -4 * Float(step)
            events += process(engine, frame(UInt64(24 + 8 * step) * ms, [(1, .moved, 63 + dx, 100), (2, .moved, 73 + dx, 100),
                                                                          (3, .moved, 83 + dx, 100), (4, .moved, 90 + dx, 100)]))
        }
        events += process(engine, frame(80 * ms, [(1, .ended, 39, 100), (2, .ended, 49, 100), (3, .ended, 59, 100), (4, .ended, 66, 100)]))
        events += ticks(engine, from: 88 * ms, to: 600 * ms)
        XCTAssertEqual(leftButtons(events), [.button(kind: .left, phase: .down, clickCount: 1), .button(kind: .left, phase: .up, clickCount: 1)])
        let up = events.firstIndex(of: .button(kind: .left, phase: .up, clickCount: 1)) ?? Int.max
        let swipe = events.firstIndex { if case .dockSwipe = $0 { return true } else { return false } } ?? -1
        XCTAssertLessThan(up, swipe, "the button is up before the Dock swipe starts: \(events)")
        XCTAssertEqual(dockSwipes(events).first?.phase, .began)
        XCTAssertFalse(events.contains(.haptic(.dragLockEngaged)))
        XCTAssertFalse(engine.isDragLockEngaged)
    }

    // MARK: M10 three to five fingers effective after the settle window (§6.5.3)

    func testThreeLateFingersSwipeOnceTheThumbHoldingThePhoneRests() {
        let engine = engine()
        process(engine, frame(0, [(1, .began, 30, 130)]))   // a thumb holding the phone, bottom 18 mm
        process(engine, frame(100 * ms, [(1, .stationary, 30, 130)]))
        var events = process(engine, frame(400 * ms, [(1, .stationary, 30, 130), (2, .began, 20, 60), (3, .began, 30, 55), (4, .began, 40, 60)]))
        for step in 1...15 {
            let dx = -2 * Float(step)
            events += process(engine, frame(UInt64(400 + 8 * step) * ms, [(1, .stationary, 30, 130), (2, .moved, 20 + dx, 60),
                                                                           (3, .moved, 30 + dx, 55), (4, .moved, 40 + dx, 60)]))
        }
        events += process(engine, frame(528 * ms, [(1, .stationary, 30, 130), (2, .ended, -10, 60), (3, .ended, 0, 55), (4, .ended, 10, 60)]))
        let swipes = dockSwipes(events)
        XCTAssertEqual(swipes.first?.phase, .began, "\(events)")
        XCTAssertEqual(swipes.last?.phase, .ended)
        XCTAssertTrue(swipes.allSatisfy { $0.kind == .horizontal })
        XCTAssertEqual(pointerTravel(events).0, 0)
        XCTAssertEqual(buttons(events), [])
    }

    // MARK: M11 the effective set growing during an active gesture (§6.5.2, §6.5.3)

    func testThumbThatStopsRestingDuringAScrollBecomesALateFinger() {
        let engine = engine()
        // Pointing with the index flags the thumb resting (170 ms); the index lifts.
        process(engine, frame(0, [(1, .began, 30, 60)]))
        process(engine, frame(20 * ms, [(1, .moved, 31, 60), (2, .began, 20, 135)]))
        for step in 2...20 {
            process(engine, frame(UInt64(step) * 10 * ms, [(1, .moved, 30 + Float(step), 60), (2, .stationary, 20, 135)]))
        }
        process(engine, frame(250 * ms, [(1, .ended, 50, 60), (2, .stationary, 20, 135)]))
        // A two-finger scroll; halfway through, the thumb drifts 8 mm (it stops resting after 3 mm).
        var events = process(engine, frame(400 * ms, [(2, .stationary, 20, 135), (3, .began, 30, 60), (4, .began, 45, 60)]))
        for step in 1...16 {
            let y = 60 + 2 * Float(step)
            let thumbY: Float = step > 8 ? 135 - Float(step - 8) : 135
            let thumbPhase: Contact.Phase = step > 8 ? .moved : .stationary
            events += process(engine, frame(UInt64(400 + 10 * step) * ms, [(2, thumbPhase, 20, thumbY),
                                                                             (3, .moved, 30, y), (4, .moved, 45, y)]))
        }
        events += process(engine, frame(570 * ms, [(2, .stationary, 20, 127), (3, .ended, 30, 92), (4, .stationary, 45, 92)]))
        events += process(engine, frame(580 * ms, [(2, .stationary, 20, 127), (4, .ended, 45, 92)]))
        let phases = scrollPhases(events)
        XCTAssertEqual(phases.first, .mayBegin)
        XCTAssertEqual(phases.filter { $0 == .changed }.count, 15, "the scroll keeps tracking after the thumb moved: \(events)")
        XCTAssertEqual(phases.last, .ended, "and ends normally")
        XCTAssertFalse(events.contains { if case .dockSwipe = $0 { return true } else { return false } })
        XCTAssertEqual(buttons(events), [])
        // The scroll fingers are gone: the late thumb is the primary and points.
        var after: [GestureEvent] = []
        for step in 1...9 {
            after += process(engine, frame(UInt64(590 + 10 * step) * ms, [(2, .moved, 20 + 2 * Float(step), 127)]))
        }
        XCTAssertEqual(pointerTravel(after).0, 18, accuracy: 1e-9, "\(after)")
    }

    func testFourthFingerAfterAnEarlySwipeActivationDoesNotJumpTheProgress() {
        let engine = engine(geometry: pad)
        var events = process(engine, frame(0, [(1, .began, 60, 100), (2, .began, 70, 90), (3, .began, 80, 100)]))
        events += process(engine, frame(8 * ms, [(1, .moved, 56, 100), (2, .moved, 66, 90), (3, .moved, 76, 100)]))
        events += process(engine, frame(16 * ms, [(1, .moved, 52, 100), (2, .moved, 62, 90), (3, .moved, 72, 100)]))
        XCTAssertEqual(dockSwipes(events).first?.phase, .began, "the swipe activated within the settle window")
        // A fourth finger lands at 24 ms, still inside the window, far from the centroid.
        events += process(engine, frame(24 * ms, [(1, .moved, 48, 100), (2, .moved, 58, 90), (3, .moved, 68, 100), (4, .began, 120, 100)]))
        for step in 1...2 {
            let dx = -4 * Float(step)
            events += process(engine, frame(UInt64(24 + 8 * step) * ms, [(1, .moved, 48 + dx, 100), (2, .moved, 58 + dx, 90),
                                                                          (3, .moved, 68 + dx, 100), (4, .moved, 120 + dx, 100)]))
        }
        events += process(engine, frame(48 * ms, [(1, .ended, 40, 100), (2, .ended, 50, 90), (3, .ended, 60, 100), (4, .ended, 112, 100)]))
        let swipes = dockSwipes(events)
        XCTAssertEqual(swipes.map { $0.phase }, [.began, .changed, .changed, .changed, .ended], "\(events)")
        for swipe in swipes where swipe.phase == .changed { XCTAssertEqual(swipe.delta, 4.0 / 110, accuracy: 1e-9) }
        XCTAssertEqual(swipes.reduce(0.0) { $0 + $1.delta }, 20.0 / 110, accuracy: 1e-9)
    }

    // MARK: M12 / M13 momentum (§6.8)

    func testLostBeganDuringMomentumStopsTheCoastFirst() {
        let engine = engine()
        var events = process(engine, frame(0, [(1, .began, 20, 20), (2, .began, 30, 20)]))
        for step in 1...3 {
            let y = 20 + 8 * Float(step)
            events += process(engine, frame(UInt64(step) * 8 * ms, [(1, .moved, 20, y), (2, .moved, 30, y)]))
        }
        events += process(engine, frame(32 * ms, [(1, .ended, 20, 44), (2, .ended, 30, 44)]))
        events += tick(engine, 40 * ms) + tick(engine, 48 * ms)
        // Two fingers put down to stop the coast and scroll again; the frame with their `began` was lost.
        let restart = events.count
        events += process(engine, frame(56 * ms, [(3, .moved, 20, 70), (4, .moved, 30, 70)]))
        for step in 1...4 {
            let y = 70 + 4 * Float(step)
            events += process(engine, frame(UInt64(56 + 8 * step) * ms, [(3, .moved, 20, y), (4, .moved, 30, y)]))
        }
        events += process(engine, frame(96 * ms, [(3, .ended, 20, 86), (4, .ended, 30, 86)]))
        events += tick(engine, 104 * ms) + tick(engine, 112 * ms)
        XCTAssertEqual(momentumPhases(events), [.begin, .continued, .end, .begin, .continued], "\(events)")
        XCTAssertEqual(events[restart], .scrollMomentum(phase: .end, dxPoints: 0, dyPoints: 0), "the coast stops before the new contacts")
        let secondScroll = events[restart...].firstIndex { if case .scroll(_, _, .began, _) = $0 { return true } else { return false } }
        let secondCoast = events[restart...].firstIndex { if case .scrollMomentum(.begin, _, _) = $0 { return true } else { return false } }
        XCTAssertNotNil(secondScroll)
        XCTAssertLessThan(secondScroll ?? Int.max, secondCoast ?? -1)
    }

    func testMomentumNeverBeginsTwiceWithoutAnEnd() {
        var momentum = ScrollMomentum(), events = EventBuffer()
        for step in 1...3 { momentum.record(dx: 0, dy: 8, dt: 8 * ms, at: UInt64(step) * 8 * ms) }
        momentum.start(now: 32 * ms, enabled: true, into: &events)
        momentum.tick(now: 40 * ms, into: &events)
        XCTAssertEqual(momentumPhases(events.events), [.begin])
        // A second scroll lifts while the first still coasts: the open phase is closed before the new one begins.
        for step in 6...8 { momentum.record(dx: 0, dy: 4, dt: 8 * ms, at: UInt64(step) * 8 * ms) }
        events.clear(); momentum.start(now: 72 * ms, enabled: true, into: &events)
        XCTAssertEqual(events.events, [.scrollMomentum(phase: .end, dxPoints: 0, dyPoints: 0)])
        events.clear(); momentum.tick(now: 80 * ms, into: &events)
        XCTAssertTrue(GestureEvent.approximatelyEqual(events.events, [.scrollMomentum(phase: .begin, dxPoints: 0, dyPoints: 500 * 0.008)]),
                      "\(events.events)")
        // Too slow to coast again: the open phase is still closed, and nothing restarts.
        momentum.record(dx: 0, dy: 0.1, dt: 8 * ms, at: 88 * ms)
        events.clear(); momentum.start(now: 96 * ms, enabled: true, into: &events)
        XCTAssertEqual(events.events, [.scrollMomentum(phase: .end, dxPoints: 0, dyPoints: 0)])
        XCTAssertFalse(momentum.active)
        // Without an event buffer a begun phase is not re-armed: it keeps coasting.
        var coasting = ScrollMomentum()
        for step in 1...3 { coasting.record(dx: 0, dy: 8, dt: 8 * ms, at: UInt64(step) * 8 * ms) }
        coasting.start(now: 32 * ms, enabled: true)
        events.clear(); coasting.tick(now: 40 * ms, into: &events)
        coasting.record(dx: 0, dy: 0.1, dt: 8 * ms, at: 48 * ms)
        coasting.start(now: 56 * ms, enabled: true)
        events.clear(); coasting.tick(now: 64 * ms, into: &events)
        guard case .scrollMomentum(.continued, _, _)? = events.events.first else { return XCTFail("\(events.events)") }
    }

    func testMomentumAfterAStallDecaysWithoutJumping() {
        var momentum = ScrollMomentum(), events = EventBuffer()
        for step in 1...3 { momentum.record(dx: 0, dy: 8, dt: 8 * ms, at: UInt64(step) * 8 * ms) }   // 1 000 pt/s
        momentum.start(now: 32 * ms, enabled: true, into: &events)
        // The first tick comes 600 ms later (a heartbeat lift-off processed at the last frame's time).
        momentum.tick(now: 632 * ms, into: &events)
        guard case let .scrollMomentum(.begin, _, first)? = events.events.first else { return XCTFail("\(events.events)") }
        XCTAssertEqual(first, 1_000 * pow(0.998, 584.0) * 0.016, accuracy: 1e-9, "one capped 16 ms step, after 584 ms of decay")
        events.clear(); momentum.tick(now: 640 * ms, into: &events)
        guard case let .scrollMomentum(.continued, _, second)? = events.events.first else { return XCTFail("\(events.events)") }
        XCTAssertEqual(second, 1_000 * pow(0.998, 600.0) * 0.008, accuracy: 1e-9, "the velocity decayed over the whole gap")
        // Through the engine: a scroll whose lift datagrams were lost ends at the heartbeat's lift-off.
        let engine = engine()
        process(engine, frame(0, [(1, .began, 20, 20), (2, .began, 30, 20)]))
        for step in 1...6 {
            let y = 20 + 8 * Float(step)
            process(engine, frame(UInt64(step) * 8 * ms, [(1, .moved, 20, y), (2, .moved, 30, y)]))
        }
        var buffer = EventBuffer(); engine.forceLiftoff(releaseDragLock: false, into: &buffer)
        XCTAssertTrue(buffer.events.contains(.scroll(dxPoints: 0, dyPoints: 0, phase: .ended, naturalInverted: true)), "\(buffer.events)")
        let coast = tick(engine, 748 * ms)
        guard case let .scrollMomentum(.begin, _, dy)? = coast.first else { return XCTFail("\(coast)") }
        XCTAssertLessThanOrEqual(dy, 1_000 * 0.016 + 1e-9, "not 700 ms of travel in one event")
    }

    // MARK: M14 the resting rule's "another contact moves" (§6.5.2)

    func testTwoFingerTapInTheRestingZoneStaysASecondaryClick() {
        // Finger A rests in the bottom 18 mm, finger B is higher; the tap lasts 170 ms.
        for drift: Float in [0.1, 1.8] {   // B's touch jitter, and a drift beyond the resting tolerance but tap-sized
            let engine = engine(TrackpadSettings(smartZoomEnabled: false))
            var events = process(engine, frame(0, [(1, .began, 30, 130), (2, .began, 45, 100)]))
            events += process(engine, frame(8 * ms, [(1, .stationary, 30, 130), (2, .moved, 45 + drift, 100)]))
            events += ticks(engine, from: 16 * ms, to: 160 * ms)
            events += process(engine, frame(160 * ms, [(2, .ended, 45 + drift, 100), (1, .stationary, 30, 130)]))
            events += process(engine, frame(170 * ms, [(1, .ended, 30, 130)]))
            XCTAssertEqual(buttons(events), Array(secondaryClick.prefix(2)), "drift \(drift): \(events)")
        }
    }

    // MARK: L10 frames from a new orientation before SURFACE (§8.7)

    func testFramesFromANewOrientationBeforeTheSurfaceCancelAndAreDropped() {
        let engine = engine()
        var events = process(engine, frame(0, [(1, .began, 20, 40), (2, .began, 40, 40)]))
        for step in 1...4 {
            let y = 40 + 3 * Float(step)
            events += process(engine, frame(UInt64(step) * 8 * ms, [(1, .moved, 20, y), (2, .moved, 40, y)]))
        }
        XCTAssertTrue(scrollPhases(events).contains(.began))
        // The phone turned: its frames say landscape while the geometry is still portrait.
        XCTAssertEqual(process(engine, frame(40 * ms, [(1, .moved, 20, 55), (2, .moved, 40, 55)], landscape: true)),
                       [.scroll(dxPoints: 0, dyPoints: 0, phase: .cancelled, naturalInverted: true)])
        XCTAssertFalse(engine.hasActiveContacts)
        XCTAssertEqual(process(engine, frame(48 * ms, [(1, .moved, 20, 58), (2, .moved, 40, 58)], landscape: true)), [])
        XCTAssertFalse(engine.hasActiveContacts, "dropped until the geometry follows")
        var buffer = EventBuffer(); engine.setGeometry(EngineGeometry(widthMM: 141, heightMM: 65, isLandscape: true), into: &buffer)
        XCTAssertEqual(buffer.events, [])
        let resumed = process(engine, frame(56 * ms, [(1, .moved, 20, 30), (2, .moved, 40, 30)], landscape: true))
        XCTAssertEqual(scrollPhases(resumed), [.mayBegin])
        XCTAssertTrue(engine.hasActiveContacts)
        // A frame still in flight from the old orientation after the SURFACE is dropped as well.
        XCTAssertEqual(process(engine, frame(64 * ms, [(1, .moved, 20, 33), (2, .moved, 40, 33)])),
                       [.scroll(dxPoints: 0, dyPoints: 0, phase: .cancelled, naturalInverted: true)])
        XCTAssertFalse(engine.hasActiveContacts)
    }

    func testOrientationIsOnlyComparedWhenItChangesAndTheGeometryHasOne() {
        // A surface whose flag never matched the geometry (and square geometry) is processed as before.
        let landscape = engine(geometry: EngineGeometry(widthMM: 146, heightMM: 68, isLandscape: true))
        process(landscape, frame(0, [(1, .began, 30, 40)]))
        XCTAssertEqual(pointerTravel(process(landscape, frame(16 * ms, [(1, .moved, 36, 40)]))).0, 6, accuracy: 1e-9)
        let square = engine(geometry: pad)
        process(square, frame(0, [(1, .began, 30, 40)]))
        XCTAssertEqual(pointerTravel(process(square, frame(16 * ms, [(1, .moved, 36, 40)], landscape: true))).0, 6, accuracy: 1e-9)
        XCTAssertEqual(pointerTravel(process(square, frame(32 * ms, [(1, .moved, 42, 40)]))).0, 6, accuracy: 1e-9)
    }

    // MARK: L11 the pending secondary click and a second tap still down (§6.5.7)

    func testPendingSecondaryClickWaitsForASecondTapThatBeganBeforeItsDeadline() {
        let engine = engine()   // smart zoom on, double-click interval 0.5 s
        var events = process(engine, frame(0, [(1, .began, 20, 40), (2, .began, 30, 40)]))
        events += process(engine, frame(50 * ms, [(1, .ended, 20, 40), (2, .ended, 30, 40)]))   // deadline 550 ms
        events += process(engine, frame(430 * ms, [(1, .began, 20, 40), (2, .began, 30, 40)]))
        events += ticks(engine, from: 438 * ms, to: 570 * ms)
        events += process(engine, frame(570 * ms, [(1, .ended, 20, 40), (2, .ended, 30, 40)]))
        events += ticks(engine, from: 578 * ms, to: 1_200 * ms)
        XCTAssertEqual(buttons(events), [], "\(events)")
        XCTAssertEqual(events.filter { $0 == .smartZoom }.count, 1)
        XCTAssertFalse(engine.needsTick)
        // Held beyond TAP_MAX_DURATION the second set can no longer be a tap: the click goes out then.
        let held = self.engine()
        process(held, frame(0, [(1, .began, 20, 40), (2, .began, 30, 40)]))
        process(held, frame(50 * ms, [(1, .ended, 20, 40), (2, .ended, 30, 40)]))
        process(held, frame(430 * ms, [(1, .began, 20, 40), (2, .began, 30, 40)]))
        XCTAssertEqual(tick(held, 550 * ms), [])
        XCTAssertEqual(tick(held, 730 * ms), [])
        XCTAssertEqual(tick(held, 731 * ms), secondaryClick)
    }

    // MARK: L12 Drag Lock ends with the next tap anywhere (§6.5.6)

    /// Tap, then a tap-and-a-half drag of 10 mm lifted with Drag Lock on: the lock holds the button.
    private func lockedDrag(_ engine: GestureEngine) {
        process(engine, frame(0, [(1, .began, 30, 40)]))
        process(engine, frame(50 * ms, [(1, .ended, 30, 40)]))
        process(engine, frame(150 * ms, [(1, .began, 30, 40)]))
        process(engine, frame(220 * ms, [(1, .moved, 40, 40)]))
        process(engine, frame(260 * ms, [(1, .ended, 40, 40)]))
        XCTAssertTrue(engine.isDragLockEngaged)
    }

    private func buttonsAndHaptics(_ events: [GestureEvent]) -> [GestureEvent] {
        events.filter {
            switch $0 {
            case .button, .haptic, .lookUpAtPointer: return true
            default: return false
            }
        }
    }

    func testTwoAndThreeFingerTapsReleaseDragLockFirst() {
        let release: [GestureEvent] = [.button(kind: .left, phase: .up, clickCount: 2), .haptic(.dragLockReleased)]
        let two = engine(TrackpadSettings(dragging: true, dragLock: true, smartZoomEnabled: false))
        lockedDrag(two)
        var events = process(two, frame(400 * ms, [(3, .began, 30, 60), (4, .began, 45, 60)]))
        events += process(two, frame(450 * ms, [(3, .ended, 30, 60), (4, .ended, 45, 60)]))
        XCTAssertEqual(buttonsAndHaptics(events), release + secondaryClick)
        XCTAssertFalse(two.isDragLockEngaged)
        let three = engine(TrackpadSettings(dragging: true, dragLock: true))
        lockedDrag(three)
        events = process(three, frame(400 * ms, [(3, .began, 30, 60), (4, .began, 40, 60), (5, .began, 50, 60)]))
        events += process(three, frame(450 * ms, [(3, .ended, 30, 60), (4, .ended, 40, 60), (5, .ended, 50, 60)]))
        XCTAssertEqual(buttonsAndHaptics(events), release + [.lookUpAtPointer])
        XCTAssertFalse(three.isDragLockEngaged)
    }

    func testTapBesideAHeldDragReleasesItInsteadOfPressingAgain() {
        for dragLock in [false, true] {
            let engine = engine(TrackpadSettings(dragging: true, dragLock: dragLock))
            var events = tapBeforeRepeat(engine)
            events += process(engine, frame(250 * ms, [(1, .began, 30, 40)]))
            events += process(engine, frame(320 * ms, [(1, .moved, 40, 40)]))
            // A second finger lands while the drag is held (late) and taps (240 ms) after the drag finger lifted,
            // inside the grace window (or with the lock engaged after it landed).
            events += process(engine, frame(330 * ms, [(1, .stationary, 40, 40), (2, .began, 50, 90)]))
            events += process(engine, frame(360 * ms, [(1, .ended, 40, 40), (2, .stationary, 50, 90)]))
            events += process(engine, frame(556 * ms, [(2, .stationary, 50, 90)]))
            events += process(engine, frame(570 * ms, [(2, .ended, 50, 90)]))
            events += ticks(engine, from: 578 * ms, to: 1_000 * ms)
            XCTAssertEqual(leftButtons(events), click + [.button(kind: .left, phase: .down, clickCount: 2),
                                                         .button(kind: .left, phase: .up, clickCount: 2)], "drag lock \(dragLock): \(events)")
            XCTAssertEqual(events.contains(.haptic(.dragLockReleased)), dragLock)
            XCTAssertFalse(engine.isDragLockEngaged)
        }
    }

    // MARK: L13 the drag's lift sample (§6.5.6)

    func testDragLiftSampleMovesThePointerBeforeTheRelease() {
        let engine = engine(TrackpadSettings(dragging: true))
        var events = tapBeforeRepeat(engine)
        events += process(engine, frame(250 * ms, [(1, .began, 30, 40)]))
        events += process(engine, frame(320 * ms, [(1, .moved, 40, 40)]))
        XCTAssertEqual(process(engine, frame(340 * ms, [(1, .ended, 42, 40)])), [.pointerMove(dx: 2, dy: 0)])
        XCTAssertEqual(tick(engine, 640 * ms), [.button(kind: .left, phase: .up, clickCount: 2)])
        XCTAssertEqual(pointerTravel(events).0, 10, accuracy: 1e-9)
    }
}
