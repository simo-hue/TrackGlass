import AppKit
import Foundation
import Observation
import Sparkle

/// Sparkle 2 (SPEC §6.11): automatic daily checks against the EdDSA-signed appcast in `SUFeedURL`,
/// plus the explicit "Check for Updates…" entry points in the menu bar menu and Settings → General.
@MainActor @Observable
final class UpdateController {
    private let controller: SPUStandardUpdaterController
    /// Sparkle keeps its user-driver delegate weakly.
    private let reminders: UpdateReminderDelegate
    /// Mirrors the updater's preference so SwiftUI can bind to it.
    var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    init(startsUpdater: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil) {
        // Under XCTest the host app must not schedule checks or show update UI.
        let reminders = UpdateReminderDelegate()
        self.reminders = reminders
        controller = SPUStandardUpdaterController(startingUpdater: startsUpdater, updaterDelegate: nil, userDriverDelegate: reminders)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        lastCheck = controller.updater.lastUpdateCheckDate
        canCheckForUpdates = controller.updater.canCheckForUpdates
        // Stored and fed by KVO so SwiftUI redraws when a check starts, ends or records its date; computed
        // pass-throughs to the updater are invisible to Observation.
        observations = [
            // Sparkle changes these on the main thread; the values are read there too (SPUUpdater is main-actor).
            controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
                MainActor.assumeIsolated {
                    self?.canCheckForUpdates = updater.canCheckForUpdates
                    self?.lastCheck = updater.lastUpdateCheckDate
                }
            },
            controller.updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.lastCheck = updater.lastUpdateCheckDate }
            },
        ]
    }

    private(set) var lastCheck: Date?
    /// False while a check is running (and before the updater started): the menu and Settings disable their buttons.
    private(set) var canCheckForUpdates: Bool
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    func checkForUpdates() {
        guard controller.updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }
}

/// Sparkle's gentle scheduled-update reminders for a menu-bar (LSUIElement) app (SPEC §6.11): the standard driver still
/// shows the update, but the app first becomes a regular app with a Dock icon — badged when the check was scheduled —
/// so the alert is not lost behind other windows, and it returns to the menu bar when the update session ends.
/// Sparkle calls these on the main thread.
final class UpdateReminderDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        let scheduled = !state.userInitiated
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            if scheduled { NSApp.dockTile.badgeLabel = "1" }
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { NSApp.dockTile.badgeLabel = nil }
    }

    func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            NSApp.dockTile.badgeLabel = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
