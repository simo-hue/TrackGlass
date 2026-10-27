import Foundation

struct TwoFingerRecognizer {
    private var previous: (x: Double, y: Double, time: UInt64)?
    private var path = 0.0
    private(set) var scrollActive = false
    private(set) var lastDeltaTime: UInt64 = 0
    private var startDistance = 0.0, previousDistance = 0.0, previousAngle = 0.0, totalAngle = 0.0
    private var pinchActive = false, rotateActive = false, bracketOpen = false
    private var edgeCandidate = false, edgeTriggered = false
    private var originX = 0.0, originY = 0.0
    var hasActiveGesture: Bool { scrollActive || pinchActive || rotateActive || edgeTriggered }

    mutating func begin(x: Double, y: Double, distance: Double, angle: Double, time: UInt64, rightEdge: Bool = false) {
        previous = (x, y, time); path = 0; scrollActive = false
        startDistance = distance; previousDistance = distance; previousAngle = angle; totalAngle = 0
        pinchActive = false; rotateActive = false; bracketOpen = false
        edgeCandidate = rightEdge; edgeTriggered = false; originX = x; originY = y
    }

    mutating func update(x: Double, y: Double, distance: Double, angle: Double, time: UInt64, settings: TrackpadSettings,
                         acceleration: any AccelerationModel, suppressActivation: Bool = false, into events: inout EventBuffer) {
        guard let previous, time > previous.time else { return }
        let dx = x - previous.x, dy = y - previous.y
        lastDeltaTime = time - previous.time
        self.previous = (x, y, time)
        if edgeTriggered { return }
        if edgeCandidate && settings.notificationCenterEdgeGesture == 3 {
            if x - originX < -8 {
                events.append(.notificationCenter); edgeTriggered = true; return
            }
            if x > originX || abs(y - originY) > max(1.5, abs(x - originX)) { edgeCandidate = false }
            else { return }
        }
        if suppressActivation && !hasActiveGesture {
            path = 0; startDistance = distance; previousDistance = distance
            previousAngle = angle; totalAngle = 0
            return
        }
        if suppressActivation && !scrollActive { path = 0 }
        else {
            path += hypot(dx, dy)
            if settings.scrollEnabled, path > 1.5 {
                let delta = acceleration.accelerate(dxMM: settings.horizontalScrollEnabled ? dx : 0,
                    dyMM: dy, dtNanoseconds: lastDeltaTime)
                if delta.0 != 0 || delta.1 != 0 {
                    let sign = settings.naturalScrolling ? 1.0 : -1.0
                    events.append(.scroll(dxPoints: delta.0 * sign, dyPoints: delta.1 * sign,
                        phase: scrollActive ? .changed : .began, naturalInverted: settings.naturalScrolling))
                    scrollActive = true
                }
            }
        }
        var angleDelta = angle - previousAngle
        while angleDelta > .pi { angleDelta -= 2 * .pi }
        while angleDelta < -.pi { angleDelta += 2 * .pi }
        totalAngle += angleDelta
        let pinch = settings.pinchEnabled && previousDistance > 0.0001 &&
            (pinchActive || abs(distance - startDistance) > 2.5)
        let rotate = settings.rotateEnabled && distance > 15 &&
            (rotateActive || abs(totalAngle) > 5 * .pi / 180)
        if (pinch || rotate) && !bracketOpen { events.append(.gestureBegin); bracketOpen = true }
        if pinch {
            let delta = distance / previousDistance - 1
            if delta != 0 || !pinchActive { events.append(.magnify(delta: delta, phase: pinchActive ? .changed : .began)) }
            pinchActive = true
        }
        if rotate {
            let delta = angleDelta * 180 / .pi
            if delta != 0 || !rotateActive { events.append(.rotate(deltaDegrees: delta, phase: rotateActive ? .changed : .began)) }
            rotateActive = true
        }
        previousDistance = distance; previousAngle = angle
    }

    mutating func end(cancelled: Bool, natural: Bool, into events: inout EventBuffer) {
        events.append(.scroll(dxPoints: 0, dyPoints: 0,
            phase: scrollActive && !cancelled ? .ended : .cancelled, naturalInverted: natural))
        if pinchActive { events.append(.magnify(delta: 0, phase: cancelled ? .cancelled : .ended)) }
        if rotateActive { events.append(.rotate(deltaDegrees: 0, phase: cancelled ? .cancelled : .ended)) }
        if bracketOpen { events.append(.gestureEnd) }
        previous = nil; path = 0; scrollActive = false
        pinchActive = false; rotateActive = false; bracketOpen = false
    }
}
