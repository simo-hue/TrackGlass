import ApplicationServices
import XCTest

final class InjectorPlaceholderTests: XCTestCase {
    func testAccessibilityAvailable() throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "Accessibility permission is required for injector tests.")
    }
}
