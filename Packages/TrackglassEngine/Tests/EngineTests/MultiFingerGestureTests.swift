import TrackglassKit
import XCTest
@testable import TrackglassEngine

/// §6.5.7–§6.5.8 behaviours driven through the whole engine, including the two owner decisions of
/// 2026-10-28: pinch-vs-swipe arbitration for 4/5 fingers, and staggered lift-off of 3+ finger gestures.
final class MultiFingerGestureTests: XCTestCase {
    private let ms: UInt64 = 1_000_000
    private let pad = EngineGeometry(widthMM: 200, heightMM: 200, isLandscape: false)

    private func engine(_ settings: TrackpadSettings = TrackpadSettings(),
                        geometry: EngineGeometry? = nil) -> GestureEngine {
        GestureEngine(settings: settings, geometry: geometry ?? pad, acceleration: UnitGainAcceleration(),
                      scrollAcceleration: UnitGainAcceleration())
    }

    private func frame(_ time: UInt64, _ contacts: [(UInt8, Contact.Phase, Float, Float)]) -> TouchFrame {
        var frame = TouchFrame(sequence: UInt32(truncatingIfNeeded: time / ms), frameTime: time)
        for (id, phase, x, y) in contacts { frame.append(Contact(contactID: id, phase: phase, x: x, y: y, majorRadius: 4)) }
        return frame
    }

    /// Contacts 1…n at `points`, all in `phase`, shifted by (`dx`, `dy`).
    private func contacts(_ points: [(Float, Float)], _ phase: Contact.Phase,
                          dx: Float = 0, dy: Float = 0) -> [(UInt8, Contact.Phase, Float, Float)] {
        var result: [(UInt8, Contact.Phase, Float, Float)] = []
        for (index, point) in points.enumerated() { result.append((UInt8(index + 1), phase, point.0 + dx, point.1 + dy)) }
        return result
    }

    @discardableResult
    private func process(_ engine: GestureEngine, _ frame: TouchFrame) -> [GestureEvent] {
        var events = EventBuffer(); engine.process(frame, into: &events); return events.events
    }

    private func liftoff(_ engine: GestureEngine, _ time: UInt64) -> [GestureEvent] {
        process(engine, TouchFrame(frameTime: time, isSyntheticLiftoff: true))
    }

    private func dockKinds(_ events: [GestureEvent]) -> [DockSwipeKind] {
        events.compactMap { if case let .dockSwipe(kind, _, _, _) = $0 { return kind } else { return nil } }
    }

    private func dockPhases(_ events: [GestureEvent]) -> [GesturePhase] {
        events.compactMap { if case let .dockSwipe(_, _, phase, _) = $0 { return phase } else { return nil } }
    }

    private func hasScroll(_ events: [GestureEvent]) -> Bool {
        events.contains { if case .scroll = $0 { return true } else { return false } }
    }

    private func hasPointerMove(_ events: [GestureEvent]) -> Bool {
        events.contains { if case .pointerMove = $0 { return true } else { return false } }
    }

    // MARK: Pinch vs swipe arbitration (owner decision 2026-10-28)

    func testThumbAnchoredFourFingerPinchIsLaunchpadNotASwipe() {
        // The thumb stays put while three fingers close on it: the centroid travels 6.75 mm by step 3 (the old
        // centroid-only rule locked a horizontal swipe there), but the travel all four fingers share is zero.
        let engine = engine()
        var events = process(engine, frame(0, [(1, .began, 60, 100), (2, .began, 100, 85), (3, .began, 100, 100), (4, .began, 100, 115)]))
        for step in 1...10 {
            let x = Float(100 - 3 * step)
            events += process(engine, frame(UInt64(step) * 10 * ms,
                [(1, .stationary, 60, 100), (2, .moved, x, 85), (3, .moved, x, 100), (4, .moved, x, 115)]))
        }
        events += process(engine, frame(120 * ms, [(1, .ended, 60, 100), (2, .ended, 70, 85), (3, .ended, 70, 100), (4, .ended, 70, 115)]))
        XCTAssertEqual(Set(dockKinds(events)), [.pinch], "\(events)")
        XCTAssertEqual(dockPhases(events).first, .began)
        XCTAssertEqual(dockPhases(events).last, .ended)
        if case let .dockSwipe(_, delta, _, _)? = events.first(where: { if case .dockSwipe = $0 { return true } else { return false } }) {
            XCTAssertLessThan(delta, 0, "closing fingers is Launchpad (negative progress)")
        }
    }

