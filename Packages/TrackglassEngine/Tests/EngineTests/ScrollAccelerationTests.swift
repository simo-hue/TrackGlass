import XCTest
@testable import TrackglassEngine

final class ScrollAccelerationTests: XCTestCase {
    func testReferenceCurveOutputSpeedIsMonotonicInFingerSpeed() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("Mac/Resources/DefaultAccelCurves.json"))
        let curves = try ParametricAccelerationCurve.decodeScrollCurves(from: data)
        for index in [0.0, 0.6875, 1.5, 3.0] {
            var last = 0.0
            for speed in stride(from: 1.0, through: 1_000.0, by: 1) {
                let accelerator = try ScrollAccelerator(curves: curves, resolution: 400, reportRate: 120, trackingSpeed: index)
                let gain = accelerator.accelerate(dxMM: 0, dyMM: 1, dtNanoseconds: UInt64(1_000_000_000 / speed)).1
                XCTAssertGreaterThanOrEqual(gain * speed + 0.0000001, last)
                XCTAssertTrue(gain.isFinite)
                last = gain * speed
            }
        }
    }

    func testLinearCurveUnitsAndDirectionReset() throws {
        let curves = [ParametricAccelerationCurve.Parameters(index: 0, gainLinear: 1)]
        let accelerator = try ScrollAccelerator(curves: curves, resolution: 400, reportRate: 120, trackingSpeed: 0)
        let positive = accelerator.accelerate(dxMM: 0, dyMM: 1, dtNanoseconds: 8_000_000).1
        let expected = (400.0 / 25.4) * (120.0 / 400) * (96.0 / 67) * (6_554.0 / 65_536) * 10
        XCTAssertEqual(positive, expected, accuracy: 1e-10)
        let negative = accelerator.accelerate(dxMM: 0, dyMM: -1, dtNanoseconds: 8_000_000).1
        XCTAssertEqual(negative, -positive, accuracy: 1e-10)
        XCTAssertEqual(accelerator.accelerate(dxMM: 1, dyMM: 1, dtNanoseconds: 0).0, 0)
    }

    func testFallbackGainAndHistoryReset() throws {
        var last = 0.0
        let fallback = ScrollFallbackAcceleration()
        for speed in stride(from: 1.0, through: 1_000, by: 10) {
            let value = fallback.accelerate(dxMM: 0, dyMM: 1, dtNanoseconds: UInt64(1_000_000_000 / speed)).1
            XCTAssertGreaterThanOrEqual(value, last); XCTAssertLessThanOrEqual(value, 5.7)
            last = value
        }
        let curves = [ParametricAccelerationCurve.Parameters(index: 0, gainLinear: 1, gainParabolic: 0.6,
            tangentSpeedLinear: 6, tangentSpeedParabolicRoot: 12)]
        let used = try ScrollAccelerator(curves: curves, resolution: 400, reportRate: 120, trackingSpeed: 0)
        for _ in 0..<20 { _ = used.accelerate(dxMM: 3, dyMM: 3, dtNanoseconds: 8_000_000) }
        used.reset()
        let fresh = try ScrollAccelerator(curves: curves, resolution: 400, reportRate: 120, trackingSpeed: 0)
        XCTAssertEqual(used.accelerate(dxMM: 1, dyMM: 1, dtNanoseconds: 8_000_000).1,
                       fresh.accelerate(dxMM: 1, dyMM: 1, dtNanoseconds: 8_000_000).1)
    }
}
