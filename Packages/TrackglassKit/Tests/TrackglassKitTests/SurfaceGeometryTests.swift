import XCTest
@testable import TrackglassKit

final class SurfaceGeometryTests: XCTestCase {
    func testReferencePhoneDimensions() {
        let geometry = SurfaceGeometry(ppi: DevicePPI.lookup(modelIdentifier: "iPhone16,1"), nativeScale: 3,
                                       boundsInPoints: SurfaceSize(width: 393, height: 852))
        XCTAssertEqual(geometry.widthMM, 65.1, accuracy: 0.1)
        XCTAssertEqual(geometry.heightMM, 141.1, accuracy: 0.1)
        XCTAssertEqual(geometry.toMM(point: SurfacePoint(x: 393, y: 852)),
                       SurfacePoint(x: geometry.widthMM, y: geometry.heightMM))
    }

    func testRotationAndWindowBounds() {
        let portrait = SurfaceGeometry(ppi: 264, nativeScale: 2, boundsInPoints: SurfaceSize(width: 834, height: 1194))
        let landscape = SurfaceGeometry(ppi: 264, nativeScale: 2, boundsInPoints: SurfaceSize(width: 1194, height: 834))
        let split = SurfaceGeometry(ppi: 264, nativeScale: 2, boundsInPoints: SurfaceSize(width: 300, height: 600))
        XCTAssertEqual(portrait.widthMM, landscape.heightMM)
        XCTAssertEqual(portrait.heightMM, landscape.widthMM)
        XCTAssertEqual(split.widthMM, 300 * 25.4 / 264 * 2, accuracy: 0.000001)
        XCTAssertEqual(split.toMM(point: SurfacePoint(x: -10, y: 0)).x, -10 * split.mmPerPoint)
    }

    func testPixelDensityFamiliesAndFallbacks() {
        for (identifier, ppi) in [("iPhone11,8", 326.0), ("iPhone12,8", 326), ("iPhone14,6", 326),
                                  ("iPhone13,4", 458), ("iPhone14,8", 458), ("iPhone14,4", 476),
                                  ("iPhone16,2", 460), ("iPhone18,4", 460), ("iPad8,1", 264),
                                  ("iPad11,1", 326), ("iPad14,2", 326), ("iPad16,1", 326),
                                  ("iPad99,1", 264), ("iPhone99,1", 460)] {
            XCTAssertEqual(DevicePPI.lookup(modelIdentifier: identifier), ppi, identifier)
        }
    }

    func testMarketingNames() {
        for (identifier, name) in [("iPhone16,1", "iPhone 15 Pro"), ("iPhone16,2", "iPhone 15 Pro Max"),
                                   ("iPhone13,1", "iPhone 12 mini"), ("iPhone18,3", "iPhone 17"),
                                   ("iPad8,1", "iPad Pro 11-inch (1st generation)"),
                                   ("iPad99,1", "iPad"), ("iPhone99,1", "iPhone")] {
            XCTAssertEqual(DeviceModelName.marketingName(modelIdentifier: identifier), name)
        }
    }
}
