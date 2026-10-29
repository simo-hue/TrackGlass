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

    func testKeyboardFallbackSendsTheModifiersTheSystemShortcutsAreRegisteredWith() {
        // com.apple.symbolichotkeys: Spaces / Mission Control / App Exposé = arrow + Control|Fn, Show Desktop = F11 + Fn.
        var keys: [CGEvent] = []
        let injector = QuartzInjector(dockPath: .attachedHIDEvent, capabilities: PrivateAPICapabilities(),
            postKeyEvent: { keys.append($0) }, postDockEvent: { _ in XCTFail("Private event posted") })
        for kind in [DockSwipeKind.horizontal, .vertical] {
            keys.removeAll()
            injector.inject(.dockSwipe(kind: kind, progressDelta: 0.7, phase: .began, exitVelocity: 0))
            injector.inject(.dockSwipe(kind: kind, progressDelta: 0, phase: .ended, exitVelocity: 1))
            XCTAssertEqual(keys.count, 2)
            XCTAssertTrue(keys.allSatisfy { $0.flags.contains([.maskControl, .maskSecondaryFn]) }, "\(kind)")
        }
        keys.removeAll()
        injector.inject(.dockSwipe(kind: .pinch, progressDelta: 0.7, phase: .began, exitVelocity: 0))
        injector.inject(.dockSwipe(kind: .pinch, progressDelta: 0, phase: .ended, exitVelocity: 1))
        XCTAssertEqual(keys.first?.getIntegerValueField(.keyboardEventKeycode), 103)
        XCTAssertTrue(keys.allSatisfy { $0.flags.contains(.maskSecondaryFn) && !$0.flags.contains(.maskControl) })
    }

    func testDockSwipesFollowTheScrollDirectionSettingBeforeAnyScroll() {
        var events: [CGEvent] = []
        var capabilities = PrivateAPICapabilities()
        capabilities.gestureEvents = true
        let injector = QuartzInjector(dockPath: .legacyFields, capabilities: capabilities, postDockEvent: { events.append($0) })
        injector.settingsDidChange(TrackpadSettings(naturalScrolling: false))
        injector.inject(.dockSwipe(kind: .horizontal, progressDelta: 0.3, phase: .began, exitVelocity: 0))
        XCTAssertEqual(events.last?.getIntegerValueField(TGFieldDockInverted), 0)
        injector.settingsDidChange(TrackpadSettings(naturalScrolling: true))
        injector.inject(.dockSwipe(kind: .horizontal, progressDelta: 0.3, phase: .began, exitVelocity: 0))
        XCTAssertEqual(events.last?.getIntegerValueField(TGFieldDockInverted), 1)
    }

    func testADockSwipeKeepsTheDirectionItBeganWith() {
        // F11: a settings change applied while the fingers are down must not flip the swipe under them.
        var events: [CGEvent] = []
        var capabilities = PrivateAPICapabilities()
        capabilities.gestureEvents = true
        let injector = QuartzInjector(dockPath: .legacyFields, capabilities: capabilities, postDockEvent: { events.append($0) })
        injector.settingsDidChange(TrackpadSettings(naturalScrolling: true))
        injector.inject(.dockSwipe(kind: .horizontal, progressDelta: 0.3, phase: .began, exitVelocity: 0))
        injector.settingsDidChange(TrackpadSettings(naturalScrolling: false))
        injector.inject(.dockSwipe(kind: .horizontal, progressDelta: 0.3, phase: .changed, exitVelocity: 0))
        injector.inject(.dockSwipe(kind: .horizontal, progressDelta: 0, phase: .ended, exitVelocity: 1))
        let companions = events.filter { $0.type == TGEventTypeDockCompanion }
        XCTAssertEqual(companions.count, 3)
        XCTAssertTrue(companions.allSatisfy { $0.getIntegerValueField(TGFieldDockInverted) == 1 })
        injector.inject(.dockSwipe(kind: .horizontal, progressDelta: 0.3, phase: .began, exitVelocity: 0))
        XCTAssertEqual(events.last?.getIntegerValueField(TGFieldDockInverted), 0, "the next swipe uses the new setting")
    }

    func testFlushPostsAPendingDockEndAtOnce() {
        // A session that ends inside the re-post window must not drop the §6.9.4 safety-net end.
        var time: UInt64 = 0
        var events: [CGEvent] = []
        var capabilities = PrivateAPICapabilities()
        capabilities.gestureEvents = true
        let injector = QuartzInjector(dockPath: .legacyFields, capabilities: capabilities,
                                      postDockEvent: { events.append($0) }, now: { time })
        injector.inject(.dockSwipe(kind: .horizontal, progressDelta: 0.7, phase: .began, exitVelocity: 0))
        injector.inject(.dockSwipe(kind: .horizontal, progressDelta: 0, phase: .ended, exitVelocity: 1))
        XCTAssertEqual(events.count, 4)
        injector.flush()
        XCTAssertEqual(events.count, 6)
        XCTAssertFalse(injector.needsTick)
        time = 1_000_000_000; injector.tick()
        XCTAssertEqual(events.count, 6)
    }

    func testKeyboardFallbackNeedsHalfASwipe() {
        // Owner decision 2026-10-28: the discrete fallback fires only at |progress| ≥ 0.5 (the spaceSwitched haptic's
        // threshold); a shorter swipe snaps back (§10.3 C7: a 40 mm swipe switches nothing).
        var keys: [CGEvent] = []
        let injector = QuartzInjector(dockPath: .attachedHIDEvent, capabilities: PrivateAPICapabilities(),
            postKeyEvent: { keys.append($0) }, postDockEvent: { _ in XCTFail("Private event posted") })
        for (progress, expected) in [(0.36, 0), (-0.49, 0), (0.5, 2), (-0.5, 2), (1.2, 2)] {
            keys.removeAll()
            injector.inject(.dockSwipe(kind: .horizontal, progressDelta: progress, phase: .began, exitVelocity: 0))
            injector.inject(.dockSwipe(kind: .horizontal, progressDelta: 0, phase: .ended, exitVelocity: 1))
            XCTAssertEqual(keys.count, expected, "progress \(progress)")
        }
        XCTAssertEqual(QuartzInjector.fallbackProgressThreshold, 0.5)
    }

    func testLegacyDockTrialSelectsTheLegacyPathOnlyOnMacOS27() {
        let trial = PrivateGestureTrials(legacyDockSwipes: true)
        XCTAssertEqual(DockSwipePath.resolved(trials: trial), .legacyFields)
        var full = PrivateAPICapabilities()
        full.gestureEvents = true
        if #available(macOS 27, *) {
            XCTAssertEqual(DockSwipePath.resolved(trials: PrivateGestureTrials()), .attachedHIDEvent)
            XCTAssertTrue(DockSwipePath.isLegacyTrial(trial))
            let list = QuartzInjector.degradedGestures(capabilities: full, path: .legacyFields, trials: trial)
            XCTAssertTrue(list.contains { $0.hasSuffix("legacy dock-swipe trial (macOS 27)") }, "\(list)")
            XCTAssertFalse(list.contains { $0.hasPrefix("Spaces, Mission Control, App Exposé and Show Desktop use shortcuts") })
        } else {
            XCTAssertEqual(DockSwipePath.resolved(trials: PrivateGestureTrials()), .legacyFields)
            XCTAssertFalse(DockSwipePath.isLegacyTrial(trial), "below the cut line the legacy path is not a trial")
        }
        // With the trial on, a dock swipe posts the legacy e29/e30 pair instead of keyboard shortcuts.
        var docks: [CGEvent] = []
        var keys: [CGEvent] = []
        let injector = QuartzInjector(dockPath: .legacyFields, capabilities: full, trials: trial,
            postKeyEvent: { keys.append($0) }, postDockEvent: { docks.append($0) })
        injector.inject(.dockSwipe(kind: .horizontal, progressDelta: 0.7, phase: .began, exitVelocity: 0))
        XCTAssertEqual(docks.map(\.type), [TGEventTypeGesture, TGEventTypeDockCompanion])
        XCTAssertTrue(keys.isEmpty)
    }

    func testAttachedPathHIDEventCarriesKindPhaseProgressAndVelocity() throws {
        // §10.1: the attached DockSwipePath asserted field by field (SPEC §6.9.4 macOS 27+ construction).
        guard TGPrivateAPIGetCapabilities().hidEventClass else { throw XCTSkip("HIDEvent is unavailable on this OS") }
        let factory = DockSwipeEventFactory()
        _ = factory.make(kind: .vertical, delta: 0.3, phase: .began, exitVelocity: 0, inverted: false, source: nil, location: .zero)
        let pair = try XCTUnwrap(factory.make(kind: .vertical, delta: 0, phase: .ended, exitVelocity: 4,
                                              inverted: false, source: nil, location: CGPoint(x: 12, y: 34)))
        var captured: Any?
        let carrier = try XCTUnwrap(DockSwipeEventFactory.attached(from: pair.1, attach: { _, hid in captured = hid; return true }))
        XCTAssertEqual(carrier.type, TGEventTypeDockCompanion)
        XCTAssertEqual(carrier.location, CGPoint(x: 12, y: 34))
        let hid = try XCTUnwrap(captured)
        var type: UInt32 = 0
        guard TGHIDEventGetType(hid, &type) else { throw XCTSkip("HIDEvent does not expose its fields on this OS") }
        XCTAssertEqual(Int(type), Int(TGHIDDockSwipe))
        var options: UInt32 = 0
        if TGHIDEventGetOptions(hid, &options) {
            XCTAssertEqual(Int(options >> UInt32(TGHIDPhaseShift)), Int(TGPhaseEnded))
        }
        var motion: Int64 = 0, flavor: Int64 = 0, progress = 0.0
        XCTAssertTrue(TGHIDEventGetInteger(hid, UInt32(TGHIDDockMotionField), &motion))
        XCTAssertTrue(TGHIDEventGetInteger(hid, UInt32(TGHIDDockFlavorField), &flavor))
        XCTAssertTrue(TGHIDEventGetDouble(hid, UInt32(TGHIDDockProgressField), &progress))
        XCTAssertEqual(motion, 2, "vertical")
        XCTAssertEqual(flavor, Int64(TGHIDDockPrimary))
        XCTAssertEqual(progress, 0.3, accuracy: 1e-4)   // HID may store progress as 16.16 fixed point
        let children = try XCTUnwrap(TGHIDEventGetChildren(hid), "the ended event carries a velocity child")
        XCTAssertEqual(children.count, 1)
        let velocity = children[0]
        var childType: UInt32 = 0
        XCTAssertTrue(TGHIDEventGetType(velocity, &childType))
        XCTAssertEqual(Int(childType), Int(TGHIDVelocity))
        var vx = 0.0, vy = 0.0, vz = 1.0
        XCTAssertTrue(TGHIDEventGetDouble(velocity, UInt32(TGHIDVelocityXField), &vx))
        XCTAssertTrue(TGHIDEventGetDouble(velocity, UInt32(TGHIDVelocityYField), &vy))
        XCTAssertTrue(TGHIDEventGetDouble(velocity, UInt32(TGHIDVelocityZField), &vz))
        XCTAssertEqual(vx, 4); XCTAssertEqual(vy, 4); XCTAssertEqual(vz, 0)
        // A changed step carries no velocity child.
        let changed = try XCTUnwrap(factory.make(kind: .vertical, delta: 0.1, phase: .changed, exitVelocity: 0,
                                                 inverted: false, source: nil, location: .zero))
        var changedHID: Any?
        _ = DockSwipeEventFactory.attached(from: changed.1, attach: { _, hid in changedHID = hid; return true })
        XCTAssertEqual(TGHIDEventGetChildren(try XCTUnwrap(changedHID))?.count ?? 0, 0)
    }

    func testAttachedEndIsRepostedLikeTheLegacyEnd() {
        // §6.9.4 end re-posts at +0.2 s and +0.5 s apply to the attached path too (one carrier per post).
        var time: UInt64 = 0
        var events: [CGEvent] = []
        var full = PrivateAPICapabilities()
        full.gestureEvents = true; full.dockSwipe = true
        guard TGPrivateAPIGetCapabilities().dockSwipe else {
            // Without the attachment symbol the injector falls back to shortcuts and posts nothing private.
            let injector = QuartzInjector(dockPath: .attachedHIDEvent, capabilities: full,
                                          postKeyEvent: { _ in }, postDockEvent: { events.append($0) }, now: { time })
            injector.inject(.dockSwipe(kind: .horizontal, progressDelta: 0.7, phase: .began, exitVelocity: 0))
            injector.inject(.dockSwipe(kind: .horizontal, progressDelta: 0, phase: .ended, exitVelocity: 1))
            XCTAssertTrue(events.isEmpty)
            return
        }
        let injector = QuartzInjector(dockPath: .attachedHIDEvent, capabilities: full,
                                      postDockEvent: { events.append($0) }, now: { time })
        injector.inject(.dockSwipe(kind: .horizontal, progressDelta: 0.7, phase: .began, exitVelocity: 0))
        injector.inject(.dockSwipe(kind: .horizontal, progressDelta: 0, phase: .ended, exitVelocity: 1))
        XCTAssertEqual(events.count, 2)
        time = 200_000_000; injector.tick(); XCTAssertEqual(events.count, 3)
        time = 500_000_000; injector.tick(); XCTAssertEqual(events.count, 4)
        XCTAssertTrue(events.allSatisfy { $0.type == TGEventTypeDockCompanion })
    }
}
