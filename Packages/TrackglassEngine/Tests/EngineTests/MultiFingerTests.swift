import XCTest
@testable import TrackglassEngine

final class MultiFingerTests: XCTestCase {
    func testReverseLastThreeMovementsCancelsDockSwipe() {
        var recognizer = MultiFingerRecognizer(), events = EventBuffer()
        recognizer.begin(fingers: 3, sample: .init(x: 0, y: 0, radius: 20))
        for x in [60.0, 55, 50, 45] {
            recognizer.update(.init(x: x, y: 0, radius: 20), settings: TrackpadSettings(), into: &events)
        }
        events.clear(); recognizer.end(cancelled: false, into: &events)
        XCTAssertEqual(events.events, [.dockSwipe(kind: .horizontal, progressDelta: 0, phase: .cancelled, exitVelocity: 5.0 / 110 * 100)])
    }

    func testAxisLockAndDisabledDockGesture() {
        var recognizer = MultiFingerRecognizer(), events = EventBuffer()
        recognizer.begin(fingers: 4, sample: .init(x: 0, y: 0, radius: 20))
        recognizer.update(.init(x: 8, y: 1, radius: 20), settings: TrackpadSettings(), into: &events)
        recognizer.update(.init(x: 9, y: 80, radius: 20), settings: TrackpadSettings(), into: &events)
        for event in events.events {
            guard case let .dockSwipe(kind, _, _, _) = event else { return XCTFail("Expected dock event") }
            XCTAssertEqual(kind, .horizontal)
        }
        recognizer.begin(fingers: 4, sample: .init(x: 0, y: 0, radius: 20)); events.clear()
        recognizer.update(.init(x: 0, y: -20, radius: 20), settings: TrackpadSettings(missionControlEnabled: false), into: &events)
        XCTAssertTrue(events.events.isEmpty)
    }
}
