import XCTest
@testable import TrackglassiOS

final class ThemeTests: XCTestCase {
    func testEveryThemeRoundTripsIncludingCustomAppearance() throws {
        for id in Theme.ID.allCases {
            var theme = Theme.preset(id)
            if id == .custom {
                theme.backgroundRGB = 0x234567; theme.accentRGB = 0xABCDEF
                theme.fingerGlow = .none; theme.showsGrid = true
            }
            XCTAssertEqual(try JSONDecoder().decode(Theme.self, from: JSONEncoder().encode(theme)), theme)
        }
    }
    @MainActor func testSelectionPersistsAndInvalidStoredDataUsesDefault() throws {
        let suite = "ThemeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("bad".utf8), forKey: "surfaceTheme")
        let store = ThemeStore(defaults: defaults)
        XCTAssertEqual(store.theme, .preset(.glassBlack))
        store.select(.preset(.midnightGrid))
        XCTAssertEqual(ThemeStore(defaults: defaults).theme, .preset(.midnightGrid))
    }
}
