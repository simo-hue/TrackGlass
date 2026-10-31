import AVFoundation
import XCTest
@testable import TrackglassiOS

final class NoMacPanelTests: XCTestCase {
    func testHeadlineSaysWhatThePhoneIsDoing() {
        XCTAssertEqual(NoMacView.headline(lastMacName: "", isReconnecting: true, passive: true), "No Mac connected")
        XCTAssertEqual(NoMacView.headline(lastMacName: "Studio", isReconnecting: true, passive: true), "Reconnecting to Studio…")
        XCTAssertEqual(NoMacView.headline(lastMacName: "Studio", isReconnecting: true, passive: false), "Looking for Studio…")
        XCTAssertEqual(NoMacView.headline(lastMacName: "Studio", isReconnecting: false, passive: false), "Not connected to Studio")
        XCTAssertEqual(NoMacView.headline(lastMacName: "Studio", isReconnecting: true, passive: false, lastMacListed: true),
                       "Reconnecting to Studio…", "a Mac in range that refuses (busy, asleep) is not being looked for")
    }

    @MainActor func testPanelWidthAndHeightFollowTheSurface() {
        XCTAssertEqual(OverlayLayout.panelWidth(forSurfaceWidth: 393), 345)
        XCTAssertEqual(OverlayLayout.panelWidth(forSurfaceWidth: 1024), 400, "readable line length on iPad")
        let layout = OverlayLayout()
        layout.update(size: CGSize(width: 320, height: 300))
        XCTAssertEqual(layout.panelWidth, 272)
        XCTAssertEqual(layout.panelMaxHeight, 252)
        XCTAssertEqual(layout.statusWidth, 208)
    }

    func testLocalNetworkDenialIsToldApartFromNoNetwork() {
        XCTAssertTrue(MacBrowser.isLocalNetworkDenial(.dns(-65570)))
        XCTAssertFalse(MacBrowser.isLocalNetworkDenial(.dns(-65563)))
        XCTAssertFalse(MacBrowser.isLocalNetworkDenial(.posix(.ENETDOWN)))
        XCTAssertEqual(MacBrowser.waitingStatus(for: .dns(-65570)), MacBrowser.localNetworkOffStatus)
        XCTAssertEqual(MacBrowser.waitingStatus(for: .posix(.ENETDOWN)), MacBrowser.noWiFiStatus)
    }

    func testOnboardingIsDoneOnceAMacIsPaired() throws {
        let suite = "OnboardingProgressTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(OnboardingProgress.isCompleted(defaults: defaults, hasPairedMacs: { false }))
        XCTAssertTrue(OnboardingProgress.isCompleted(defaults: defaults, hasPairedMacs: { true }),
                      "a phone paired through a link never sees the introduction")
        XCTAssertTrue(OnboardingProgress.isCompleted(defaults: defaults, hasPairedMacs: { false }), "and it is remembered")
        let fresh = "OnboardingProgressTests-\(UUID().uuidString)"
        let other = try XCTUnwrap(UserDefaults(suiteName: fresh))
        defer { other.removePersistentDomain(forName: fresh) }
        OnboardingProgress.markCompleted(defaults: other)
        XCTAssertTrue(OnboardingProgress.isCompleted(defaults: other, hasPairedMacs: { false }))
    }

    @MainActor func testColourEditsOnABuiltInThemeBecomeTheCustomTheme() {
        let aluminum = SettingsSheet.edited(.preset(.aluminum), rgb: 0x112233, background: false)
        XCTAssertEqual(aluminum.id, .custom)
        XCTAssertEqual(aluminum.accentRGB, 0x112233)
        XCTAssertEqual(aluminum.background, .aluminum, "an accent edit keeps the finish")
        let background = SettingsSheet.edited(aluminum, rgb: 0x445566, background: true)
        XCTAssertEqual(background.background, .solid)
        XCTAssertEqual(background.backgroundRGB, 0x445566)
        XCTAssertEqual(SettingsSheet.strengthDescription(0.75), "75 percent")
        XCTAssertEqual(SettingsSheet.trackingDescription(0), "Same as your Mac")
        XCTAssertEqual(SettingsSheet.trackingDescription(0.25), "0.25 faster than your Mac")
        XCTAssertEqual(SettingsSheet.trackingDescription(-0.5), "0.50 slower than your Mac")
    }

    func testScannerExplainsWhyTheCameraStopped() {
        let busy = AVCaptureSession.InterruptionReason.videoDeviceInUseByAnotherClient.rawValue
        let splitView = AVCaptureSession.InterruptionReason.videoDeviceNotAvailableWithMultipleForegroundApps.rawValue
        XCTAssertTrue(QRScannerController.interruptionMessage(rawReason: busy).contains("Another app"))
        XCTAssertTrue(QRScannerController.interruptionMessage(rawReason: splitView).contains("full screen"))
        XCTAssertEqual(QRScannerController.interruptionMessage(rawReason: nil),
                       QRScannerController.interruptionMessage(rawReason: 9_999))
    }
}
