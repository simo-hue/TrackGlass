import XCTest
import TrackglassKit
@testable import TrackglassiOS

final class PairingLinkRouterTests: XCTestCase {
    @MainActor func testValidLinkRoutesPayloadAndInvalidLinkDoesNotReplaceIt() throws {
        let router = PairingLinkRouter()
        let payload = try PairingPayload(pairID: Data(repeating: 1, count: 8), pairSecret: Data(repeating: 2, count: 32),
                                         macName: "Mac", bonjourInstanceName: "Mac (pairing)")
        XCTAssertTrue(router.open(payload.url))
        XCTAssertEqual(router.presentation?.payload, payload)
        let presentationID = router.presentation?.id
        XCTAssertFalse(router.open(try XCTUnwrap(URL(string: "trackglass://pair?v=1&id=bad"))))
        XCTAssertEqual(router.presentation?.id, presentationID)
        XCTAssertFalse(router.open(try XCTUnwrap(URL(string: "https://example.com"))))
        XCTAssertTrue(router.open(payload.url))
        XCTAssertNotEqual(router.presentation?.id, presentationID, "A repeated link is a fresh presentation")
        router.showPairing()
        XCTAssertNil(router.presentation?.payload)
    }

    func testPairingSchemeIsRegistered() throws {
        let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        XCTAssertTrue(types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains("trackglass") == true })
    }
}
