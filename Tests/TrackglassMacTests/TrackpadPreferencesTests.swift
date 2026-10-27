import Foundation
import XCTest
import TrackglassEngine
@testable import TrackglassMac

final class TrackpadPreferencesTests: XCTestCase {
    func testCurrentHostOverridesSharedGlobalWithoutDroppingSharedKeys() {
        let merged = TrackpadPreferences.mergeGlobal(shared: ["com.apple.trackpad.scaling": 1.0, "com.apple.trackpad.forceClick": true],
            currentHost: ["com.apple.trackpad.forceClick": false])
        XCTAssertEqual(merged["com.apple.trackpad.scaling"] as? Double, 1.0)
        XCTAssertEqual(merged["com.apple.trackpad.forceClick"] as? Bool, false)
    }
    func testUnknownValuesAreReportedAndRemovedForDefaults() {
        var reported = Set<String>()
        let valid = TrackpadPreferences.validated(["Clicking": 7, "TrackpadPinch": true,
            "com.apple.trackpad.scaling": Double.nan, "TrackpadThreeFingerHorizSwipeGesture": 99]) { reported.insert($0) }
        XCTAssertEqual(reported, ["Clicking", "com.apple.trackpad.scaling", "TrackpadThreeFingerHorizSwipeGesture"])
        XCTAssertEqual(valid.count, 1)
        XCTAssertEqual(valid["TrackpadPinch"] as? Bool, true)
    }
    func testPhoneTrackingOverrideClampsWithoutChangingMacSnapshot() {
        let settings = TrackpadSettings(trackingSpeed: 0.5)
        XCTAssertEqual(ControlListener.effectiveSettings(settings, override: 0).trackingSpeed, 0.5)
        XCTAssertEqual(ControlListener.effectiveSettings(settings, override: 0.5).trackingSpeed, 1)
        XCTAssertEqual(ControlListener.effectiveSettings(settings, override: -1).trackingSpeed, 0)
        XCTAssertEqual(ControlListener.effectiveSettings(TrackpadSettings(trackingSpeed: 2.8), override: 1).trackingSpeed, 3)
        XCTAssertEqual(ControlListener.effectiveSettings(settings, override: .nan).trackingSpeed, 0.5)
        XCTAssertEqual(ControlListener.message(for: settings).trackingSpeed, 0.5)
    }
    func testMultiFingerAndDockPreferences() throws {
        let builtIn = try TrackpadPreferences.parseFixture(fixture(), bluetoothTrackpadConnected: false)
        let bluetooth = try TrackpadPreferences.parseFixture(fixture(), bluetoothTrackpadConnected: true)
        XCTAssertEqual(builtIn.threeFingerHorizontalGesture, 0)
        XCTAssertEqual(builtIn.fourFingerHorizontalGesture, 1)
        XCTAssertEqual(builtIn.threeFingerVerticalGesture, 2)
        XCTAssertEqual(builtIn.fourFingerVerticalGesture, 0)
        XCTAssertEqual(builtIn.fourFingerPinchGesture, 1)
        XCTAssertEqual(builtIn.fiveFingerPinchGesture, 2)
        XCTAssertEqual(builtIn.notificationCenterEdgeGesture, 0)
        XCTAssertEqual(bluetooth.threeFingerHorizontalGesture, 2)
        XCTAssertEqual(bluetooth.fourFingerHorizontalGesture, 2)
        XCTAssertEqual(bluetooth.threeFingerVerticalGesture, 2)
        XCTAssertEqual(bluetooth.fourFingerVerticalGesture, 2)
        XCTAssertEqual(bluetooth.fourFingerPinchGesture, 2)
        XCTAssertEqual(bluetooth.fiveFingerPinchGesture, 2)
        XCTAssertEqual(bluetooth.notificationCenterEdgeGesture, 3)
        for value in [builtIn, bluetooth] {
            XCTAssertFalse(value.missionControlEnabled)
            XCTAssertTrue(value.appExposeEnabled)
            XCTAssertFalse(value.launchpadEnabled)
            XCTAssertTrue(value.showDesktopEnabled)
        }
    }
    func testParsesBuiltInPreferencesFixture() throws {
        let settings = try TrackpadPreferences.parseFixture(fixture(), bluetoothTrackpadConnected: false)
        XCTAssertFalse(settings.clicking)
        XCTAssertTrue(settings.trackpadRightClick)
        XCTAssertEqual(settings.cornerSecondaryClick, 1)
        XCTAssertTrue(settings.dragging)
        XCTAssertTrue(settings.dragLock)
        XCTAssertFalse(settings.threeFingerDrag)
        XCTAssertFalse(settings.forceClickEnabled)
        XCTAssertEqual(settings.threeFingerTapGesture, 0)
        XCTAssertFalse(settings.naturalScrolling)
        XCTAssertEqual(settings.trackingSpeed, 1.5)
        XCTAssertEqual(settings.doubleClickIntervalNs, 500_000_000)
    }

