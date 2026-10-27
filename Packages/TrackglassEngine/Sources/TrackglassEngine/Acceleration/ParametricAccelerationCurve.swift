// Algorithm reproduced from Apple's IOHIDFamily (IOHIDAccelerationAlgorithm.cpp), Apple Public Source License 2.0. See docs/THIRD-PARTY.md.
import Foundation

public struct ParametricAccelerationCurve: AccelerationModel, Sendable {
    public struct Parameters: Sendable, Equatable {
        public var index: Double
        public var gainLinear: Double
        public var gainParabolic: Double
        public var gainCubic: Double
        public var gainQuartic: Double
        public var tangentSpeedLinear: Double
        public var tangentSpeedParabolicRoot: Double

        public init(index: Double, gainLinear: Double, gainParabolic: Double = 0,
                    gainCubic: Double = 0, gainQuartic: Double = 0,
                    tangentSpeedLinear: Double = 0, tangentSpeedParabolicRoot: Double = 0) {
            self.index = index
            self.gainLinear = gainLinear
            self.gainParabolic = gainParabolic
            self.gainCubic = gainCubic
            self.gainQuartic = gainQuartic
            self.tangentSpeedLinear = tangentSpeedLinear
            self.tangentSpeedParabolicRoot = tangentSpeedParabolicRoot
        }
    }

    public enum ConfigurationError: Error {
        case noCurves
        case invalidCurve
        case invalidDeviceScale
    }

    public let parameters: Parameters
    public let accelerationIndex: Double
    public let resolution: Double
    public let reportRate: Double
    private let deviceScale: Double

    private let tangent0: Double
    private let tangent1: Double
    private let slope0: Double
    private let intercept0: Double
    private let slope1: Double
    private let intercept1: Double

    public init(curves: [Parameters], accelerationIndex: Double,
                resolution: Double, reportRate: Double) throws {
        guard !curves.isEmpty else { throw ConfigurationError.noCurves }
        guard resolution.isFinite, resolution > 0, reportRate.isFinite, reportRate > 0 else {
            throw ConfigurationError.invalidDeviceScale
        }
        guard accelerationIndex.isFinite,
              curves.allSatisfy({ $0.valuesAreFinite && $0.tangentSpeedLinear >= 0 && $0.tangentSpeedParabolicRoot >= 0 }) else {
            throw ConfigurationError.invalidCurve
        }

        let sorted = curves.sorted { $0.index < $1.index }
        guard zip(sorted, sorted.dropFirst()).allSatisfy({ $0.index < $1.index }) else {
            throw ConfigurationError.invalidCurve
        }

        let lowerIndex = sorted.lastIndex(where: { $0.index <= accelerationIndex }) ?? sorted.startIndex
        var selected = sorted[lowerIndex]
        if lowerIndex + 1 < sorted.count, selected.index < accelerationIndex {
            let upper = sorted[lowerIndex + 1]
            let ratio = (accelerationIndex - selected.index) / (upper.index - selected.index)
            selected = selected.interpolated(to: upper, ratio: ratio)
        }

        self.parameters = selected
        self.accelerationIndex = accelerationIndex
        self.resolution = resolution
        self.reportRate = reportRate
        self.deviceScale = resolution / reportRate

        var firstTangent = Double.greatestFiniteMagnitude
        var secondTangent = Double.greatestFiniteMagnitude
        var firstSlope = 0.0
        var firstIntercept = 0.0
        var secondSlope = 0.0
        var secondIntercept = 0.0

        if selected.tangentSpeedLinear != 0 {
            let x = selected.tangentSpeedLinear
            let y = Self.firstSegment(x, selected)
            firstSlope = Self.derivative(x, selected)
            firstIntercept = y - firstSlope * x
            firstTangent = x

            if selected.tangentSpeedParabolicRoot != 0 {
                let root = selected.tangentSpeedParabolicRoot
                let y1 = firstSlope * root + firstIntercept
                secondSlope = 2 * y1 * firstSlope
                secondIntercept = y1 * y1 - secondSlope * root
                secondTangent = root
            }
        } else if selected.tangentSpeedParabolicRoot != 0 {
            let root = selected.tangentSpeedParabolicRoot
            let y0 = Self.firstSegment(root, selected)
            secondSlope = Self.derivative(root, selected)
            secondIntercept = y0 * y0 - secondSlope * root
            firstTangent = root
        }

        self.tangent0 = firstTangent
        self.tangent1 = secondTangent
        self.slope0 = firstSlope
        self.intercept0 = firstIntercept
        self.slope1 = secondSlope
        self.intercept1 = secondIntercept
    }

    public init(registryJSON: Data, accelerationIndex: Double,
                resolution: Double, reportRate: Double) throws {
        try self.init(curves: Self.decodeCurves(from: registryJSON), accelerationIndex: accelerationIndex,
                      resolution: resolution, reportRate: reportRate)
    }

    public static func decodeCurves(from registryJSON: Data) throws -> [Parameters] {
        try JSONDecoder().decode(CurveArchive.self, from: registryJSON).curves.map(\.parameters)
    }

