import CoreGraphics
import TrackglassEngine
import XCTest
@testable import TrackglassMac

final class GestureInjectorTests: XCTestCase {
    func testNavigationEndsWithClearedDirection() throws {
        var captured: [CGEvent] = []
        let injector = QuartzInjector(postScrollEvent: { captured.append($0) })
        injector.inject(.navigationSwipe(direction: .left))
        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured[0].getIntegerValueField(TGFieldSwipeMask), Int64(TGSwipeLeft))
        XCTAssertEqual(captured[1].getIntegerValueField(TGFieldSwipeMask), 0)
        XCTAssertEqual(captured[0].getIntegerValueField(TGFieldGesturePhase), Int64(TGPhaseBegan))
        XCTAssertEqual(captured[1].getIntegerValueField(TGFieldGesturePhase), Int64(TGPhaseEnded))
    }
    func testForceFallbackClicksThenLooksUpAfterDelay() {
        var time: UInt64 = 0
        var mouse: [CGEvent] = [], keys: [CGEvent] = []
        let injector = QuartzInjector(postScrollEvent: { mouse.append($0) }, capabilities: PrivateAPICapabilities(),
            postKeyEvent: { keys.append($0) }, now: { time })
        injector.inject(.forceClick(stage: 2))
        XCTAssertEqual(mouse.map(\.type), [.leftMouseDown, .leftMouseUp])
        XCTAssertTrue(keys.isEmpty); XCTAssertTrue(injector.needsTick)
        time = 29_000_000; injector.tick(); XCTAssertTrue(keys.isEmpty)
        time = 30_000_000; injector.tick(); XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys.first?.getIntegerValueField(.keyboardEventKeycode), 2)
        XCTAssertEqual(keys.first?.flags, [.maskControl, .maskCommand])
        XCTAssertFalse(injector.needsTick)
    }
    func testSmartZoomIsOneUnphasedZoomToggle() throws {
        var captured: [CGEvent] = []
        let injector = QuartzInjector(postScrollEvent: { captured.append($0) })
        injector.inject(.smartZoom)
        XCTAssertEqual(captured.count, 1)
        let event = try XCTUnwrap(captured.first)
        XCTAssertEqual(event.getIntegerValueField(TGFieldHIDEventType), Int64(TGHIDZoomToggle))
        XCTAssertEqual(event.getIntegerValueField(TGFieldGesturePhase), 0)
    }
    func testCompoundGestureFieldsAndBrackets() throws {
        var captured: [CGEvent] = []
        let injector = QuartzInjector(postScrollEvent: { captured.append($0) })
        for gesture in [GestureEvent.gestureBegin, .magnify(delta: 0.25, phase: .began),
                        .rotate(deltaDegrees: -12, phase: .changed), .magnify(delta: 0, phase: .ended),
                        .rotate(deltaDegrees: 0, phase: .cancelled), .gestureEnd] { injector.inject(gesture) }
        XCTAssertEqual(captured.count, 6)
        let types = [TGHIDGestureBegan, TGHIDZoom, TGHIDRotation, TGHIDZoom, TGHIDRotation, TGHIDGestureEnded]
        for (index, event) in captured.enumerated() {
            XCTAssertEqual(event.type, TGEventTypeGesture)
            XCTAssertEqual(event.getIntegerValueField(TGFieldHIDEventType), Int64(types[index]))
        }
        XCTAssertEqual(captured[1].getDoubleValueField(TGFieldMagnification), 0.25)
        XCTAssertEqual(captured[2].getDoubleValueField(TGFieldRotation), -12)
        for (index, phase) in [(1, TGPhaseBegan), (2, TGPhaseChanged), (3, TGPhaseEnded), (4, TGPhaseCancelled)] {
            XCTAssertEqual(captured[index].getIntegerValueField(TGFieldGesturePhase), Int64(phase))
        }
    }
}
