import Foundation
import XCTest
@testable import TrackglassEngine

final class PointerAccelerationCurveTests: XCTestCase {
    private struct Archive: Decodable {
        let HIDAccelCurves: [[String: Double]]
        let HIDPointerResolution: Double
        let HIDPointerReportRate: Double
    }

    private func referenceData() throws -> (Data, Archive) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Mac/Resources/DefaultAccelCurves.json"))
        return (data, try JSONDecoder().decode(Archive.self, from: data))
    }

    private func curve(_ data: Data, resolution: Double, rate: Double, index: Double) throws -> ParametricAccelerationCurve {
        try ParametricAccelerationCurve(registryJSON: data, accelerationIndex: index,
                                        resolution: resolution / 65_536, reportRate: rate)
    }

    func testReferenceCurvesAreMonotonicFromZeroToFiftyInchesPerSecond() throws {
        let (data, archive) = try referenceData()
        XCTAssertGreaterThanOrEqual(archive.HIDAccelCurves.count, 2)
        let resolution = archive.HIDPointerResolution
        for rawCurve in archive.HIDAccelCurves {
            guard let fixedIndex = rawCurve["HIDAccelIndex"] else { return XCTFail("curve has no index") }
            let model = try curve(data, resolution: resolution, rate: archive.HIDPointerReportRate,
                                 index: fixedIndex / 65_536)
            var previous = model.multiplier(forSpeedInchesPerSecond: 0)
            for step in 1...1_000 {
                let speed = Double(step) / 20
                let value = model.multiplier(forSpeedInchesPerSecond: speed)
                XCTAssertGreaterThanOrEqual(value + 1e-12, previous,
                                            "curve \(fixedIndex / 65_536) decreases at \(speed) in/s")
                previous = value
            }
        }
    }

    func testCurveIsContinuousAtConfiguredTangents() throws {
        let (data, archive) = try referenceData()
        for rawCurve in archive.HIDAccelCurves {
            guard let fixedIndex = rawCurve["HIDAccelIndex"] else { return XCTFail("curve has no index") }
            let model = try curve(data, resolution: archive.HIDPointerResolution,
                                 rate: archive.HIDPointerReportRate, index: fixedIndex / 65_536)
            let tangents = [model.parameters.tangentSpeedLinear, model.parameters.tangentSpeedParabolicRoot]
                .filter { $0 > 0 }
            for tangent in tangents {
                let before = model.multiplier(forSpeedInchesPerSecond: tangent - 1e-6)
                let at = model.multiplier(forSpeedInchesPerSecond: tangent)
                let after = model.multiplier(forSpeedInchesPerSecond: tangent + 1e-6)
                XCTAssertEqual(before, at, accuracy: 1e-3)
                XCTAssertEqual(after, at, accuracy: 1e-3)
            }
        }
    }

    func testMidpointIndexInterpolatesEveryCurveParameter() throws {
        let (data, archive) = try referenceData()
        let curves = archive.HIDAccelCurves.sorted { ($0["HIDAccelIndex"] ?? 0) < ($1["HIDAccelIndex"] ?? 0) }
        let lowIndex = try XCTUnwrap(curves.first?["HIDAccelIndex"])
        let highIndex = try XCTUnwrap(curves.dropFirst().first?["HIDAccelIndex"])
        let midpoint = (lowIndex + highIndex) / (2 * 65_536)
        let model = try curve(data, resolution: archive.HIDPointerResolution,
                             rate: archive.HIDPointerReportRate, index: midpoint)
        let lower = try XCTUnwrap(curves.first)
        let upper = try XCTUnwrap(curves.dropFirst().first)
        let actual = model.parameters
        let fields: [(String, Double)] = [
            ("HIDAccelIndex", actual.index), ("HIDAccelGainLinear", actual.gainLinear),
            ("HIDAccelGainParabolic", actual.gainParabolic), ("HIDAccelGainCubic", actual.gainCubic),
            ("HIDAccelGainQuartic", actual.gainQuartic), ("HIDAccelTangentSpeedLinear", actual.tangentSpeedLinear),
            ("HIDAccelTangentSpeedParabolicRoot", actual.tangentSpeedParabolicRoot)
        ]
        for (key, value) in fields {
            let expected = ((lower[key] ?? 0) + (upper[key] ?? 0)) / (2 * 65_536)
            XCTAssertEqual(value, expected, accuracy: 1e-12, "parameter \(key)")
        }
    }

    func testMultiplierAverageRuntimeIsAtMostFiftyNanoseconds() throws {
#if DEBUG
        throw XCTSkip("The 50 ns budget applies to optimized production code; run this check with swift test -c release.")
#else
        let (data, archive) = try referenceData()
        let model = try curve(data, resolution: archive.HIDPointerResolution,
                             rate: archive.HIDPointerReportRate, index: 1.5)
        var checksum = 0.0
        let iterations = 1_000_000
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations {
            checksum += model.multiplier(forSpeedInchesPerSecond: Double(index % 1_000) / 20)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        XCTAssertGreaterThan(checksum, 0)
        XCTAssertLessThan(Double(elapsed) / Double(iterations), 50,
                          "average multiplier cost was \(Double(elapsed) / Double(iterations)) ns")
#endif
    }
}