    public static func decodeScrollCurves(from registryJSON: Data) throws -> [Parameters] {
        try JSONDecoder().decode(ScrollCurveArchive.self, from: registryJSON).curves.map(\.parameters)
    }

    /// Returns Apple's cursor multiplier for device units per report.
    @inline(__always)
    public func multiplier(forDeviceVelocity velocity: Double) -> Double {
        let value = velocity / deviceScale
        let result: Double
        if value <= tangent0 {
            result = Self.firstSegment(value, parameters)
        } else if value <= tangent1 && tangent0 == parameters.tangentSpeedLinear {
            result = slope0 * value + intercept0
        } else {
            result = (slope1 * value + intercept1).squareRoot()
        }
        return result * (96.0 / 67.0)
    }

    /// Convenience evaluator for tests and callers that already have physical speed.
    @inline(__always)
    public func multiplier(forSpeedInchesPerSecond speed: Double) -> Double {
        multiplier(forDeviceVelocity: speed * deviceScale)
    }

    /// Compatibility implementation for the engine protocol. M5.3 adds the count and report-rate normalization path.
    public func accelerate(dxMM: Double, dyMM: Double, dtNanoseconds: UInt64) -> (Double, Double) {
        guard dtNanoseconds > 0 else { return (dxMM, dyMM) }
        let seconds = Double(dtNanoseconds) / 1_000_000_000
        let speed = (dxMM * dxMM + dyMM * dyMM).squareRoot() / seconds / 25.4
        guard speed > 0 else { return (dxMM, dyMM) }
        let multiplier = multiplier(forSpeedInchesPerSecond: speed)
        return (dxMM * multiplier, dyMM * multiplier)
    }

    @inline(__always)
    private static func firstSegment(_ x: Double, _ p: Parameters) -> Double {
        let linear = p.gainLinear * x
        let parabolic = p.gainParabolic * x
        let cubic = p.gainCubic * x
        let quartic = p.gainQuartic * x
        return linear + parabolic * parabolic + cubic * cubic * cubic + quartic * quartic * quartic * quartic
    }

    @inline(__always)
    private static func derivative(_ x: Double, _ p: Parameters) -> Double {
        let parabolic = p.gainParabolic
        let cubic = p.gainCubic
        let quartic = p.gainQuartic
        return p.gainLinear + 2 * x * parabolic * parabolic
            + 3 * x * x * cubic * cubic * cubic
            + 4 * x * x * x * quartic * quartic * quartic * quartic
    }
}

private extension ParametricAccelerationCurve.Parameters {
    var valuesAreFinite: Bool {
        [index, gainLinear, gainParabolic, gainCubic, gainQuartic,
         tangentSpeedLinear, tangentSpeedParabolicRoot].allSatisfy(\.isFinite)
    }

    func interpolated(to other: Self, ratio: Double) -> Self {
        func blend(_ a: Double, _ b: Double) -> Double { a + (b - a) * ratio }
        return .init(index: blend(index, other.index), gainLinear: blend(gainLinear, other.gainLinear),
                     gainParabolic: blend(gainParabolic, other.gainParabolic),
                     gainCubic: blend(gainCubic, other.gainCubic), gainQuartic: blend(gainQuartic, other.gainQuartic),
                     tangentSpeedLinear: blend(tangentSpeedLinear, other.tangentSpeedLinear),
                     tangentSpeedParabolicRoot: blend(tangentSpeedParabolicRoot, other.tangentSpeedParabolicRoot))
    }
}

private struct CurveArchive: Decodable {
    let curves: [RegistryCurve]

    enum CodingKeys: String, CodingKey { case curves = "HIDAccelCurves" }
}

private struct ScrollCurveArchive: Decodable {
    let curves: [RegistryCurve]
    enum CodingKeys: String, CodingKey { case curves = "HIDScrollAccelCurves" }
}

private struct RegistryCurve: Decodable {
    let index: Int64
    let gainLinear: Int64
    let gainParabolic: Int64?
    let gainCubic: Int64?
    let gainQuartic: Int64?
    let tangentSpeedLinear: Int64?
    let tangentSpeedParabolicRoot: Int64?

    enum CodingKeys: String, CodingKey {
        case index = "HIDAccelIndex"
        case gainLinear = "HIDAccelGainLinear"
        case gainParabolic = "HIDAccelGainParabolic"
        case gainCubic = "HIDAccelGainCubic"
        case gainQuartic = "HIDAccelGainQuartic"
        case tangentSpeedLinear = "HIDAccelTangentSpeedLinear"
        case tangentSpeedParabolicRoot = "HIDAccelTangentSpeedParabolicRoot"
    }

    var parameters: ParametricAccelerationCurve.Parameters {
        let scale = 65_536.0
        return .init(index: Double(index) / scale, gainLinear: Double(gainLinear) / scale,
                     gainParabolic: Double(gainParabolic ?? 0) / scale,
                     gainCubic: Double(gainCubic ?? 0) / scale,
                     gainQuartic: Double(gainQuartic ?? 0) / scale,
                     tangentSpeedLinear: Double(tangentSpeedLinear ?? 0) / scale,
                     tangentSpeedParabolicRoot: Double(tangentSpeedParabolicRoot ?? 0) / scale)
    }
}
