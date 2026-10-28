import Foundation
import Observation
import Sparkle

/// Sparkle 2 (SPEC §6.11): automatic daily checks against the EdDSA-signed appcast in `SUFeedURL`,
/// plus the explicit "Check for Updates…" entry points in the menu bar menu and Settings → General.
@MainActor @Observable
final class UpdateController {
    private let controller: SPUStandardUpdaterController
    /// Mirrors the updater's preference so SwiftUI can bind to it.
    var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    init(startsUpdater: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil) {
        // Under XCTest the host app must not schedule checks or show update UI.
        controller = SPUStandardUpdaterController(startingUpdater: startsUpdater, updaterDelegate: nil, userDriverDelegate: nil)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    func checkForUpdates() { controller.checkForUpdates(nil) }
}
