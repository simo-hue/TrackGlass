import CoreGraphics
import TrackglassEngine

enum DockSwipePath {
    case legacyFields, attachedHIDEvent
    static var current: Self {
        if #available(macOS 27, *) { return .attachedHIDEvent }
        return .legacyFields
    }
}

/// Field facts: SPEC §6.9.4; MMF TouchSimulator.m, checked 2026-10-26.
final class DockSwipeEventFactory {
    private(set) var progress = 0.0
    static func attached(from legacy: CGEvent, attach: (CGEvent, Any) -> Bool = { TGAttachDockHIDEvent($0, $1 as AnyObject) }) -> CGEvent? {
        let progress = legacy.getDoubleValueField(TGFieldDockProgress)
        let inverted = legacy.getIntegerValueField(TGFieldDockInverted) != 0
        guard let hid = TGCreateDockHIDEvent(legacy.getIntegerValueField(TGFieldDockType),
            legacy.getIntegerValueField(TGFieldDockPhase), inverted ? -progress : progress,
            legacy.getDoubleValueField(TGFieldDockExitSpeedX)), let event = CGEvent(source: nil) else { return nil }
        event.type = TGEventTypeDockCompanion; event.location = legacy.location
        guard attach(event, hid) else { return nil }
        return event
    }
    func make(kind: DockSwipeKind, delta: Double, phase: GesturePhase, exitVelocity: Double,
              inverted: Bool, source: CGEventSource?, location: CGPoint) -> (CGEvent, CGEvent)? {
        guard delta.isFinite, exitVelocity.isFinite else { return nil }
        switch phase {
        case .began: progress = delta
        case .changed: progress += delta
        case .ended, .cancelled: break
        case .mayBegin: return nil
        }
        guard let marker = CGEvent(source: source), let event = CGEvent(source: source) else { return nil }
        let kindValue: Int64
        switch kind { case .horizontal: kindValue = 1; case .vertical: kindValue = 2; case .pinch: kindValue = 3 }
        let phaseValue: Int64
        switch phase {
        case .began: phaseValue = Int64(TGPhaseBegan)
        case .changed: phaseValue = Int64(TGPhaseChanged)
        case .ended: phaseValue = Int64(TGPhaseEnded)
        case .cancelled: phaseValue = Int64(TGPhaseCancelled)
        case .mayBegin: return nil
        }
        marker.type = TGEventTypeGesture; marker.location = location
        marker.setIntegerValueField(TGFieldEventType, value: Int64(TGEventTypeGesture.rawValue))
        marker.setIntegerValueField(TGFieldDockMarker, value: TGDockMarkerValue)
        event.type = TGEventTypeDockCompanion; event.location = location
        event.setIntegerValueField(TGFieldEventType, value: Int64(TGEventTypeDockCompanion.rawValue))
        event.setIntegerValueField(TGFieldHIDEventType, value: Int64(TGHIDDockSwipe))
        event.setIntegerValueField(TGFieldGesturePhase, value: phaseValue)
        event.setIntegerValueField(TGFieldDockPhase, value: phaseValue)
        event.setDoubleValueField(TGFieldDockProgress, value: progress)
        event.setIntegerValueField(TGFieldDockProgressFloatBits, value: Int64(Float(progress).bitPattern))
        event.setIntegerValueField(TGFieldDockMarker, value: TGDockMarkerValue)
        let denormal = Double(Float(bitPattern: UInt32(kindValue)))
        event.setDoubleValueField(TGFieldDockTypeDenormal, value: denormal)
        event.setDoubleValueField(TGFieldDockTypeDenormalAlternate, value: denormal)
        event.setIntegerValueField(TGFieldDockType, value: kindValue)
        event.setIntegerValueField(TGFieldDockTypeAlternate, value: kindValue)
        event.setIntegerValueField(TGFieldDockInverted, value: inverted ? 1 : 0)
        if phase == .ended || phase == .cancelled {
            event.setDoubleValueField(TGFieldDockExitSpeedX, value: exitVelocity)
            event.setDoubleValueField(TGFieldDockExitSpeedY, value: exitVelocity)
        }
        return (marker, event)
    }
}
