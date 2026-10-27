// Algorithm reproduced from Apple's IOHIDFamily (IOHIDAccelerationAlgorithm.cpp), Apple Public Source License 2.0. See docs/THIRD-PARTY.md.
import Foundation

/// Converts touch deltas in millimeters to accelerated pointer points.
/// The instance is confined to GestureEngine's input queue.
public final class PointerAccelerator: AccelerationModel, @unchecked Sendable {
    public static let outputScale = 1.0

    public enum ConfigurationError: Error {
        case invalidDeviceProperties
    }

    private let curves: [ParametricAccelerationCurve.Parameters]
    private let resolution: Double
    private let reportRate: Double
    private let countsPerMM: Double
    private let outputScale: Double
    private var trackingSpeed: Double
    private var trackingOverride: Double
    private var curve: ParametricAccelerationCurve
    public private(set) var accelerationIndex: Double

    public init(curves: [ParametricAccelerationCurve.Parameters], resolution: Double, reportRate: Double,
                trackingSpeed: Double, trackingOverride: Double = 0,
                outputScale: Double = PointerAccelerator.outputScale) throws {
        guard resolution.isFinite, resolution > 0, reportRate.isFinite, reportRate > 0,
              outputScale.isFinite, outputScale >= 0, !curves.isEmpty else {
            throw ConfigurationError.invalidDeviceProperties
        }
        self.curves = curves
        self.resolution = resolution
        self.reportRate = reportRate
        self.countsPerMM = resolution / 25.4
        self.outputScale = outputScale
        self.trackingSpeed = trackingSpeed
        self.trackingOverride = trackingOverride
        let index = Self.clampedIndex(trackingSpeed, trackingOverride)
        self.accelerationIndex = index
        self.curve = try ParametricAccelerationCurve(curves: curves, accelerationIndex: index,
                                                     resolution: resolution, reportRate: reportRate)
    }

    public convenience init(registryJSON: Data, resolution: Double, reportRate: Double,
                            trackingSpeed: Double, trackingOverride: Double = 0,
                            outputScale: Double = PointerAccelerator.outputScale) throws {
        try self.init(curves: ParametricAccelerationCurve.decodeCurves(from: registryJSON),
                      resolution: resolution, reportRate: reportRate, trackingSpeed: trackingSpeed,
                      trackingOverride: trackingOverride, outputScale: outputScale)
    }

    public static func fallback(trackingSpeed: Double, trackingOverride: Double = 0) -> PointerAccelerator {
        let curve = ParametricAccelerationCurve.Parameters(index: 1, gainLinear: 1, gainParabolic: 0.8,
                                                            tangentSpeedLinear: 4, tangentSpeedParabolicRoot: 8)
        // These fallback values are specified in SPEC §6.6 for a Mac with no usable registry data.
        return try! PointerAccelerator(curves: [curve], resolution: 1_000, reportRate: 125,
                                       trackingSpeed: trackingSpeed, trackingOverride: trackingOverride)
    }

    public func updateTrackingSpeed(_ trackingSpeed: Double, trackingOverride: Double = 0) {
        self.trackingSpeed = trackingSpeed
        self.trackingOverride = trackingOverride
        let index = Self.clampedIndex(trackingSpeed, trackingOverride)
        guard index != accelerationIndex,
              let nextCurve = try? ParametricAccelerationCurve(curves: curves, accelerationIndex: index,
                                                               resolution: resolution, reportRate: reportRate) else { return }
        accelerationIndex = index
        curve = nextCurve
    }

    @inline(__always)
    public func accelerate(dxMM: Double, dyMM: Double, dtNanoseconds: UInt64) -> (Double, Double) {
        guard dtNanoseconds > 0 else { return (0, 0) }
        let dxCounts = dxMM * countsPerMM
        let dyCounts = dyMM * countsPerMM
        let deltaTMilliseconds = Double(dtNanoseconds) / 1_000_000
        let reportPeriodMilliseconds = 1_000 / reportRate
        let rateMultiplier = reportPeriodMilliseconds / max(deltaTMilliseconds, reportPeriodMilliseconds)
        let velocity = max((dxCounts * dxCounts + dyCounts * dyCounts).squareRoot().rounded(.down) * rateMultiplier,
                           1.0 / 65_536)
        let multiplier = curve.multiplier(forDeviceVelocity: velocity) / velocity
        return (dxCounts * multiplier * outputScale, dyCounts * multiplier * outputScale)
    }

    private static func clampedIndex(_ trackingSpeed: Double, _ trackingOverride: Double) -> Double {
        let speed = trackingSpeed.isFinite ? trackingSpeed : 0.6875
        let override = trackingOverride.isFinite ? trackingOverride : 0
        return min(max(speed + override, 0), 3)
    }
}
