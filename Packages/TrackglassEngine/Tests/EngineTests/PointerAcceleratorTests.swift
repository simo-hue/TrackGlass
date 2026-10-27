import Foundation
import XCTest
@testable import TrackglassEngine

final class PointerAcceleratorTests: XCTestCase {
    private struct Archive: Decodable {
        let HIDPointerResolution: Double
        let HIDPointerReportRate: Double
    }

    private func referenceAccelerator(trackingSpeed: Double = 0.6875) throws -> PointerAccelerator {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Mac/Resources/DefaultAccelCurves.json"))
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        return try PointerAccelerator(registryJSON: data,
                                      resolution: archive.HIDPointerResolution / 65_536,
                                      reportRate: archive.HIDPointerReportRate,
                                      trackingSpeed: trackingSpeed)
    }

    func testEqualFingerVelocityHasEqualPointerVelocityAtSixtyAndOneTwentyHertz() throws {
        let accelerator = try referenceAccelerator()
        let countsPerMM = (26_214_400.0 / 65_536) / 25.4
        let slowDeltaMM = 32 / countsPerMM
        let fastDeltaMM = 16 / countsPerMM
        let slowOutput = accelerator.accelerate(dxMM: slowDeltaMM, dyMM: 0, dtNanoseconds: 16_666_667).0
        let fastOutput = accelerator.accelerate(dxMM: fastDeltaMM, dyMM: 0, dtNanoseconds: 8_333_333).0
        let slowOutputPerSecond = slowOutput / (Double(16_666_667) / 1_000_000_000)
        let fastOutputPerSecond = fastOutput / (Double(8_333_333) / 1_000_000_000)
        XCTAssertEqual(slowOutputPerSecond, fastOutputPerSecond, accuracy: 1e-3)
    }

    func testTrackingSpeedClampsAndUpdatesCurveSelection() throws {
        let accelerator = try referenceAccelerator(trackingSpeed: 1.5)
        XCTAssertEqual(accelerator.accelerationIndex, 1.5)
        accelerator.updateTrackingSpeed(-2, trackingOverride: -2)
        XCTAssertEqual(accelerator.accelerationIndex, 0)
        accelerator.updateTrackingSpeed(2, trackingOverride: 9)
        XCTAssertEqual(accelerator.accelerationIndex, 3)
    }

    func testZeroDurationReturnsNoPointerMovement() throws {
        let accelerator = try referenceAccelerator()
        XCTAssertEqual(accelerator.accelerate(dxMM: 1, dyMM: -1, dtNanoseconds: 0).0, 0)
        XCTAssertEqual(accelerator.accelerate(dxMM: 1, dyMM: -1, dtNanoseconds: 0).1, 0)
    }
}
