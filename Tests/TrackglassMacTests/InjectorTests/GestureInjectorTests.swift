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
    func testNotificationCenterTrialPostsTheLegacyFluidGestureSequence() throws {
        var captured: [CGEvent] = []
        var caps = PrivateAPICapabilities(); caps.gestureEvents = true
        let injector = QuartzInjector(postScrollEvent: { captured.append($0) }, dockPath: .legacyFields, capabilities: caps,
                                      trials: PrivateGestureTrials(notificationCenter: true, forceClick: false))
        injector.inject(.notificationCenter)
        XCTAssertEqual(captured.count, 3)
        let phases = [TGPhaseBegan, TGPhaseChanged, TGPhaseEnded]
        for (index, event) in captured.enumerated() {
            XCTAssertEqual(event.type, TGEventTypeGesture)
            XCTAssertEqual(event.getIntegerValueField(TGFieldEventType), Int64(TGEventTypeGesture.rawValue))
            XCTAssertEqual(event.getIntegerValueField(TGFieldHIDEventType), Int64(TGHIDFluidTouchGesture))
            XCTAssertEqual(event.getIntegerValueField(TGFieldGesturePhase), Int64(phases[index]))
            XCTAssertEqual(event.getIntegerValueField(TGFieldDockPhase), Int64(phases[index]))
            XCTAssertEqual(event.getIntegerValueField(TGFieldSwipeMotion), Int64(TGHIDGestureMotionFromRightEdge))
            XCTAssertEqual(event.getIntegerValueField(TGFieldSwipeMask), 0)
        }
        XCTAssertEqual(captured.map { $0.getDoubleValueField(TGFieldSwipeProgress) }, [0, 1, 1])
    }
    func testAttachedFluidSequenceCarriesOneHIDEventPerPhase() throws {
        guard TGPrivateAPIGetCapabilities().hidEventClass else { throw XCTSkip("HIDEvent is unavailable on this OS") }
        var attached = 0
        let events = try XCTUnwrap(FluidGestureEventFactory.attachedNotificationCenterSequence(source: nil, location: .zero,
            attach: { event, hid in
                attached += 1
                XCTAssertEqual(event.type, TGEventTypeGesture)
                XCTAssertTrue((hid as AnyObject) is NSObject)
                return true
            }))
        XCTAssertEqual(events.count, 3); XCTAssertEqual(attached, 3)
        XCTAssertNil(FluidGestureEventFactory.attachedNotificationCenterSequence(source: nil, location: .zero, attach: { _, _ in false }))
    }
    func testForceTrialWithoutAttachmentFallsBackToClickAndLookUp() {
        var time: UInt64 = 0
        var mouse: [CGEvent] = [], keys: [CGEvent] = []
        let injector = QuartzInjector(postScrollEvent: { mouse.append($0) }, capabilities: PrivateAPICapabilities(),
            trials: PrivateGestureTrials(notificationCenter: false, forceClick: true),
            postKeyEvent: { keys.append($0) }, now: { time })
        injector.inject(.forceClick(stage: 2))
        XCTAssertEqual(mouse.map(\.type), [.leftMouseDown, .leftMouseUp])
        time = 30_000_000; injector.tick()
        XCTAssertEqual(keys.count, 2); XCTAssertFalse(injector.needsTick)
    }
    func testForceTrialPostsStagesAtFortyMillisecondSpacing() throws {
        guard TGPrivateAPIGetCapabilities().dockSwipe else { throw XCTSkip("HIDEvent attachment is unavailable on this OS") }
        var time: UInt64 = 0
        var posted: [CGEvent] = []
        var caps = PrivateAPICapabilities(); caps.gestureEvents = true; caps.dockSwipe = true
        let injector = QuartzInjector(postScrollEvent: { posted.append($0) }, capabilities: caps,
            trials: PrivateGestureTrials(notificationCenter: false, forceClick: true),
            postKeyEvent: { _ in XCTFail("Keyboard fallback used during the trial") }, now: { time })
        injector.inject(.forceClick(stage: 2))
        XCTAssertEqual(posted.count, 1); XCTAssertTrue(injector.needsTick)
        time = 39_000_000; injector.tick(); XCTAssertEqual(posted.count, 1)
        time = 40_000_000; injector.tick(); XCTAssertEqual(posted.count, 2)
        time = 80_000_000; injector.tick(); XCTAssertEqual(posted.count, 3)
        XCTAssertFalse(injector.needsTick)
        XCTAssertTrue(posted.allSatisfy { $0.type == TGEventTypeGesture })
    }
    func testForceStepsFollowTheSpecifiedStagesAndPressures() throws {
        XCTAssertEqual(ForceEventFactory.steps.map(\.stage), [1, 2, 0])
        XCTAssertEqual(ForceEventFactory.steps.map(\.pressure), [0.5, 1.0, 0.0])
        XCTAssertEqual(ForceEventFactory.steps.map(\.delayNs), [0, 40_000_000, 80_000_000])
        guard TGPrivateAPIGetCapabilities().hidEventClass else { throw XCTSkip("HIDEvent is unavailable on this OS") }
        var attached = false
        let event = ForceEventFactory.attachedEvent(ForceEventFactory.steps[1], source: nil, location: .zero,
                                                    attach: { _, hid in attached = (hid as AnyObject) is NSObject; return true })
        XCTAssertNotNil(event); XCTAssertTrue(attached)
        XCTAssertNil(ForceEventFactory.attachedEvent(ForceEventFactory.steps[1], source: nil, location: .zero, attach: { _, _ in false }))
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