    func testUnevenFourFingerSwipeStaysASwipe() {
        // One finger lags (8 mm per frame instead of 10): the shared travel still beats the spread change.
        let engine = engine()
        var events = process(engine, frame(0, [(1, .began, 70, 100), (2, .began, 90, 95), (3, .began, 110, 95), (4, .began, 130, 100)]))
        for step in 1...4 {
            let d = Float(10 * step), lag = Float(8 * step)
            events += process(engine, frame(UInt64(step) * 10 * ms,
                [(1, .moved, 70 - lag, 100), (2, .moved, 90 - d, 95), (3, .moved, 110 - d, 95), (4, .moved, 130 - d, 100)]))
        }
        XCTAssertEqual(Set(dockKinds(events)), [.horizontal], "\(events)")
    }

    func testFiveFingerPinchFollowsItsOwnPreference() {
        let spreadStart: [(Float, Float)] = [(70, 100), (100, 70), (130, 100), (100, 130), (100, 100.5)]
        func run(_ settings: TrackpadSettings) -> [GestureEvent] {
            let engine = self.engine(settings)
            var events = process(engine, frame(0, contacts(spreadStart, .began)))
            // Every finger moves 12 mm toward the centre (100, 100).
            events += process(engine, frame(20 * ms, spreadStart.enumerated().map { (index, point) -> (UInt8, Contact.Phase, Float, Float) in
                let dx: Float = 100 - point.0, dy: Float = 100 - point.1
                let length: Float = max((dx * dx + dy * dy).squareRoot(), 0.001)
                let step: Float = min(12, length)
                return (UInt8(index + 1), .moved, point.0 + dx / length * step, point.1 + dy / length * step)
            }))
            return events
        }
        XCTAssertEqual(dockKinds(run(TrackpadSettings())).first, .pinch)
        XCTAssertTrue(dockKinds(run(TrackpadSettings(fiveFingerPinchGesture: 0))).isEmpty)
    }

    func testDockGestureKeysDisableTheirGestures() {
        let symmetric: [(Float, Float)] = [(70, 100), (100, 70), (130, 100), (100, 130)]
        func pinch(_ settings: TrackpadSettings, spread: Bool) -> [GestureEvent] {
            let engine = self.engine(settings)
            let closed: [(Float, Float)] = symmetric.map { point in (100 + (point.0 - 100) * 0.6, 100 + (point.1 - 100) * 0.6) }
            let start: [(Float, Float)] = spread ? closed : symmetric
            let end: [(Float, Float)] = spread ? symmetric : closed
            var events = process(engine, frame(0, contacts(start, .began)))
            events += process(engine, frame(20 * ms, contacts(end, .moved)))
            return events
        }
        XCTAssertEqual(dockKinds(pinch(TrackpadSettings(), spread: false)), [.pinch])
        XCTAssertTrue(dockKinds(pinch(TrackpadSettings(launchpadEnabled: false), spread: false)).isEmpty, "Launchpad off")
        XCTAssertEqual(dockKinds(pinch(TrackpadSettings(), spread: true)), [.pinch])
        XCTAssertTrue(dockKinds(pinch(TrackpadSettings(showDesktopEnabled: false), spread: true)).isEmpty, "Show Desktop off")
        // App Exposé (four fingers down) off.
        let engine = engine(TrackpadSettings(appExposeEnabled: false))
        var events = process(engine, frame(0, contacts(symmetric, .began)))
        events += process(engine, frame(20 * ms, contacts(symmetric, .moved, dy: 12)))
        XCTAssertTrue(dockKinds(events).isEmpty, "\(events)")
    }

    // MARK: Spaces tracking and navigation

