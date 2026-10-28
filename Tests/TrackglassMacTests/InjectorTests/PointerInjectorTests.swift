import CoreGraphics
import XCTest
import TrackglassEngine
@testable import TrackglassMac

final class PointerInjectorTests: XCTestCase {
    func testPointerMovesBecomeDraggedEventsWhileAButtonIsHeld() throws {
        var pointerEvents: [CGEvent] = []
        var buttonEvents: [CGEvent] = []
        let injector = QuartzInjector(postScrollEvent: { buttonEvents.append($0) }, postPointerEvent: { pointerEvents.append($0) })

        injector.inject(.pointerMove(dx: 3, dy: 0))
        XCTAssertEqual(pointerEvents.last?.type, .mouseMoved)

        injector.inject(.button(kind: .left, phase: .down, clickCount: 1))
        injector.inject(.pointerMove(dx: 0, dy: 3))
        XCTAssertEqual(pointerEvents.last?.type, .leftMouseDragged)
        XCTAssertEqual(pointerEvents.last?.getIntegerValueField(.mouseEventDeltaY), 3)

        injector.inject(.button(kind: .left, phase: .up, clickCount: 1))
        injector.inject(.pointerMove(dx: -3, dy: 0))
        XCTAssertEqual(pointerEvents.last?.type, .mouseMoved)

        injector.inject(.button(kind: .right, phase: .down, clickCount: 1))
        injector.inject(.pointerMove(dx: 0, dy: -3))
        XCTAssertEqual(pointerEvents.last?.type, .rightMouseDragged)
        XCTAssertEqual(pointerEvents.last?.getIntegerValueField(.mouseEventButtonNumber), Int64(CGMouseButton.right.rawValue))
        injector.inject(.button(kind: .right, phase: .up, clickCount: 1))

        XCTAssertEqual(buttonEvents.map(\.type), [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp])
        XCTAssertEqual(pointerEvents.count, 4)
    }

    func testSubPointMotionAccumulatesInsteadOfBeingDropped() {
        var pointerEvents: [CGEvent] = []
        let injector = QuartzInjector(postScrollEvent: { _ in }, postPointerEvent: { pointerEvents.append($0) })
        for _ in 0..<4 { injector.inject(.pointerMove(dx: 0.3, dy: 0)) }
        // 0.3 + 0.3 rounds to 1 after the second call; 1.2 total → one event of 1 point so far.
        XCTAssertEqual(pointerEvents.count, 1)
        XCTAssertEqual(pointerEvents.first?.getIntegerValueField(.mouseEventDeltaX), 1)
    }

    func testDegradedListReportsTheFallbacksTheInjectorActuallyUses() {
        // Even with every private symbol resolved, force click and Notification Center use their fallbacks today (G-FORCE/G-NC pending).
        var full = PrivateAPICapabilities()
        full.gestureEvents = true; full.dockSwipe = true; full.forceEvent = true; full.fluidTouchGesture = true
        let list = QuartzInjector.degradedGestures(capabilities: full, path: .legacyFields, trials: PrivateGestureTrials())
        XCTAssertTrue(list.contains("Force click uses Look Up"))
        XCTAssertTrue(list.contains("Notification Center uses Accessibility"))
        XCTAssertFalse(list.contains { $0.hasPrefix("Spaces") })
        // A gate trial replaces its fallback line so the menu shows what the injector will do during the test.
        let trial = QuartzInjector.degradedGestures(capabilities: full, path: .legacyFields,
                                                    trials: PrivateGestureTrials(notificationCenter: true, forceClick: true))
        XCTAssertTrue(trial.contains("Force click: private event trial (G-FORCE)"))
        XCTAssertTrue(trial.contains("Notification Center: private gesture trial (G-NC)"))
        XCTAssertFalse(trial.contains("Force click uses Look Up"))
        XCTAssertFalse(trial.contains("Notification Center uses Accessibility"))
        // Trials without the mechanism they need still report the fallback.
        let none = QuartzInjector.degradedGestures(capabilities: PrivateAPICapabilities(), path: .legacyFields,
                                                   trials: PrivateGestureTrials(notificationCenter: true, forceClick: true))
        XCTAssertTrue(none.contains("Force click uses Look Up"))
        XCTAssertTrue(none.contains("Notification Center uses Accessibility"))
    }
}
