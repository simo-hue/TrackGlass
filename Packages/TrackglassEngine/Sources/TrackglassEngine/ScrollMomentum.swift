import Foundation

struct ScrollMomentum {
    /// §6.8: the release velocity is the scroll motion of the last 50 ms before the lift divided by that span, so
    /// fingers that stopped before lifting do not coast (the old per-sample average kept the last moving frames).
    private var motion = RecentMotion()
    private var vx = 0.0, vy = 0.0
    private var lastTick: UInt64 = 0
    private var began = false
    private(set) var active = false
    /// The longest interval one step integrates (2 × ENGINE_TICK). After a stall (a heartbeat lift-off processed
    /// at the last frame's time, a busy input queue) the velocity still decays over the whole gap, but the gap's
    /// travel is not sent as one jump (2026-10-31). Normal 8 ms ticks are unaffected.
    static let maximumStepNs: UInt64 = 16_000_000

    mutating func clearSamples() { motion.clear() }
    mutating func record(dx: Double, dy: Double, dt: UInt64, at time: UInt64) {
        motion.record(dx: dx, dy: dy, dt: dt, at: time)
    }
    /// Starts coasting at a scroll's lift (§6.8). A momentum phase that already began is closed first (`.end`):
    /// apps must never see a second `.begin` without an `.end`, nor a begun phase left open.
    mutating func start(now: UInt64, enabled: Bool, into events: inout EventBuffer) {
        if active && began {
            events.append(.scrollMomentum(phase: .end, dxPoints: 0, dyPoints: 0))
            active = false; began = false
        }
        start(now: now, enabled: enabled)
    }
    /// Without an event buffer a begun phase cannot be closed, so it keeps coasting instead of being re-armed.
    mutating func start(now: UInt64, enabled: Bool) {
        guard !(active && began) else { clearSamples(); return }
        (vx, vy) = motion.velocity(at: now)
        active = enabled && hypot(vx, vy) >= 60
        lastTick = now; began = false; clearSamples()
    }
    mutating func tick(now: UInt64, into events: inout EventBuffer) {
        guard active, now > lastTick else { return }
        let elapsed = now - lastTick
        let step = min(elapsed, Self.maximumStepNs)
        if elapsed > step {
            let skipped = pow(0.998, Double(elapsed - step) / 1_000_000)
            vx *= skipped; vy *= skipped
        }
        if hypot(vx, vy) < 5 { cancel(into: &events); return }
        let seconds = Double(step) / 1_000_000_000
        events.append(.scrollMomentum(phase: began ? .continued : .begin, dxPoints: vx * seconds, dyPoints: vy * seconds))
        let decay = pow(0.998, seconds * 1_000)
        vx *= decay; vy *= decay; lastTick = now; began = true
    }
    @discardableResult
    mutating func cancel(into events: inout EventBuffer) -> Bool {
        guard active else { clearSamples(); return false }
        // An `.end` only closes a momentum phase that began (a cancel before the first tick emits nothing).
        if began { events.append(.scrollMomentum(phase: .end, dxPoints: 0, dyPoints: 0)) }
        active = false; began = false; vx = 0; vy = 0; clearSamples()
        return true
    }
}
