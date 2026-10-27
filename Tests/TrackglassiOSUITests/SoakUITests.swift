import XCTest

/// M9.4 soak driver: moves one finger continuously on the surface for `TG_SOAK_SECONDS`
/// (default 24 h). Run on the paired phone with the Mac connected:
///   xcodebuild -project Trackglass.xcodeproj -scheme TrackglassiOSSoak \
///     -destination 'platform=iOS,id=<device>' test TG_SOAK_SECONDS=86400
/// (a build-setting override; the scheme forwards it to the runner's environment).
/// The app's own container is used, so onboarding and pairing persist from normal use.
final class SoakUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testOneFingerMovesContinuously() throws {
        let app = XCUIApplication()
        app.launch()
        let seconds = TimeInterval(ProcessInfo.processInfo.environment["TG_SOAK_SECONDS"] ?? "") ?? 86_400
        let deadline = Date().addingTimeInterval(seconds)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Trackglass window did not appear")
        // The Macs sheet is presented on every launch; dismiss it so the drags land on the surface.
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 5) {
            done.tap()
            XCTAssertTrue(done.waitForNonExistence(timeout: 5), "Macs sheet did not dismiss")
        }
        XCTAssertFalse(app.navigationBars["Macs"].exists, "the soak must run on the trackpad surface, not a sheet")
        // Stay inside the surface: away from the grip button (top-trailing) and the status pill (top-centre).
        let corners: [(CGFloat, CGFloat)] = [(0.25, 0.35), (0.75, 0.45), (0.65, 0.85), (0.2, 0.7)]
        var index = 0
        var strokes = 0
        while Date() < deadline {
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: corners[index].0, dy: corners[index].1))
            index = (index + 1) % corners.count
            let to = window.coordinate(withNormalizedOffset: CGVector(dx: corners[index].0, dy: corners[index].1))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.05)
            strokes += 1
            if strokes % 500 == 0 {
                XCTAssertEqual(app.state, .runningForeground, "Trackglass left the foreground after \(strokes) strokes")
            }
        }
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertGreaterThan(strokes, 0)
    }
}