    func testBluetoothTrackpadDomainWinsWhenConnected() throws {
        let settings = try TrackpadPreferences.parseFixture(fixture(), bluetoothTrackpadConnected: true)
        XCTAssertTrue(settings.clicking)
        XCTAssertFalse(settings.trackpadRightClick)
        XCTAssertEqual(settings.cornerSecondaryClick, 2)
        XCTAssertFalse(settings.dragging)
        XCTAssertFalse(settings.dragLock)
        XCTAssertTrue(settings.threeFingerDrag)
        XCTAssertTrue(settings.forceClickEnabled)
    }

    private func fixture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/TrackpadPreferences.plist")
        return try Data(contentsOf: url)
    }

    func testScrollPreferencesSelectDeviceDomainAndTransmitSnapshot() throws {
        for bluetooth in [false, true] {
            let settings = try TrackpadPreferences.parseFixture(fixture(), bluetoothTrackpadConnected: bluetooth)
            XCTAssertEqual(settings.scrollEnabled, bluetooth)
            XCTAssertEqual(settings.horizontalScrollEnabled, !bluetooth)
            XCTAssertEqual(settings.momentumScrollEnabled, bluetooth)
            XCTAssertEqual(settings.pinchEnabled, !bluetooth)
            XCTAssertEqual(settings.rotateEnabled, bluetooth)
            XCTAssertEqual(settings.smartZoomEnabled, !bluetooth)
            XCTAssertFalse(settings.swipeNavigationEnabled)
            let message = ControlListener.message(for: settings)
            XCTAssertEqual(message.scrollEnabled, bluetooth ? 1 : 0)
            XCTAssertEqual(message.horizontalScrollEnabled, bluetooth ? 0 : 1)
            XCTAssertEqual(message.momentumScrollEnabled, bluetooth ? 1 : 0)
            XCTAssertEqual(message.pinchEnabled, bluetooth ? 0 : 1)
            XCTAssertEqual(message.rotateEnabled, bluetooth ? 1 : 0)
            XCTAssertEqual(message.smartZoomEnabled, bluetooth ? 0 : 1)
            XCTAssertEqual(message.swipeNavigationEnabled, 0)
        }
    }

    func testMissingScrollPreferencesAndOldRecordingSettingsDefaultEnabled() throws {
        let empty = try PropertyListSerialization.data(fromPropertyList:
            ["builtIn": [:], "bluetooth": [:], "global": [:]], format: .xml, options: 0)
        let parsed = try TrackpadPreferences.parseFixture(empty, bluetoothTrackpadConnected: false)
        let oldRecording = try JSONDecoder().decode(TrackpadSettings.self, from: Data("{}".utf8))
        for settings in [parsed, oldRecording] {
            XCTAssertTrue(settings.scrollEnabled)
            XCTAssertTrue(settings.horizontalScrollEnabled)
            XCTAssertTrue(settings.momentumScrollEnabled)
            XCTAssertTrue(settings.pinchEnabled)
            XCTAssertTrue(settings.rotateEnabled)
            XCTAssertTrue(settings.smartZoomEnabled)
            XCTAssertTrue(settings.swipeNavigationEnabled)
        }
    }
}
