import XCTest
import TrackglassKit
@testable import TrackglassEngine

final class SmartZoomTests: XCTestCase {
    func testDisconnectDiscardsPendingSecondaryClick() {
        let engine = GestureEngine(geometry: .init(widthMM: 65, heightMM: 141, isLandscape: false))
        var events = EventBuffer()
        tap(engine, start: 0, into: &events)
        XCTAssertTrue(engine.needsTick)
        events.clear(); engine.forceLiftoff(into: &events)
        engine.tick(now: 1_000_000_000, into: &events)
        XCTAssertTrue(events.events.isEmpty)
        XCTAssertFalse(engine.needsTick)
    }

    func testSmartZoomWorksWhenSecondaryClickIsDisabled() {
        let engine = GestureEngine(settings: TrackpadSettings(trackpadRightClick: false),
            geometry: .init(widthMM: 65, heightMM: 141, isLandscape: false))
        var events = EventBuffer()
        tap(engine, start: 0, into: &events); tap(engine, start: 150_000_000, into: &events)
        XCTAssertEqual(events.events.filter { $0 == .smartZoom }.count, 1)
        XCTAssertFalse(events.events.contains { if case .button = $0 { return true }; return false })
        events.clear(); engine.tick(now: 1_000_000_000, into: &events)
        XCTAssertTrue(events.events.isEmpty)
    }

    private func tap(_ engine: GestureEngine, start: UInt64, into events: inout EventBuffer) {
        for (offset, phase) in [(UInt64(0), Contact.Phase.began), (50_000_000, .ended)] {
            var frame = TouchFrame(frameTime: start + offset)
            for id in UInt8(1)...2 { frame.append(Contact(contactID: id, phase: phase, x: Float(id) * 10, y: 40)) }
            engine.process(frame, into: &events)
        }
    }
}
