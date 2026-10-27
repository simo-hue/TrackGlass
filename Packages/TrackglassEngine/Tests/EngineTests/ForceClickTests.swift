import XCTest
import TrackglassKit
@testable import TrackglassEngine

final class ForceClickTests: XCTestCase {
    func testHoldFiresOnceAndConsumesLift() {
        let engine = GestureEngine(geometry: .init(widthMM: 65, heightMM: 140, isLandscape: false))
        var events = EventBuffer()
        send(engine, time: 0, phase: .began, into: &events)
        engine.tick(now: 599_000_000, into: &events); XCTAssertTrue(events.events.isEmpty)
        engine.tick(now: 600_000_000, into: &events)
        XCTAssertEqual(events.events, [.forceClick(stage: 2), .haptic(.forceClickStage2)])
        events.clear(); engine.tick(now: 900_000_000, into: &events)
        send(engine, time: 950_000_000, phase: .ended, into: &events)
        XCTAssertTrue(events.events.isEmpty)
    }
    func testMovementAndDisabledPreferencePreventHold() {
        for enabled in [false, true] {
            let engine = GestureEngine(settings: TrackpadSettings(forceClickEnabled: enabled),
                geometry: .init(widthMM: 65, heightMM: 140, isLandscape: false))
            var events = EventBuffer()
            send(engine, time: 0, phase: .began, into: &events)
            if enabled { send(engine, time: 100_000_000, phase: .moved, x: 22, into: &events) }
            events.clear(); engine.tick(now: 700_000_000, into: &events)
            XCTAssertTrue(events.events.isEmpty)
        }
    }
    private func send(_ engine: GestureEngine, time: UInt64, phase: Contact.Phase, x: Float = 20, into events: inout EventBuffer) {
        var frame = TouchFrame(frameTime: time)
        frame.append(Contact(contactID: 1, phase: phase, x: x, y: 40))
        engine.process(frame, into: &events)
    }
}
