import Foundation

struct ScrollMomentum {
    private struct Sample { var x = 0.0, y = 0.0; var time: UInt64 = 0 }
    private var samples = [Sample](repeating: Sample(), count: 3)
    private var sampleCount = 0, next = 0
    private var vx = 0.0, vy = 0.0
    private var lastTick: UInt64 = 0
    private var began = false
    private(set) var active = false

    mutating func clearSamples() { sampleCount = 0; next = 0 }
    mutating func record(dx: Double, dy: Double, dt: UInt64, at time: UInt64) {
        guard dt > 0 else { return }
        let factor = 1_000_000_000 / Double(dt)
        samples[next] = Sample(x: dx * factor, y: dy * factor, time: time)
        next = (next + 1) % 3; sampleCount = min(sampleCount + 1, 3)
    }
    mutating func start(now: UInt64, enabled: Bool) {
        vx = 0; vy = 0
        var count = 0
        for index in 0..<sampleCount {
            let sample = samples[index]
            if now >= sample.time, now - sample.time <= 50_000_000 {
                vx += sample.x; vy += sample.y; count += 1
            }
        }
        if count > 0 { vx /= Double(count); vy /= Double(count) }
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
