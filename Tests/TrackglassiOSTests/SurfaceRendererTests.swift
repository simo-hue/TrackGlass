import UIKit
import XCTest
import TrackglassKit
@testable import TrackglassiOS

@MainActor
final class SurfaceRendererTests: XCTestCase {
    func testHalosFollowFingersAndOnlyChangedFramesTouchTheLayers() throws {
        let root = CALayer()
        let renderer = SurfaceRenderer(layer: root)
        // Sublayers: background, grid, then the ten halos.
        let halo = try XCTUnwrap(root.sublayers?[2])
        var frame = TouchFrame(sequence: 1)
        frame.append(Contact(contactID: 3, phase: .began, x: 10, y: 20))
        renderer.render(frame, mmPerPoint: 0.1)
        XCTAssertEqual(halo.opacity, 1)
        XCTAssertEqual(halo.position.x, 100, accuracy: 0.001)
        XCTAssertEqual(halo.position.y, 200, accuracy: 0.001)

        halo.position = .zero
        renderer.render(frame, mmPerPoint: 0.1)
        XCTAssertEqual(halo.position, .zero, "the display link re-rendering the same frame changes nothing")
        frame.header.sequence = 2
        frame[0].phase = .stationary
        renderer.render(frame, mmPerPoint: 0.1)
        XCTAssertEqual(halo.position, .zero, "an unchanged position is not written again")
        frame.header.sequence = 3
        frame[0].x = 11
        renderer.render(frame, mmPerPoint: 0.1)
        XCTAssertEqual(halo.position.x, 110, accuracy: 0.001)

        renderer.render(TouchFrame(sequence: 4, isSyntheticLiftoff: true), mmPerPoint: 0.1)
        XCTAssertEqual(halo.opacity, 0, "the halo fades out when the finger lifts")
    }

    func testSuppressedHalosStayHiddenAndReturnWithTheNextRender() throws {
        let root = CALayer()
        let renderer = SurfaceRenderer(layer: root)
        let halo = try XCTUnwrap(root.sublayers?[2])
        var frame = TouchFrame(sequence: 1)
        frame.append(Contact(contactID: 1, phase: .began, x: 5, y: 5))
        renderer.setHalosSuppressed(true)
        renderer.render(frame, mmPerPoint: 0.1)
        XCTAssertEqual(halo.opacity, 0)
        renderer.setHalosSuppressed(false)
        renderer.render(frame, mmPerPoint: 0.1)   // same frame: redrawn because the suppression changed
        XCTAssertEqual(halo.opacity, 1)
    }
}
