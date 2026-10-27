import CoreGraphics
import TrackglassEngine

enum GestureEventFactory {
    static func navigation(_ direction: SwipeDirection, source: CGEventSource?, location: CGPoint) -> (CGEvent, CGEvent)? {
        guard let began = CGEvent(source: source), let ended = CGEvent(source: source) else { return nil }
        let mask: Int64
        switch direction {
        case .left: mask = Int64(TGSwipeLeft)
        case .right: mask = Int64(TGSwipeRight)
        case .up: mask = Int64(TGSwipeUp)
        case .down: mask = Int64(TGSwipeDown)
        }
        for event in [began, ended] {
            event.type = TGEventTypeGesture; event.location = location
            event.setIntegerValueField(TGFieldEventType, value: Int64(TGEventTypeGesture.rawValue))
            event.setIntegerValueField(TGFieldHIDEventType, value: Int64(TGHIDNavigationSwipe))
        }
        began.setIntegerValueField(TGFieldGesturePhase, value: Int64(TGPhaseBegan))
        began.setIntegerValueField(TGFieldSwipeMask, value: mask)
        ended.setIntegerValueField(TGFieldGesturePhase, value: Int64(TGPhaseEnded))
        ended.setIntegerValueField(TGFieldSwipeMask, value: 0)
        return (began, ended)
    }

    static func make(_ gesture: GestureEvent, source: CGEventSource?, location: CGPoint) -> CGEvent? {
        let subtype: Int64
        var phase: GesturePhase?
        var field: CGEventField?
        var value = 0.0
        switch gesture {
        case let .magnify(delta, gesturePhase):
            subtype = Int64(TGHIDZoom); field = TGFieldMagnification; value = delta; phase = gesturePhase
        case let .rotate(delta, gesturePhase):
            subtype = Int64(TGHIDRotation); field = TGFieldRotation; value = delta; phase = gesturePhase
        case .smartZoom: subtype = Int64(TGHIDZoomToggle)
        case .gestureBegin: subtype = Int64(TGHIDGestureBegan)
        case .gestureEnd: subtype = Int64(TGHIDGestureEnded)
        default: return nil
        }
        guard value.isFinite, let event = CGEvent(source: source) else { return nil }
        event.type = TGEventTypeGesture; event.location = location
        event.setIntegerValueField(TGFieldEventType, value: Int64(TGEventTypeGesture.rawValue))
        event.setIntegerValueField(TGFieldHIDEventType, value: subtype)
        if let field { event.setDoubleValueField(field, value: value) }
        if let phase {
            let bits: Int64
            switch phase {
            case .mayBegin: bits = Int64(TGPhaseMayBegin)
            case .began: bits = Int64(TGPhaseBegan)
            case .changed: bits = Int64(TGPhaseChanged)
            case .ended: bits = Int64(TGPhaseEnded)
            case .cancelled: bits = Int64(TGPhaseCancelled)
            }
            event.setIntegerValueField(TGFieldGesturePhase, value: bits)
        }
        return event
    }
}
