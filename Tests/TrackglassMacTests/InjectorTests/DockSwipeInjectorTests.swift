import CoreGraphics
import TrackglassEngine
import XCTest
@testable import TrackglassMac

final class DockSwipeInjectorTests: XCTestCase {
    func testAttachedPathBuildsOneCompanionAndRejectsMissingAttachment() throws {
        let factory = DockSwipeEventFactory()
        let pair = try XCTUnwrap(factory.make(kind: .horizontal, delta: 0.4, phase: .ended, exitVelocity: 2,
                                             inverted: true, source: nil, location: .zero))
        guard TGPrivateAPIGetCapabilities().hidEventClass else { throw XCTSkip("HIDEvent is unavailable on this OS") }
        var attached = false
        let event = DockSwipeEventFactory.attached(from: pair.1, attach: { event, hid in
            attached = true
            XCTAssertEqual(event.type, TGEventTypeDockCompanion)
            XCTAssertTrue((hid as AnyObject) is NSObject)
            return true
        })
        XCTAssertNotNil(event); XCTAssertTrue(attached)
        XCTAssertNil(DockSwipeEventFactory.attached(from: pair.1, attach: { _, _ in false }))
    }
    func testMissingCapabilitiesUseOnlyTerminalShortcuts() {
        var keys: [CGEvent] = []
        let injector = QuartzInjector(dockPath: .attachedHIDEvent, capabilities: PrivateAPICapabilities(),
            postKeyEvent: { keys.append($0) }, postDockEvent: { _ in XCTFail("Private event posted") })
        for (kind, progress, key) in [(DockSwipeKind.horizontal, 0.7, 124), (.horizontal, -0.7, 123),
                                      (.vertical, 0.7, 126), (.vertical, -0.7, 125), (.pinch, 0.7, 103)] {
            keys.removeAll()
            injector.inject(.dockSwipe(kind: kind, progressDelta: progress, phase: .began, exitVelocity: 0))
            XCTAssertTrue(keys.isEmpty)
            injector.inject(.dockSwipe(kind: kind, progressDelta: 0, phase: .ended, exitVelocity: 1))
            XCTAssertEqual(keys.count, 2)
            XCTAssertEqual(keys.first?.getIntegerValueField(.keyboardEventKeycode), Int64(key))
        }
        keys.removeAll()
        injector.inject(.dockSwipe(kind: .pinch, progressDelta: -0.7, phase: .began, exitVelocity: 0))
        injector.inject(.dockSwipe(kind: .pinch, progressDelta: 0, phase: .ended, exitVelocity: 1))
        XCTAssertTrue(keys.isEmpty)
        injector.inject(.dockSwipe(kind: .horizontal, progressDelta: 0.7, phase: .began, exitVelocity: 0))
        injector.inject(.dockSwipe(kind: .horizontal, progressDelta: 0, phase: .cancelled, exitVelocity: 1))
        XCTAssertTrue(keys.isEmpty)
        XCTAssertFalse(QuartzInjector.degradedGestures(capabilities: PrivateAPICapabilities()).isEmpty)
    }
    func testLegacyFieldsAccumulateAndRetainTerminalProgress() throws {
        let factory = DockSwipeEventFactory()
        for (kind, value) in [(DockSwipeKind.horizontal, 1), (.vertical, 2), (.pinch, 3)] {
            _ = factory.make(kind: kind, delta: 0.25, phase: .began, exitVelocity: 0, inverted: true, source: nil, location: .zero)
            _ = factory.make(kind: kind, delta: -0.1, phase: .changed, exitVelocity: 0, inverted: true, source: nil, location: .zero)
            let pair = try XCTUnwrap(factory.make(kind: kind, delta: 0, phase: .cancelled, exitVelocity: -3, inverted: true, source: nil, location: .zero))
            XCTAssertEqual(pair.0.type, TGEventTypeGesture)
            XCTAssertEqual(pair.0.getIntegerValueField(TGFieldDockMarker), TGDockMarkerValue)
            let event = pair.1
            XCTAssertEqual(event.type, TGEventTypeDockCompanion)
            XCTAssertEqual(event.getIntegerValueField(TGFieldHIDEventType), Int64(TGHIDDockSwipe))
            XCTAssertEqual(event.getIntegerValueField(TGFieldDockMarker), TGDockMarkerValue)
            for field in [TGFieldGesturePhase, TGFieldDockPhase] {
                XCTAssertEqual(event.getIntegerValueField(field), Int64(TGPhaseCancelled))
            }
            XCTAssertEqual(event.getDoubleValueField(TGFieldDockProgress), 0.15, accuracy: 0.000001)
            XCTAssertEqual(event.getIntegerValueField(TGFieldDockProgressFloatBits), Int64(Float(0.15).bitPattern))
            for field in [TGFieldDockTypeDenormal, TGFieldDockTypeDenormalAlternate] {
                XCTAssertEqual(event.getDoubleValueField(field), Double(Float(bitPattern: UInt32(value))))
            }
            for field in [TGFieldDockType, TGFieldDockTypeAlternate] {
                XCTAssertEqual(event.getIntegerValueField(field), Int64(value))
            }
            XCTAssertEqual(event.getIntegerValueField(TGFieldDockInverted), 1)
            for field in [TGFieldDockExitSpeedX, TGFieldDockExitSpeedY] {
                XCTAssertEqual(event.getDoubleValueField(field), -3)
            }
        }
    }
    func testEndRepostsAndNewGestureInvalidatesOldEnd() {
        var time: UInt64 = 0
        var events: [CGEvent] = []
        let injector = QuartzInjector(dockPath: .legacyFields, postDockEvent: { events.append($0) }, now: { time })
        injector.inject(.dockSwipe(kind: .horizontal, progressDelta: 0.7, phase: .began, exitVelocity: 0))
        injector.inject(.dockSwipe(kind: .horizontal, progressDelta: 0, phase: .ended, exitVelocity: 1))
        XCTAssertEqual(events.count, 4)
        time = 199_000_000; injector.tick(); XCTAssertEqual(events.count, 4)
        time = 200_000_000; injector.tick(); XCTAssertEqual(events.count, 6)
        time = 500_000_000; injector.tick(); XCTAssertEqual(events.count, 8)
        injector.inject(.dockSwipe(kind: .horizontal, progressDelta: 0.7, phase: .began, exitVelocity: 0))
        injector.inject(.dockSwipe(kind: .horizontal, progressDelta: 0, phase: .ended, exitVelocity: 1))
        injector.inject(.dockSwipe(kind: .vertical, progressDelta: 0.2, phase: .began, exitVelocity: 0))
        time = 2_000_000_000; injector.tick(); XCTAssertEqual(events.count, 14)
    }
}
