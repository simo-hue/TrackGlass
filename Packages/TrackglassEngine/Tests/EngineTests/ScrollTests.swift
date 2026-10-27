import XCTest
import TrackglassKit
@testable import TrackglassEngine

final class ScrollTests: XCTestCase {
    func testThresholdNaturalDirectionAndActivatedScrollDoesNotClick() {
        for natural in [true, false] {
            let engine = makeEngine(TrackpadSettings(naturalScrolling: natural))
            var events = EventBuffer()
            engine.process(frame(0, .began, y: 20), into: &events)
            engine.process(frame(10, .moved, y: 21.5), into: &events)
            XCTAssertEqual(events.count, 1, "Activation must exceed 1.5 mm")
            engine.process(frame(20, .moved, y: 21.75), into: &events)
            engine.process(frame(30, .ended, y: 21.75), into: &events)
            XCTAssertEqual(events.events, [
                .scroll(dxPoints: 0, dyPoints: 0, phase: .mayBegin, naturalInverted: natural),
                .scroll(dxPoints: 0, dyPoints: natural ? 0.25 : -0.25, phase: .began, naturalInverted: natural),
                .scroll(dxPoints: 0, dyPoints: 0, phase: .ended, naturalInverted: natural)
            ])
        }
    }

    func testDisabledScrollAndGeometryCancellation() {
        let disabled = makeEngine(TrackpadSettings(scrollEnabled: false))
        var events = EventBuffer()
        disabled.process(frame(0, .began, y: 20), into: &events)
        disabled.process(frame(20, .moved, y: 30), into: &events)
        disabled.process(frame(40, .ended, y: 30), into: &events)
        XCTAssertEqual(events.events, [
            .scroll(dxPoints: 0, dyPoints: 0, phase: .mayBegin, naturalInverted: true),
            .scroll(dxPoints: 0, dyPoints: 0, phase: .cancelled, naturalInverted: true)
        ])
        let enabled = makeEngine(TrackpadSettings())
        events.clear()
        enabled.process(frame(0, .began, y: 20), into: &events)
        enabled.process(frame(20, .moved, y: 30), into: &events)
        enabled.setGeometry(EngineGeometry(widthMM: 141, heightMM: 65, isLandscape: true), into: &events)
        XCTAssertEqual(events.events.last,
            .scroll(dxPoints: 0, dyPoints: 0, phase: .cancelled, naturalInverted: true))
        XCTAssertFalse(enabled.hasActiveContacts)
        XCTAssertFalse(enabled.needsTick)
    }

    private func makeEngine(_ settings: TrackpadSettings) -> GestureEngine {
        GestureEngine(settings: settings, geometry: EngineGeometry(widthMM: 65, heightMM: 141, isLandscape: false),
            acceleration: UnitGainAcceleration(), scrollAcceleration: UnitGainAcceleration())
    }

    private func frame(_ ms: UInt64, _ phase: Contact.Phase, y: Float) -> TouchFrame {
        var frame = TouchFrame(sequence: UInt32(ms), frameTime: ms * 1_000_000)
        frame.append(Contact(contactID: 1, phase: phase, x: 20, y: y))
        frame.append(Contact(contactID: 2, phase: phase, x: 30, y: y))
        return frame
    }
}
