import XCTest
import TrackglassKit
@testable import TrackglassEngine

final class ScrollMomentumTests: XCTestCase {
    func testPreferenceDisablingMomentumStopsOnNextTick() {
        let engine = GestureEngine(geometry: .init(widthMM: 65, heightMM: 141, isLandscape: false),
            scrollAcceleration: UnitGainAcceleration())
        var events = EventBuffer()
        for (ms, phase, y) in [(UInt64(0), Contact.Phase.began, Float(20)), (8, .moved, 28), (16, .ended, 28)] {
            var frame = TouchFrame(sequence: UInt32(ms), frameTime: ms * 1_000_000)
            for id in UInt8(1)...2 { frame.append(Contact(contactID: id, phase: phase, x: Float(id) * 10, y: y)) }
            engine.process(frame, into: &events)
        }
        engine.setSettings(TrackpadSettings(momentumScrollEnabled: false))
        events.clear(); engine.tick(now: 24_000_000, into: &events)
        XCTAssertEqual(events.events, [.scrollMomentum(phase: .end, dxPoints: 0, dyPoints: 0)])
        XCTAssertFalse(engine.needsTick)
    }
    func testFlickDecaysToRestWithinSpecifiedInterval() {
        var momentum = ScrollMomentum(), events = EventBuffer()
        for time in [UInt64(8), 16, 24] { momentum.record(dx: 0, dy: 8, dt: 8_000_000, at: time * 1_000_000) }
        momentum.start(now: 32_000_000, enabled: true)
        var end: UInt64 = 0, previous = Double.infinity
        for ms in stride(from: UInt64(40), through: 4_000, by: 8) {
            events.clear(); momentum.tick(now: ms * 1_000_000, into: &events)
            if events.count > 0, case let .scrollMomentum(phase, _, dy) = events[0] {
                if phase == .end { end = ms; break }
                XCTAssertGreaterThan(dy, 0); XCTAssertLessThan(dy, previous); previous = dy
            }
        }
        XCTAssertGreaterThan(end, 2_000); XCTAssertLessThan(end, 3_000)
        XCTAssertFalse(momentum.active)
    }

    func testStaleSlowAndDisabledSamplesDoNotStartMomentum() {
        for (dy, now, enabled) in [(8.0, UInt64(100_000_000), true), (0.1, 16_000_000, true), (8, 16_000_000, false)] {
            var momentum = ScrollMomentum()
            momentum.record(dx: 0, dy: dy, dt: 8_000_000, at: 8_000_000)
            momentum.start(now: now, enabled: enabled)
            XCTAssertFalse(momentum.active)
        }
    }

    func testSyntheticLiftoffPreservesCoastingButDisconnectEndsIt() {
        let engine = GestureEngine(geometry: .init(widthMM: 65, heightMM: 141, isLandscape: false),
            acceleration: UnitGainAcceleration(), scrollAcceleration: UnitGainAcceleration())
        var events = EventBuffer()
        for (ms, phase, y) in [(UInt64(0), Contact.Phase.began, Float(20)), (8, .moved, 28), (16, .ended, 28)] {
            var frame = TouchFrame(sequence: UInt32(ms), frameTime: ms * 1_000_000)
            frame.append(Contact(contactID: 1, phase: phase, x: 20, y: y))
            frame.append(Contact(contactID: 2, phase: phase, x: 30, y: y))
            engine.process(frame, into: &events)
        }
        var lift = TouchFrame(sequence: 17, frameTime: 17_000_000)
        lift.isSyntheticLiftoff = true
        engine.process(lift, into: &events)
        XCTAssertTrue(engine.needsTick)
        events.clear(); engine.tick(now: 24_000_000, into: &events)
        XCTAssertEqual(events.events, [.scrollMomentum(phase: .begin, dxPoints: 0, dyPoints: 8)])
        events.clear(); engine.forceLiftoff(into: &events)
        XCTAssertEqual(events.events, [.scrollMomentum(phase: .end, dxPoints: 0, dyPoints: 0)])
        XCTAssertFalse(engine.needsTick)
    }
}
