import AppKit
import XCTest
@testable import TrackglassMac

final class MenuBarIconTests: XCTestCase {
    func testMenuBarTemplateIconIsBundled() throws {
        let image = try XCTUnwrap(Bundle(for: MacSettingsModel.self).image(forResource: "MenuBarIcon"), "MenuBarIcon must be in the Mac asset catalog")
        XCTAssertEqual(image.size.width, 18, accuracy: 0.5)
        XCTAssertEqual(image.size.height, 18, accuracy: 0.5)
        XCTAssertTrue(image.isTemplate, "SPEC §6.1: the menu bar icon is a template image")
    }
}
