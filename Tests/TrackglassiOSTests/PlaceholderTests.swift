import XCTest
@testable import TrackglassiOS

final class PlaceholderTests: XCTestCase {
    func testHostBundle() throws {
        let prefix = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "TGBundlePrefix") as? String)
        XCTAssertEqual(Bundle.main.bundleIdentifier, "\(prefix).ios")
    }
}
