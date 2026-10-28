import ApplicationServices
import CoreGraphics
import XCTest
import TrackglassEngine
@testable import TrackglassMac

/// SPEC §10.1: a listen-only `CGEventTap` in the host process captures what `QuartzInjector` really posts, so the
/// fields are proven to survive a post through the window server (the other injector tests intercept before posting).
/// Only side-effect-free events are posted: a zero-delta scroll mayBegin → cancelled pair and an empty gesture bracket.
/// Needs Accessibility (posting) and listen-event access (the tap); the app requests neither for the latter (§6.2),
/// so this skips unless the owner granted Input Monitoring to the test host by hand.
final class EventTapCaptureTests: XCTestCase {
    private final class Capture {
        var events: [CGEvent] = []
        let marker: Int64
        init(marker: Int64) { self.marker = marker }
    }

    func testPostedScrollAndGestureEventsKeepTheirFields() throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "Accessibility permission is required for injector tests.")
        try XCTSkipUnless(CGPreflightListenEventAccess(), "Listen-event access (Input Monitoring) is required for the capture tap.")
        let marker: Int64 = 0x5447_7461_7000 | Int64.random(in: 1...0xFFF)   // "TGtap" + random: only our own events
        let source = PointerState.sharedEventSource
        let previousUserData = source.userData
        source.userData = marker
        defer { source.userData = previousUserData }

        let capture = Capture(marker: marker)
        let callback: CGEventTapCallBack = { _, _, event, info in
            if let info {
                let capture = Unmanaged<Capture>.fromOpaque(info).takeUnretainedValue()
                if event.getIntegerValueField(.eventSourceUserData) == capture.marker { capture.events.append(event.copy() ?? event) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: CGEventMask.max, callback: callback,
                                          userInfo: Unmanaged.passUnretained(capture).toOpaque()) else {
            throw XCTSkip("The system refused the listen-only event tap.")
        }
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        defer {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CFMachPortInvalidate(tap)
        }

        var full = PrivateAPICapabilities()
        full.gestureEvents = true
        let injector = QuartzInjector(capabilities: full, trials: PrivateGestureTrials())
        injector.inject(.scroll(dxPoints: 0, dyPoints: 0, phase: .mayBegin, naturalInverted: true))
        injector.inject(.scroll(dxPoints: 0, dyPoints: 0, phase: .cancelled, naturalInverted: true))
        injector.inject(.gestureBegin)
        injector.inject(.gestureEnd)
        let deadline = Date().addingTimeInterval(2)
        while capture.events.count < 6, Date() < deadline {
            _ = CFRunLoopRunInMode(.defaultMode, 0.05, false)
        }

        let wheels = capture.events.filter { $0.type == .scrollWheel }
        let gestures = capture.events.filter { $0.type == TGEventTypeGesture }
        XCTAssertEqual(wheels.count, 2, "captured \(capture.events.map(\.type.rawValue))")
        XCTAssertEqual(wheels.map { $0.getIntegerValueField(.scrollWheelEventScrollPhase) },
                       [Int64(TGPhaseMayBegin), Int64(TGPhaseCancelled)])
        for wheel in wheels {
            XCTAssertEqual(wheel.getIntegerValueField(TGFieldEventType), Int64(CGEventType.scrollWheel.rawValue))
            XCTAssertEqual(wheel.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
            XCTAssertEqual(wheel.getIntegerValueField(TGFieldDirectionInvertedFromDevice), 1)
            XCTAssertEqual(wheel.getIntegerValueField(.scrollWheelEventMomentumPhase), 0)
            XCTAssertEqual(wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 0)
        }
        // Two scroll companions (110 = 6) plus the begin/end bracket (110 = 61 / 62).
        XCTAssertEqual(gestures.map { $0.getIntegerValueField(TGFieldHIDEventType) },
                       [Int64(TGHIDScroll), Int64(TGHIDScroll), Int64(TGHIDGestureBegan), Int64(TGHIDGestureEnded)])
        for gesture in gestures { XCTAssertEqual(gesture.getIntegerValueField(TGFieldEventType), Int64(TGEventTypeGesture.rawValue)) }
        XCTAssertEqual(gestures.prefix(2).map { $0.getIntegerValueField(TGFieldGesturePhase) },
                       [Int64(TGPhaseMayBegin), Int64(TGPhaseCancelled)])
    }
}
