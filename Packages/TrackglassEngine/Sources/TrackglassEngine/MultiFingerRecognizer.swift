import Foundation

struct MultiFingerRecognizer {
    struct Sample { var x: Double; var y: Double; var radius: Double }
    private(set) var fingerCount = 0
    private var start = Sample(x: 0, y: 0, radius: 0)
    private var previous = Sample(x: 0, y: 0, radius: 0)
    private var axis: DockSwipeKind?
    private var kind: DockSwipeKind?
    private var navigationSent = false
    private var progress = 0.0, lastDelta = 0.0
    private var directions = (0.0, 0.0, 0.0)
    private var movementCount = 0
    var active: Bool { kind != nil || navigationSent }

    mutating func begin(fingers: Int, sample: Sample) {
        fingerCount = fingers; start = sample; previous = sample
        axis = nil; kind = nil; navigationSent = false; progress = 0; lastDelta = 0
        directions = (0, 0, 0); movementCount = 0
    }

    mutating func update(_ sample: Sample, settings: TrackpadSettings, into events: inout EventBuffer) {
        let dx = sample.x - previous.x, dy = sample.y - previous.y, dr = sample.radius - previous.radius
        previous = sample
        guard !navigationSent else { return }
        let totalX = sample.x - start.x, totalY = sample.y - start.y
        if axis == nil {
            if fingerCount <= 4, max(abs(totalX), abs(totalY)) > 6 {
                axis = abs(totalX) >= abs(totalY) ? .horizontal : .vertical
            } else if fingerCount >= 4, abs(sample.radius - start.radius) > 8 { axis = .pinch }
        }
        guard let axis else { return }
        let horizontal = fingerCount == 3 ? settings.threeFingerHorizontalGesture : settings.fourFingerHorizontalGesture
        if axis == .horizontal, fingerCount == 3, horizontal == 1 {
            if abs(totalX) > 20 {
                events.append(.navigationSwipe(direction: totalX < 0 ? .left : .right)); navigationSent = true
            }
            return
        }
        let delta: Double
        switch axis {
        case .horizontal:
            guard horizontal == 2 else { return }
            delta = -dx / 110
        case .vertical:
            let preference = fingerCount == 3 ? settings.threeFingerVerticalGesture : settings.fourFingerVerticalGesture
            guard preference == 2,
                  kind != nil || (totalY < 0 ? settings.missionControlEnabled : settings.appExposeEnabled) else { return }
            delta = -dy / 60
        case .pinch:
            let preference = fingerCount == 4 ? settings.fourFingerPinchGesture : settings.fiveFingerPinchGesture
            guard preference == 2,
                  kind != nil || (sample.radius < start.radius ? settings.launchpadEnabled : settings.showDesktopEnabled) else { return }
            delta = dr / 40
        }
        guard delta != 0 else { return }
        events.append(.dockSwipe(kind: axis, progressDelta: delta, phase: kind == nil ? .began : .changed, exitVelocity: 0))
        kind = axis; progress += delta; lastDelta = delta
        directions = (directions.1, directions.2, delta); movementCount = min(movementCount + 1, 3)
    }

    mutating func end(cancelled: Bool, into events: inout EventBuffer) {
        if let kind {
            let reversed = movementCount == 3 && directions.0 * progress < 0 &&
                directions.1 * progress < 0 && directions.2 * progress < 0
            let cancel = cancelled || reversed
            events.append(.dockSwipe(kind: kind, progressDelta: 0, phase: cancel ? .cancelled : .ended,
                                    exitVelocity: lastDelta * 100))
            if !cancel, kind == .horizontal, abs(progress) >= 0.5 { events.append(.haptic(.spaceSwitched)) }
        }
        self = MultiFingerRecognizer()
    }
}
