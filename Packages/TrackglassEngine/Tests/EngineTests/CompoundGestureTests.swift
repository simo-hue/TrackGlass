import XCTest
@testable import TrackglassEngine

final class CompoundGestureTests: XCTestCase {
    func testConcurrentPinchRotateAndCancellation() {
        var recognizer = TwoFingerRecognizer(), events = EventBuffer()
        recognizer.begin(x: 30, y: 40, distance: 20, angle: 0, time: 0)
        recognizer.update(x: 30, y: 44, distance: 28, angle: .pi / 2, time: 20_000_000,
            settings: TrackpadSettings(), acceleration: UnitGainAcceleration(), into: &events)
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0], .scroll(dxPoints: 0, dyPoints: 4, phase: .began, naturalInverted: true))
        XCTAssertEqual(events[1], .gestureBegin)
        XCTAssertEqual(events[2], .magnify(delta: 28.0 / 20 - 1, phase: .began))
        XCTAssertEqual(events[3], .rotate(deltaDegrees: 90, phase: .began))
        events.clear(); recognizer.end(cancelled: true, natural: true, into: &events)
        XCTAssertEqual(events.events, [.scroll(dxPoints: 0, dyPoints: 0, phase: .cancelled, naturalInverted: true),
            .magnify(delta: 0, phase: .cancelled), .rotate(deltaDegrees: 0, phase: .cancelled), .gestureEnd])
    }

    func testRotateNeedsTheMinimumSpreadToStartButNotToContinue() {
        // §6.5.7 / Appendix A ROTATE_MIN_SPREAD: below 15 mm a rotation never activates…
        var recognizer = TwoFingerRecognizer(), events = EventBuffer()
        recognizer.begin(x: 0, y: 0, distance: 12, angle: 0, time: 0)
        recognizer.update(x: 0, y: 0, distance: 12, angle: 30 * .pi / 180, time: 20_000_000,
            settings: TrackpadSettings(), acceleration: UnitGainAcceleration(), into: &events)
        XCTAssertEqual(events.count, 0, "12 mm apart: no rotation however far the angle turns")
        // …once active it keeps reporting even when the fingers close up (stays active until lift).
        recognizer.begin(x: 0, y: 0, distance: 20, angle: 0, time: 0)
        recognizer.update(x: 0, y: 0, distance: 20, angle: 10 * .pi / 180, time: 20_000_000,
            settings: TrackpadSettings(), acceleration: UnitGainAcceleration(), into: &events)
        XCTAssertEqual(events.events, [.gestureBegin, .rotate(deltaDegrees: 10, phase: .began)])
        events.clear()
        recognizer.update(x: 0, y: 0, distance: 10, angle: 15 * .pi / 180, time: 40_000_000,
            settings: TrackpadSettings(pinchEnabled: false), acceleration: UnitGainAcceleration(), into: &events)
        XCTAssertTrue(GestureEvent.approximatelyEqual(events.events, [.rotate(deltaDegrees: 5, phase: .changed)]), "\(events.events)")
        events.clear(); recognizer.end(cancelled: false, natural: true, into: &events)
        XCTAssertEqual(events.events, [.scroll(dxPoints: 0, dyPoints: 0, phase: .cancelled, naturalInverted: true),
            .rotate(deltaDegrees: 0, phase: .ended), .gestureEnd])
    }

    func testDisabledGesturesAndAngleWrap() {
        var recognizer = TwoFingerRecognizer(), events = EventBuffer()
        recognizer.begin(x: 0, y: 0, distance: 20, angle: 179 * .pi / 180, time: 0)
        recognizer.update(x: 0, y: 0, distance: 20, angle: -179 * .pi / 180, time: 20_000_000,
            settings: TrackpadSettings(), acceleration: UnitGainAcceleration(), into: &events)
        XCTAssertEqual(events.count, 0, "Crossing the angle branch cut is only two degrees")
        recognizer.update(x: 0, y: 0, distance: 30, angle: 0, time: 40_000_000,
            settings: TrackpadSettings(pinchEnabled: false, rotateEnabled: false),
            acceleration: UnitGainAcceleration(), into: &events)
        XCTAssertEqual(events.count, 0)
    }
}
