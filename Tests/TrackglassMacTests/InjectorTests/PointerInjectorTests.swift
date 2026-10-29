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

    func testRightClickWhileTheLeftButtonIsHeldKeepsTheLeftDragGoing() {
        // A two-finger tap during a drag lock (or the drag grace window) clicks right while left stays held.
        var pointerEvents: [CGEvent] = []
        let injector = QuartzInjector(postScrollEvent: { _ in }, postPointerEvent: { pointerEvents.append($0) })
        injector.inject(.button(kind: .left, phase: .down, clickCount: 2))
        injector.inject(.button(kind: .right, phase: .down, clickCount: 1))
        injector.inject(.button(kind: .right, phase: .up, clickCount: 1))
        injector.inject(.pointerMove(dx: 4, dy: 0))
        XCTAssertEqual(pointerEvents.last?.type, .leftMouseDragged)
        injector.inject(.button(kind: .left, phase: .up, clickCount: 2))
        injector.inject(.pointerMove(dx: -4, dy: 0))
        XCTAssertEqual(pointerEvents.last?.type, .mouseMoved)
    }

    func testSubPointMotionAccumulatesInsteadOfBeingDropped() {
        var pointerEvents: [CGEvent] = []
        let injector = QuartzInjector(postScrollEvent: { _ in }, postPointerEvent: { pointerEvents.append($0) })
        for _ in 0..<4 { injector.inject(.pointerMove(dx: 0.3, dy: 0)) }
        // 0.3 + 0.3 rounds to 1 after the second call; 1.2 total → one event of 1 point so far.
        XCTAssertEqual(pointerEvents.count, 1)
        XCTAssertEqual(pointerEvents.first?.getIntegerValueField(.mouseEventDeltaX), 1)
    }

    func testPointerPositionIsTakenFromTheLastPostForFiftyMilliseconds() {
        // P6: inside a gesture the pointer is where the last posted event put it; the window server is asked again
        // only after a pause, when another device may have moved the pointer.
        var time: UInt64 = 0
        var queries = 0
        var posted: [CGEvent] = []
        let injector = QuartzInjector(postScrollEvent: { posted.append($0) }, postPointerEvent: { posted.append($0) },
                                      now: { time }, queryLocation: { queries += 1; return CGPoint(x: 100, y: 100) })
        injector.inject(.pointerMove(dx: 5, dy: 0))
        time = 8_000_000; injector.inject(.pointerMove(dx: 5, dy: 0))
        time = 16_000_000; injector.inject(.button(kind: .left, phase: .down, clickCount: 1))
        time = 57_000_000; injector.inject(.button(kind: .left, phase: .up, clickCount: 1))
        XCTAssertEqual(queries, 1)
        XCTAssertEqual(posted.map(\.location), [CGPoint(x: 105, y: 100), CGPoint(x: 110, y: 100),
                                                 CGPoint(x: 110, y: 100), CGPoint(x: 110, y: 100)])
        time = 58_000_000; injector.inject(.pointerMove(dx: 1, dy: 0))   // 50 ms after the last move: asks again
        XCTAssertEqual(queries, 2)
        XCTAssertEqual(posted.last?.location, CGPoint(x: 101, y: 100))
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
