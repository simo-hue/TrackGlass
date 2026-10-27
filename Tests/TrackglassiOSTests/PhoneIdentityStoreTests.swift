import XCTest
@testable import TrackglassiOS

final class PhoneIdentityStoreTests: XCTestCase {
    @MainActor func testMarketingDefaultAndUserNamePersist() throws {
        let suite = "PhoneIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PhoneIdentityStore(defaults: defaults, modelIdentifier: "iPhone16,2")
        XCTAssertEqual(first.name, "iPhone 15 Pro Max")
        first.name = "Simone's phone"
        let second = PhoneIdentityStore(defaults: defaults, modelIdentifier: "iPad8,1")
        XCTAssertEqual(second.peerID, first.peerID)
        XCTAssertEqual(second.name, "Simone's phone")
    }
}
