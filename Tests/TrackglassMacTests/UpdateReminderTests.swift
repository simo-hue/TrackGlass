import AppKit
import XCTest
@testable import TrackglassMac

final class UpdateReminderTests: XCTestCase {
    /// SPEC §6.11: the menu-bar app opts in to Sparkle's gentle reminders and goes back to the menu bar (no Dock icon,
    /// no badge) once an update session ends.
    @MainActor func testGentleRemindersAreOnAndTheSessionEndRestoresTheMenuBarApp() {
        let delegate = UpdateReminderDelegate()
        XCTAssertTrue(delegate.supportsGentleScheduledUpdateReminders)
        delegate.standardUserDriverWillFinishUpdateSession()
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        XCTAssertNil(NSApp.dockTile.badgeLabel)
    }
}
