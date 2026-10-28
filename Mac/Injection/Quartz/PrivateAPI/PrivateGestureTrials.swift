import CoreGraphics
import Foundation

/// Gates G-NC and G-FORCE (SPEC §6.9.5, §6.9.6; PLAN M7.6, M7.7). The private primary paths are built here but
/// stay off: the shipped behaviour is the AX Clock action and the click + Look Up fallback until a physical
/// test says otherwise. The owner runs one gate with
///   `defaults write app.trackglass.mac TGTryPrivateNotificationCenter -bool YES`   (G-NC)
///   `defaults write app.trackglass.mac TGTryPrivateForceClick -bool YES`           (G-FORCE)
/// A trial replaces its fallback entirely, so what the Mac does (or does not do) is the gate result.
///
/// `TGTryLegacyDockSwipes` (owner decision 2026-10-28): on macOS 27+, where the attached-HID-event Dock path has no
/// exported symbol on the reference Mac (M7.3/M7.4), post the macOS 14–26 legacy-field events instead of the keyboard
/// fallback, to test whether live-tracking Spaces / Mission Control still work there:
///   `defaults write app.trackglass.mac TGTryLegacyDockSwipes -bool YES`
struct PrivateGestureTrials: Equatable, Sendable {
    static let notificationCenterKey = "TGTryPrivateNotificationCenter"
    static let forceClickKey = "TGTryPrivateForceClick"
    static let legacyDockSwipesKey = "TGTryLegacyDockSwipes"
    var notificationCenter = false
    var forceClick = false
    var legacyDockSwipes = false
    static var fromDefaults: Self {
        let defaults = UserDefaults.standard
        return Self(notificationCenter: defaults.bool(forKey: notificationCenterKey),
                    forceClick: defaults.bool(forKey: forceClickKey),
                    legacyDockSwipes: defaults.bool(forKey: legacyDockSwipesKey))
    }
}

/// Notification Center as the real driver signals it: a FluidTouchGesture (type 27) from the right edge with the
/// NotificationCenterPrimary flavor, began → changed → ended with progress 0 → 1 → 1 (§6.9.5).
enum FluidGestureEventFactory {
    private static let phases: [(phase: Int64, progress: Double)] =
        [(Int64(TGPhaseBegan), 0), (Int64(TGPhaseChanged), 1), (Int64(TGPhaseEnded), 1)]

    /// Legacy-field attempt (no HID attachment): type 29, field 110 = 27, the swipe-family slots for motion and
    /// progress and the phase in both phase slots. The slot mapping is the Dock path's; type 27 is unverified.
    static func notificationCenterSequence(source: CGEventSource?, location: CGPoint) -> [CGEvent]? {
        var events: [CGEvent] = []
        events.reserveCapacity(phases.count)
        for step in phases {
            guard let event = CGEvent(source: source) else { return nil }
            event.type = TGEventTypeGesture; event.location = location
            event.setIntegerValueField(TGFieldEventType, value: Int64(TGEventTypeGesture.rawValue))
            event.setIntegerValueField(TGFieldHIDEventType, value: Int64(TGHIDFluidTouchGesture))
            event.setIntegerValueField(TGFieldGesturePhase, value: step.phase)
            event.setIntegerValueField(TGFieldDockPhase, value: step.phase)
            event.setIntegerValueField(TGFieldSwipeMask, value: 0)
            event.setIntegerValueField(TGFieldSwipeMotion, value: Int64(TGHIDGestureMotionFromRightEdge))
            event.setDoubleValueField(TGFieldSwipeProgress, value: step.progress)
            events.append(event)
        }
        return events
    }

    /// Attached-HID-event attempt (macOS with the HIDEvent class and an attachment symbol): one type-29 carrier per
    /// phase with a type-27 HIDEvent attached. `nil` when the mechanism is unavailable or attachment fails.
    static func attachedNotificationCenterSequence(source: CGEventSource?, location: CGPoint,
                                                   attach: (CGEvent, Any) -> Bool = { TGAttachHIDEvent($0, $1 as AnyObject) }) -> [CGEvent]? {
        var events: [CGEvent] = []
        events.reserveCapacity(phases.count)
        for step in phases {
            guard let hid = TGCreateFluidTouchHIDEvent(Int64(TGHIDGestureMotionFromRightEdge),
                                                       Int64(TGHIDGestureFlavorNotificationCenterPrimary),
                                                       step.phase, step.progress),
                  let event = CGEvent(source: source) else { return nil }
            event.type = TGEventTypeGesture; event.location = location
            event.setIntegerValueField(TGFieldEventType, value: Int64(TGEventTypeGesture.rawValue))
            guard attach(event, hid) else { return nil }
            events.append(event)
        }
        return events
    }
}

/// Force click as a Force (type 32) HID event attached to a type-29 carrier (§6.9.6): stage 1 at pressure 0.5,
/// stage 2 at pressure 1.0 forty milliseconds later, then stage 0. The injector spaces the three posts with its tick.
enum ForceEventFactory {
    struct Step: Equatable, Sendable {
        let stage: Int64
        let pressure: Double
        let delayNs: UInt64
    }
    static let steps: [Step] = [Step(stage: 1, pressure: 0.5, delayNs: 0),
                                Step(stage: 2, pressure: 1.0, delayNs: 40_000_000),
                                Step(stage: 0, pressure: 0.0, delayNs: 80_000_000)]

    static func attachedEvent(_ step: Step, source: CGEventSource?, location: CGPoint,
                              attach: (CGEvent, Any) -> Bool = { TGAttachHIDEvent($0, $1 as AnyObject) }) -> CGEvent? {
        guard let hid = TGCreateForceHIDEvent(step.stage, step.pressure, step.pressure),
              let event = CGEvent(source: source) else { return nil }
        event.type = TGEventTypeGesture; event.location = location
        event.setIntegerValueField(TGFieldEventType, value: Int64(TGEventTypeGesture.rawValue))
        guard attach(event, hid) else { return nil }
        return event
    }
}