    func testSpacesTracksTheFingersLiveAcrossFrames() {
        // C7: 110 mm switches one Space — progress −1.0 delivered as began + changed deltas, then ended.
        let engine = engine()
        let start: [(Float, Float)] = [(30, 90), (50, 110), (70, 90)]
        var events = process(engine, frame(0, contacts(start, .began)))
        for step in 1...11 {
            events += process(engine, frame(UInt64(step) * 10 * ms,
                contacts(start, .moved, dx: Float(10 * step))))
        }
        events += process(engine, frame(120 * ms, contacts(start, .ended, dx: 110)))
        var progress = 0.0
        var phases: [GesturePhase] = []
        var exitVelocity = 0.0
        for event in events {
            guard case let .dockSwipe(kind, delta, phase, exit) = event else { continue }
            XCTAssertEqual(kind, .horizontal)
            progress += delta; phases.append(phase); exitVelocity = exit
        }
        XCTAssertEqual(progress, -1.0, accuracy: 1e-9)
        XCTAssertEqual(phases.first, .began)
        XCTAssertEqual(phases.last, .ended)
        XCTAssertGreaterThanOrEqual(phases.filter { $0 == .changed }.count, 9, "live tracking, not one jump")
        XCTAssertEqual(exitVelocity, -10.0 / 110 * 100, accuracy: 1e-9)
        XCTAssertTrue(events.contains(.haptic(.spaceSwitched)))
    }

    func testThreeFingerNavigationSwipeRight() {
        let engine = engine(TrackpadSettings(threeFingerHorizontalGesture: 1))
        let start: [(Float, Float)] = [(80, 90), (100, 110), (120, 90)]
        var events = process(engine, frame(0, contacts(start, .began)))
        events += process(engine, frame(20 * ms, contacts(start, .moved, dx: 25)))
        XCTAssertEqual(events.filter { if case .navigationSwipe = $0 { return true } else { return false } },
                       [.navigationSwipe(direction: .right)])
    }

    // MARK: Staggered lift-off (owner decision 2026-10-28)

    func testStaggeredLiftAfterASpacesSwipeEmitsNoScrollAndNoPointerMotion() {
        let engine = engine()
        var events = process(engine, frame(0, [(1, .began, 80, 90), (2, .began, 100, 110), (3, .began, 120, 90)]))
        events += process(engine, frame(20 * ms, [(1, .moved, 140, 90), (2, .moved, 160, 110), (3, .moved, 180, 90)]))
        // Fingers leave the glass one by one; the last one still drifts 10 mm before it lifts.
        events += process(engine, frame(40 * ms, [(1, .ended, 140, 90), (2, .stationary, 160, 110), (3, .stationary, 180, 90)]))
        events += process(engine, frame(56 * ms, [(2, .ended, 160, 110), (3, .moved, 185, 90)]))
        events += process(engine, frame(72 * ms, [(3, .moved, 190, 90)]))
        events += process(engine, frame(88 * ms, [(3, .ended, 190, 90)]))
        events += liftoff(engine, 88 * ms)
        XCTAssertFalse(hasScroll(events), "no stray mayBegin/cancelled scroll pair: \(events)")
        XCTAssertFalse(hasPointerMove(events), "the last finger must not move the pointer: \(events)")
        XCTAssertEqual(dockPhases(events), [.began, .ended])
        XCTAssertTrue(events.contains(.haptic(.spaceSwitched)))
        XCTAssertFalse(engine.hasActiveContacts)
        // The next ordinary one-finger touch points again.
        process(engine, frame(300 * ms, [(9, .began, 50, 50)]))
        XCTAssertTrue(hasPointerMove(process(engine, frame(316 * ms, [(9, .moved, 55, 50)]))))
    }

    func testStaggeredLiftOfAThreeFingerTapStillLooksUp() {
        let engine = engine()
        var events = process(engine, frame(1_000 * ms, [(1, .began, 28, 50), (2, .began, 32, 50), (3, .began, 36, 50)]))
        events += process(engine, frame(1_080 * ms, [(1, .ended, 28, 50), (2, .stationary, 32, 50), (3, .stationary, 36, 50)]))
        events += process(engine, frame(1_090 * ms, [(2, .ended, 32, 50), (3, .stationary, 36, 50)]))
        events += process(engine, frame(1_100 * ms, [(3, .ended, 36, 50)]))
        XCTAssertEqual(events, [.lookUpAtPointer])
    }

