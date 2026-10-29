import Foundation

/// The motion of the last moments before a release, for release velocities (§6.5.8 Dock exit velocity, §6.8
/// momentum). A fixed ring of per-frame deltas with the frame time each one ends at and the interval it covers:
/// the velocity is the motion inside the last 50 ms divided by that span. The span ends at the release, except
/// that the release frame's own interval is not counted as stillness when it follows the last delta within one
/// frame (the lift sample's motion is not part of the deltas, so counting it would make the result depend on the
/// frame rate); a longer pause before the release counts as no motion, so fingers that stopped do not coast.
/// Stillness before the motion began does not count (fingers resting before a flick are not part of it).
/// Storage is allocated once (§7).
struct RecentMotion {
    private struct Entry { var time: UInt64 = 0; var dt: UInt64 = 0; var dx = 0.0; var dy = 0.0 }
    static let window: UInt64 = 50_000_000
    private var entries = [Entry](repeating: Entry(), count: 16)
    private var next = 0, count = 0
    private var motionStart: UInt64?
    private var lastTime: UInt64 = 0, lastInterval: UInt64 = 0

    mutating func clear() { next = 0; count = 0; motionStart = nil }

    /// `dt` is the interval the delta covers, ending at `time`.
    mutating func record(dx: Double, dy: Double = 0, dt: UInt64, at time: UInt64) {
        guard dt > 0, dx.isFinite, dy.isFinite else { return }
        if motionStart == nil, dx != 0 || dy != 0 { motionStart = time >= dt ? time - dt : 0 }
        entries[next] = Entry(time: time, dt: dt, dx: dx, dy: dy)
        lastTime = time; lastInterval = dt
        next = (next + 1) % entries.count
        count = min(count + 1, entries.count)
    }

    /// Delta per second over the last `window` before the release (or since the motion began, if that is later);
    /// the part of each frame interval that falls inside the window counts.
    func velocity(at release: UInt64) -> (Double, Double) {
        guard let motionStart, count > 0 else { return (0, 0) }
        let end = release >= lastTime && release - lastTime <= lastInterval ? lastTime : release
        let windowStart = end >= Self.window ? end - Self.window : 0
        var sx = 0.0, sy = 0.0
        for index in 0..<count {
            let entry = entries[index]
            guard entry.time > windowStart, entry.time <= end else { continue }
            let begin = entry.time >= entry.dt ? entry.time - entry.dt : 0
            let fraction = Double(entry.time - max(begin, windowStart)) / Double(entry.dt)
            sx += entry.dx * fraction; sy += entry.dy * fraction
        }
        let from = max(windowStart, motionStart)
        guard end > from else { return (0, 0) }
        let seconds = Double(end - from) / 1_000_000_000
        return (sx / seconds, sy / seconds)
    }
}
