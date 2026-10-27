import UIKit
import XCTest
@testable import TrackglassiOS

final class AccessibilityTests: XCTestCase {
    @MainActor func testTouchSurfaceIsADirectInteractionElement() {
        let surface = TouchSurfaceView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        XCTAssertTrue(surface.isAccessibilityElement)
        XCTAssertEqual(surface.accessibilityLabel, "Trackpad")
        XCTAssertTrue(surface.accessibilityTraits.contains(.allowsDirectInteraction))
    }

    func testAppIconIsInTheAssetCatalog() {
        // The build fails loudly if the catalog is missing; this guards the icon name wiring (ASSETCATALOG_COMPILER_APPICON_NAME).
        let icons = Bundle(for: TouchSurfaceViewController.self).object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        XCTAssertNotNil(primary?["CFBundleIconName"] as? String, "the app bundle must declare its primary icon")
    }
}
