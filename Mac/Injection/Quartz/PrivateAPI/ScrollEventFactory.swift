import CoreGraphics
import TrackglassEngine

/// Queue-confined conversion of scroll points to Quartz wheel/gesture events.
final class ScrollEventFactory {
    private var pointX = 0.0, pointY = 0.0
    private var lineX = 0.0, lineY = 0.0

    func make(dx: Double, dy: Double, phase: GesturePhase, natural: Bool,
              source: CGEventSource?, location: CGPoint) -> (wheel: CGEvent, companion: CGEvent)? {
        guard let wheel = makeWheel(dx: dx, dy: dy, phase: phase, momentum: 0, natural: natural,
            source: source, location: location), let companion = CGEvent(source: source) else { return nil }
        let terminal = phase == .ended || phase == .cancelled || phase == .mayBegin
        companion.type = TGEventTypeGesture
        companion.location = location
        companion.timestamp = wheel.timestamp
        companion.setIntegerValueField(TGFieldEventType, value: Int64(TGEventTypeGesture.rawValue))
        companion.setIntegerValueField(TGFieldHIDEventType, value: Int64(TGHIDScroll))
        companion.setIntegerValueField(TGFieldGesturePhase, value: wheel.getIntegerValueField(.scrollWheelEventScrollPhase))
        companion.setDoubleValueField(TGFieldGestureDeltaX, value: terminal ? 0 : dx * 1.67)
        companion.setDoubleValueField(TGFieldGestureDeltaY, value: terminal ? 0 : dy * 1.67)
        return (wheel, companion)
    }

    func makeMomentum(dx: Double, dy: Double, phase: MomentumPhase, natural: Bool,
                      source: CGEventSource?, location: CGPoint) -> CGEvent? {
        let value = phase == .begin ? TGMomentumBegin : phase == .continued ? TGMomentumContinue : TGMomentumEnd
        return makeWheel(dx: dx, dy: dy, phase: phase == .begin ? .began : phase == .continued ? .changed : .ended,
            momentum: Int64(value), natural: natural, source: source, location: location)
    }

    private func makeWheel(dx: Double, dy: Double, phase: GesturePhase, momentum: Int64, natural: Bool,
                           source: CGEventSource?, location: CGPoint) -> CGEvent? {
        guard dx.isFinite, dy.isFinite,
              abs(dx) < 1_000_000, abs(dy) < 1_000_000,
              let wheel = CGEvent(source: source) else { return nil }
        if phase == .mayBegin || phase == .began {
            pointX = 0; pointY = 0; lineX = 0; lineY = 0
        }
        let terminal = phase == .ended || phase == .cancelled || phase == .mayBegin
        let x = terminal ? 0 : dx, y = terminal ? 0 : dy
        pointX += x; pointY += y; lineX += x / 10; lineY += y / 10
        let px = pointX.rounded(.towardZero), py = pointY.rounded(.towardZero)
        let lx = lineX.rounded(.towardZero), ly = lineY.rounded(.towardZero)
        pointX -= px; pointY -= py; lineX -= lx; lineY -= ly

        let phaseValue: Int64
        switch phase {
        case .mayBegin: phaseValue = Int64(TGPhaseMayBegin)
        case .began: phaseValue = Int64(TGPhaseBegan)
        case .changed: phaseValue = Int64(TGPhaseChanged)
        case .ended: phaseValue = Int64(TGPhaseEnded)
        case .cancelled: phaseValue = Int64(TGPhaseCancelled)
        }
        wheel.type = .scrollWheel
        wheel.location = location
        wheel.setIntegerValueField(TGFieldEventType, value: Int64(CGEventType.scrollWheel.rawValue))
        wheel.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        wheel.setIntegerValueField(TGFieldDirectionInvertedFromDevice, value: natural ? 1 : 0)
        wheel.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(ly))
        wheel.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(lx))
        wheel.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(py))
        wheel.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(px))
        wheel.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Int64((y / 10 * 65_536).rounded(.towardZero)))
        wheel.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Int64((x / 10 * 65_536).rounded(.towardZero)))
        wheel.setIntegerValueField(.scrollWheelEventScrollPhase, value: momentum == 0 ? phaseValue : 0)
        wheel.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)

        if terminal { pointX = 0; pointY = 0; lineX = 0; lineY = 0 }
        return wheel
    }
}
