import UIKit
import XCTest
@testable import TrackglassiOS

final class ThermalStateTests: XCTestCase {
    func testOnlySeriousAndCriticalThermalStatesSuppressHalos() {
        XCTAssertFalse(TouchSurfaceViewController.suppressesHalos(for: .nominal))
        XCTAssertFalse(TouchSurfaceViewController.suppressesHalos(for: .fair))
        XCTAssertTrue(TouchSurfaceViewController.suppressesHalos(for: .serious))
        XCTAssertTrue(TouchSurfaceViewController.suppressesHalos(for: .critical))
    }

    @MainActor func testSuppressionIsAppliedToTheRendererAndCanBeLifted() {
        let surface = TouchSurfaceView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        XCTAssertFalse(surface.halosSuppressed)
        surface.setHalosSuppressed(true)
        XCTAssertTrue(surface.halosSuppressed)
        surface.setHalosSuppressed(false)
        XCTAssertFalse(surface.halosSuppressed)
    }
}
