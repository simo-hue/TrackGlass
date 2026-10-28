// Algorithm reproduced from Apple's IOHIDFamily (IOHIDAcceleration.cpp), Apple Public Source License 2.0. See docs/THIRD-PARTY.md.
import Foundation

/// Apple's parametric scroll velocity history, independently implemented in Swift.
/// Queue-confined; all history storage is allocated at initialization.
public final class ScrollAccelerator: AccelerationModel, @unchecked Sendable {
    private let curves: [ParametricAccelerationCurve.Parameters]
    private let resolution: Double
    private let rate: Double
    private var curve: ParametricAccelerationCurve
    private var accelerationIndex: Double
    private var x = AxisHistory()
    private var y = AxisHistory()

    public init(curves: [ParametricAccelerationCurve.Parameters], resolution: Double,
                reportRate: Double, trackingSpeed: Double) throws {
        self.curves = curves; self.resolution = resolution; rate = reportRate
        accelerationIndex = min(max(trackingSpeed, 0), 3)
        curve = try ParametricAccelerationCurve(curves: curves, accelerationIndex: accelerationIndex,
                                                resolution: resolution, reportRate: reportRate)
    }

    /// Rebuilds the curve only when the clamped index actually changes, so an unchanged
    /// settings snapshot applied from the frame path allocates nothing.
    public func updateTrackingSpeed(_ speed: Double) {
        guard speed.isFinite else { return }
        let index = min(max(speed, 0), 3)
        guard index != accelerationIndex, let updated = try? ParametricAccelerationCurve(curves: curves,
            accelerationIndex: index, resolution: resolution, reportRate: rate) else { return }
        accelerationIndex = index
        curve = updated; reset()
    }

    public func reset() { x.reset(); y.reset() }

    public func accelerate(dxMM: Double, dyMM: Double, dtNanoseconds: UInt64) -> (Double, Double) {
        guard dtNanoseconds > 0, dxMM.isFinite, dyMM.isFinite else { return (0, 0) }
        let ms = Double(dtNanoseconds) / 1_000_000
        return (x.points(counts: dxMM * resolution / 25.4, ms: ms, rate: rate, curve: curve),
                y.points(counts: dyMM * resolution / 25.4, ms: ms, rate: rate, curve: curve))
    }

    private struct AxisHistory {
        private var amounts = [Double](repeating: 0, count: 9)
        private var intervals = [Double](repeating: 0, count: 9)
        private var next = 0, count = 0
        private var positive: Bool?
        /// Frame time that passed while this axis produced no counts; Apple's history interval is the time since
        /// the previous event *on this axis*, not the previous frame.
        private var idleMs = 0.0
        mutating func reset() { next = 0; count = 0; positive = nil; idleMs = 0 }

        mutating func points(counts: Double, ms frameMs: Double, rate: Double, curve: ParametricAccelerationCurve) -> Double {
            guard counts != 0 else { idleMs += frameMs; return 0 }
            let ms = frameMs + idleMs
            idleMs = 0
            if ms > 500 { reset() }
            if let positive, positive != (counts > 0) { reset() }
            positive = counts > 0
            amounts[next] = abs(counts); intervals[next] = ms
            next = (next + 1) % 9
            // Apple's nine-slot head/tail ring leaves one slot empty.
            count = min(count + 1, 8)
            var sum = 0.0, duration = 0.0, samples = 0
            for offset in 1...count {
                let index = (next + 9 - offset) % 9
                sum += amounts[index]; samples += 1
                duration += min(intervals[index], 150)
                if intervals[index] > 150 || duration >= 500 { break }
            }
            let rateScale = rate / 67
            let averageMS = min(max(duration / Double(samples) * rateScale, 1), 150)
            let velocity = max(((2 * averageMS * averageMS - 955 * averageMS + 98_369) / 65_536)
                               * sum / Double(samples) * rateScale, 1 / 65_536)
            let multiplier = curve.multiplier(forDeviceVelocity: velocity) / velocity
            // Apple returns wheel-line units; the engine's contract is points (10 points/line).
            return counts * multiplier * (6_554.0 / 65_536) * 10
        }
    }
}

public struct ScrollFallbackAcceleration: AccelerationModel {
    public init() {}
    public func accelerate(dxMM: Double, dyMM: Double, dtNanoseconds: UInt64) -> (Double, Double) {
        guard dtNanoseconds > 0, dxMM.isFinite, dyMM.isFinite else { return (0, 0) }
        let speed = hypot(dxMM, dyMM) * 1_000_000_000 / Double(dtNanoseconds)
        let gain = 3.8 * (1 + 0.5 * (1 - exp(-speed / 350)))
        return (dxMM * gain, dyMM * gain)
    }
}
