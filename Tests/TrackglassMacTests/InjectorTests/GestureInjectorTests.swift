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
    func testForceFallbackOnlyLooksUpAndNeverClicks() {
        // H3 (§6.9.6, owner decision 2026-10-31): a finger resting still for 0.6 s must never click whatever is under
        // the pointer. The fallback is the Look Up keystroke alone (Ctrl+Cmd+D, as for the three-finger tap), at once.
        var mouse: [CGEvent] = [], keys: [CGEvent] = []
        let injector = QuartzInjector(postScrollEvent: { mouse.append($0) }, capabilities: PrivateAPICapabilities(),
            postKeyEvent: { keys.append($0) }, postPointerEvent: { mouse.append($0) })
        injector.inject(.forceClick(stage: 2))
        XCTAssertTrue(mouse.isEmpty, "no button event")
        XCTAssertEqual(keys.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(keys.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [2, 2])
        XCTAssertEqual(keys.first?.flags, [.maskControl, .maskCommand])
        XCTAssertFalse(injector.needsTick, "nothing is scheduled")
        injector.tick(); injector.flush()
        XCTAssertEqual(keys.count, 2); XCTAssertTrue(mouse.isEmpty)
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
    func testForceTrialWithoutAttachmentFallsBackToLookUpOnly() {
        var mouse: [CGEvent] = [], keys: [CGEvent] = []
        let injector = QuartzInjector(postScrollEvent: { mouse.append($0) }, capabilities: PrivateAPICapabilities(),
            trials: PrivateGestureTrials(notificationCenter: false, forceClick: true),
            postKeyEvent: { keys.append($0) })
        injector.inject(.forceClick(stage: 2))
        XCTAssertTrue(mouse.isEmpty)
        XCTAssertEqual(keys.count, 2); XCTAssertFalse(injector.needsTick)
    }
    func testNotificationCenterClockIsFoundByIdentifierInAnyLanguage() {
        // M16 (§6.9.5): the identifier is stable; the description is localized ("Uhr" on a German Mac).
        let identifiers: [String?] = ["com.apple.menuextra.battery", "com.apple.menuextra.wifi", "com.apple.menuextra.clock"]
        let german: [String?] = ["Batterie", "WLAN", "Uhr"]
        XCTAssertEqual(NotificationCenterAction.clockIndex(count: 3, identifier: { identifiers[$0] }, description: { german[$0] }), 2)
        // Identifier first: a third-party item described as "Clock" does not win over the system clock.
        let english: [String?] = ["Clock", "Wi-Fi", "Clock"]
        XCTAssertEqual(NotificationCenterAction.clockIndex(count: 3, identifier: { identifiers[$0] }, description: { english[$0] }), 2)
        // No identifiers (an older macOS): the English description is the fallback.
        XCTAssertEqual(NotificationCenterAction.clockIndex(count: 3, identifier: { _ in nil }, description: { english[$0] }), 0)
        XCTAssertNil(NotificationCenterAction.clockIndex(count: 3, identifier: { _ in nil }, description: { german[$0] }))
        // Descriptions are only asked when no identifier matched.
        var descriptionsAsked = 0
        _ = NotificationCenterAction.clockIndex(count: 3, identifier: { identifiers[$0] },
                                                description: { descriptionsAsked += 1; return german[$0] })
        XCTAssertEqual(descriptionsAsked, 0)
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
        // The left button goes down before stage 1 and up after the release stage (F12, 2026-10-29).
        XCTAssertEqual(posted.map(\.type), [.leftMouseDown, TGEventTypeGesture]); XCTAssertTrue(injector.needsTick)
        time = 39_000_000; injector.tick(); XCTAssertEqual(posted.count, 2)
        time = 40_000_000; injector.tick(); XCTAssertEqual(posted.count, 3)
        time = 80_000_000; injector.tick()
        XCTAssertEqual(posted.map(\.type), [.leftMouseDown, TGEventTypeGesture, TGEventTypeGesture, TGEventTypeGesture, .leftMouseUp])
        XCTAssertFalse(injector.needsTick)
    }
    func testInterruptedForceTrialStillReleasesTheStageAndTheButton() throws {
        guard TGPrivateAPIGetCapabilities().dockSwipe else { throw XCTSkip("HIDEvent attachment is unavailable on this OS") }
        var time: UInt64 = 0
        var posted: [CGEvent] = []
        var caps = PrivateAPICapabilities(); caps.gestureEvents = true; caps.dockSwipe = true
        let injector = QuartzInjector(postScrollEvent: { posted.append($0) }, capabilities: caps,
            trials: PrivateGestureTrials(notificationCenter: false, forceClick: true), postKeyEvent: { _ in }, now: { time })
        injector.inject(.forceClick(stage: 2))
        time = 10_000_000; injector.flush()   // the session ends before stage 2
        XCTAssertEqual(posted.map(\.type), [.leftMouseDown, TGEventTypeGesture, TGEventTypeGesture, .leftMouseUp])
        XCTAssertFalse(injector.needsTick)
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
