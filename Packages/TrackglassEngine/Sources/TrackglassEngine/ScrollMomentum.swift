import Foundation

struct ScrollMomentum {
    /// §6.8: the release velocity is the scroll motion of the last 50 ms before the lift divided by that span, so
    /// fingers that stopped before lifting do not coast (the old per-sample average kept the last moving frames).
    private var motion = RecentMotion()
    private var vx = 0.0, vy = 0.0
    private var lastTick: UInt64 = 0
    private var began = false
    private(set) var active = false

    mutating func clearSamples() { motion.clear() }
    mutating func record(dx: Double, dy: Double, dt: UInt64, at time: UInt64) {
        motion.record(dx: dx, dy: dy, dt: dt, at: time)
    }
    mutating func start(now: UInt64, enabled: Bool) {
        (vx, vy) = motion.velocity(at: now)
        active = enabled && hypot(vx, vy) >= 60
        lastTick = now; began = false; clearSamples()
    }
    mutating func tick(now: UInt64, into events: inout EventBuffer) {
        guard active, now > lastTick else { return }
        if hypot(vx, vy) < 5 { cancel(into: &events); return }
        let seconds = Double(now - lastTick) / 1_000_000_000
        events.append(.scrollMomentum(phase: began ? .continued : .begin, dxPoints: vx * seconds, dyPoints: vy * seconds))
        let decay = pow(0.998, seconds * 1_000)
        vx *= decay; vy *= decay; lastTick = now; began = true
    }
    @discardableResult
    mutating func cancel(into events: inout EventBuffer) -> Bool {
        guard active else { clearSamples(); return false }
        events.append(.scrollMomentum(phase: .end, dxPoints: 0, dyPoints: 0))
        active = false; began = false; vx = 0; vy = 0; clearSamples()
        return true
    }
}