    func testStaggeredLiftAfterThreeFingerDragReleasesAfterGraceWithoutScrolling() {
        let engine = engine(TrackpadSettings(threeFingerDrag: true))
        var events = process(engine, frame(1_000 * ms, [(1, .began, 28, 50), (2, .began, 32, 50), (3, .began, 36, 50)]))
        events += process(engine, frame(1_050 * ms, [(1, .moved, 34, 50), (2, .moved, 38, 50), (3, .moved, 42, 50)]))
        events += process(engine, frame(1_070 * ms, [(1, .ended, 34, 50), (2, .moved, 40, 50), (3, .moved, 44, 50)]))
        events += process(engine, frame(1_090 * ms, [(2, .ended, 42, 50), (3, .moved, 48, 50)]))
        events += process(engine, frame(1_110 * ms, [(3, .ended, 48, 50)]))
        var buffer = EventBuffer(); engine.tick(now: 1_500 * ms, into: &buffer); events += buffer.events
        XCTAssertFalse(hasScroll(events), "\(events)")
        XCTAssertEqual(events.filter { if case .button = $0 { return true } else { return false } },
                       [.button(kind: .left, phase: .down, clickCount: 1), .button(kind: .left, phase: .up, clickCount: 1)])
    }

    // MARK: Two-finger edge swipe and tap negatives (§6.5.5, §6.5.7)

    func testEdgeSwipeNeedsTheEdgeAndThePreference() {
        let phone = EngineGeometry(widthMM: 65, heightMM: 141, isLandscape: false)
        func swipe(_ settings: TrackpadSettings, startX: Float) -> [GestureEvent] {
            let engine = self.engine(settings, geometry: phone)
            var events = process(engine, frame(0, [(1, .began, startX, 60), (2, .began, startX, 75)]))
            for step in 1...4 {
                let x = startX - Float(3 * step)
                events += process(engine, frame(UInt64(step) * 10 * ms, [(1, .moved, x, 60), (2, .moved, x, 75)]))
            }
            return events
        }
        XCTAssertTrue(swipe(TrackpadSettings(), startX: 63.5).contains(.notificationCenter))
        let notAtEdge = swipe(TrackpadSettings(), startX: 50)
        XCTAssertFalse(notAtEdge.contains(.notificationCenter))
        XCTAssertTrue(hasScroll(notAtEdge.filter { if case let .scroll(_, _, phase, _) = $0 { return phase == .began } else { return false } }))
        let disabled = swipe(TrackpadSettings(notificationCenterEdgeGesture: 0), startX: 63.5)
        XCTAssertFalse(disabled.contains(.notificationCenter))
    }

    func testTwoFingerTapWithTooMuchStaggerIsNotASecondaryClick() {
        let engine = engine(TrackpadSettings(smartZoomEnabled: false), geometry: EngineGeometry(widthMM: 65, heightMM: 141, isLandscape: false))
        var events = process(engine, frame(0, [(1, .began, 30, 60)]))
        events += process(engine, frame(120 * ms, [(1, .stationary, 30, 60), (2, .began, 42, 60)]))   // 120 ms > 100 ms
        events += process(engine, frame(180 * ms, [(1, .ended, 30, 60), (2, .ended, 42, 60)]))
        XCTAssertFalse(events.contains(.button(kind: .right, phase: .down, clickCount: 1)), "\(events)")
    }

    func testSecondTapFartherThanTheSpreadIsAFreshClick() {
        let engine = engine(TrackpadSettings(), geometry: EngineGeometry(widthMM: 65, heightMM: 141, isLandscape: false))
        process(engine, frame(0, [(1, .began, 30, 60)]))
        let first = process(engine, frame(60 * ms, [(1, .ended, 30, 60)]))
        process(engine, frame(200 * ms, [(2, .began, 38, 60)]))   // 8 mm away (> MULTI_TAP_SPREAD 5 mm)
        let second = process(engine, frame(260 * ms, [(2, .ended, 38, 60)]))
        XCTAssertTrue(first.contains(.button(kind: .left, phase: .down, clickCount: 1)))
        XCTAssertTrue(second.contains(.button(kind: .left, phase: .down, clickCount: 1)), "\(second)")
        XCTAssertFalse(second.contains(.button(kind: .left, phase: .down, clickCount: 2)))
    }
}
