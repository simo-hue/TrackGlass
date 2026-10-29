import XCTest
@testable import TrackglassEngine

final class MultiFingerTests: XCTestCase {
    func testReverseLastThreeMovementsCancelsDockSwipe() {
        var recognizer = MultiFingerRecognizer(), events = EventBuffer()
        recognizer.begin(fingers: 3, sample: .init(x: 0, y: 0, radius: 20), time: 0)
        for (step, x) in [60.0, 55, 50, 45].enumerated() {
            recognizer.update(.init(x: x, y: 0, radius: 20), time: UInt64(step + 1) * 10_000_000,
                              settings: TrackpadSettings(), into: &events)
        }
        events.clear(); recognizer.end(cancelled: false, into: &events)
        // Exit velocity: the progress of the 40 ms the gesture lasted (−60 + 3 × 5 mm) ÷ 0.04 s (§6.5.8).
        XCTAssertTrue(GestureEvent.approximatelyEqual(events.events,
            [.dockSwipe(kind: .horizontal, progressDelta: 0, phase: .cancelled, exitVelocity: -45.0 / 110 / 0.04)]), "\(events.events)")
    }

    func testAxisLockAndDisabledDockGesture() {
        var recognizer = MultiFingerRecognizer(), events = EventBuffer()
        recognizer.begin(fingers: 4, sample: .init(x: 0, y: 0, radius: 20), time: 0)
        recognizer.update(.init(x: 8, y: 1, radius: 20), time: 10_000_000, settings: TrackpadSettings(), into: &events)
        recognizer.update(.init(x: 9, y: 80, radius: 20), time: 20_000_000, settings: TrackpadSettings(), into: &events)
        for event in events.events {
            guard case let .dockSwipe(kind, _, _, _) = event else { return XCTFail("Expected dock event") }
            XCTAssertEqual(kind, .horizontal)
        }
        recognizer.begin(fingers: 4, sample: .init(x: 0, y: 0, radius: 20), time: 0); events.clear()
        recognizer.update(.init(x: 0, y: -20, radius: 20), time: 10_000_000,
                          settings: TrackpadSettings(missionControlEnabled: false), into: &events)
        XCTAssertTrue(events.events.isEmpty)
    }
}
