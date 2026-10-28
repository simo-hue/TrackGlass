import XCTest
@testable import TrackglassiOS

/// The links the app shows (§1.5, §5.1) and the Info.plist / privacy-manifest keys App Review and
/// the OS depend on (§5.5, §5.10). The hosted bundle is the real app, so these read `Bundle.main`.
final class AppLinksAndBundleKeysTests: XCTestCase {
    func testLinksDeriveFromTheXcconfigKeys() throws {
        let website = try XCTUnwrap(AppLinks.website, "TGWebsiteURL must be in Info.plist")
        let repository = try XCTUnwrap(AppLinks.repository, "TGRepoURL must be in Info.plist")
        XCTAssertEqual(AppLinks.privacyPolicy?.absoluteString, website.absoluteString + "/privacy.html")
        XCTAssertEqual(AppLinks.support?.absoluteString, website.absoluteString + "/support.html")
        XCTAssertEqual(AppLinks.macDownload?.absoluteString, repository.absoluteString + "/releases/latest",
                       "§1.5: the Mac download page is the newest GitHub release")
        XCTAssertEqual(website.scheme, "https")
        XCTAssertEqual(repository.scheme, "https")
    }

    func testMissingOrEmptyInfoKeyYieldsNoLink() {
        XCTAssertNil(AppLinks.url(forInfoKey: "TGDoesNotExist"))
    }

    func testUsageStringsAndLocalNetworkKeysAreExact() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(info["NSLocalNetworkUsageDescription"] as? String,
                       "Trackglass finds and talks to Trackglass for Mac on your local network.")
        XCTAssertEqual(info["NSCameraUsageDescription"] as? String, "Scan the pairing code shown by Trackglass for Mac.")
        XCTAssertEqual(Set(try XCTUnwrap(info["NSBonjourServices"] as? [String])), ["_trackglass._tcp", "_trackglass._udp"])
        XCTAssertEqual(info["CADisableMinimumFrameDurationOnPhone"] as? Bool, true, "§5.4: 120 Hz touch delivery")
        XCTAssertEqual(info["ITSAppUsesNonExemptEncryption"] as? Bool, false, "§5.10 export compliance")
        XCTAssertNil(info["UIBackgroundModes"], "§5.5 Decision: the app stops when backgrounded")
    }

    func testPrivacyManifestIsBundledWithTheDeclaredReasons() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
                                "§5.10: a missing manifest is rejected at upload (ITMS-91053)")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty, true, "Data Not Collected")
        let accessed = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: [String]] = [:]
        for entry in accessed {
            let type = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)
            reasons[type] = entry["NSPrivacyAccessedAPITypeReasons"] as? [String]
        }
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategorySystemBootTime"], ["35F9.1"])
    }
}
