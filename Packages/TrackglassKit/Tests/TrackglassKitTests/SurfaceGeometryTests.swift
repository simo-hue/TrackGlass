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

    func testOnlyAPositiveFiniteSizeIsSendable() {
        // C3 (L9): a zero-size layout pass must never become HELLO or SURFACE.
        func geometry(_ width: Double, _ height: Double) -> SurfaceGeometry {
            SurfaceGeometry(ppi: 460, nativeScale: 3, boundsInPoints: SurfaceSize(width: width, height: height))
        }
        XCTAssertTrue(geometry(393, 852).isValid)
        XCTAssertTrue(geometry(1, 1).isValid)
        XCTAssertFalse(geometry(0, 852).isValid)
        XCTAssertFalse(geometry(393, 0).isValid)
        XCTAssertFalse(geometry(0, 0).isValid)
        XCTAssertFalse(geometry(1e-300, 852).isValid, "rounds to 0 as the wire's f32")
        XCTAssertFalse(geometry(1e300, 852).isValid, "overflows the wire's f32")
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
                                   ("iPad13,18", "iPad (10th generation)"), ("iPad14,9", "iPad Air 11-inch (M2)"),
                                   ("iPad16,6", "iPad Pro 13-inch (M4)"), ("iPad15,8", "iPad (A16)"),
                                   ("iPad99,1", "iPad"), ("iPhone99,1", "iPhone")] {
            XCTAssertEqual(DeviceModelName.marketingName(modelIdentifier: identifier), name)
        }
    }

    func testEveryCataloguedNonMiniIPadIs264PPIAndEveryMiniIs326() {
        // Appendix C: iPad mini 326, every other iPad 264 — the catalog only adds names, never a stray density.
        for identifier in ["iPad7,1", "iPad8,12", "iPad11,6", "iPad13,16", "iPad14,3", "iPad15,5", "iPad16,3"] {
            XCTAssertEqual(DevicePPI.lookup(modelIdentifier: identifier), 264, identifier)
            XCTAssertNotEqual(DeviceModelName.marketingName(modelIdentifier: identifier), "iPad", "\(identifier) should be named")
        }
        for identifier in ["iPad11,2", "iPad14,1", "iPad16,2"] {
            XCTAssertEqual(DevicePPI.lookup(modelIdentifier: identifier), 326, identifier)
            XCTAssertTrue(DeviceModelName.marketingName(modelIdentifier: identifier).hasPrefix("iPad mini"), identifier)
        }
    }
}
