import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import OSLog
import TrackglassEngine

protocol InputInjector: AnyObject {
    var needsTick: Bool { get }
    func inject(_ event: GestureEvent)
    func tick()
    func displayDidSleep()
}

extension InputInjector { var needsTick: Bool { false }; func displayDidSleep() {} }

final class PointerState {
    private var remainderX = 0.0
    private var remainderY = 0.0
    fileprivate let eventSource: CGEventSource
    private let displayBounds = DisplayBounds()
    private var needsDisplayWake = true
    func displayDidSleep() { needsDisplayWake = true }
    private var lastActivityTime = DispatchTime.now().uptimeNanoseconds
    private let post: (CGEvent) -> Void
    init(post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.post = post
        eventSource = Self.sharedEventSource
    }
    /// §6.7: one `CGEventSource(.hidSystemState)` for the process, with local-event suppression disabled so
    /// posting never suppresses the user's physical devices. Sessions come and go; the source does not.
    /// Only ever touched from the `input-pipeline` queue (§2.4); CoreGraphics types carry no Sendable annotation.
    nonisolated(unsafe) static let sharedEventSource: CGEventSource = {
        let source = CGEventSource(stateID: .hidSystemState)!
        source.localEventsSuppressionInterval = 0
        // `.permitAllEvents` (public mask value 1 | 2 | 4): local mouse, keyboard and system-defined events pass.
        source.setLocalEventsFilterDuringSuppressionState(CGEventFilterMask(rawValue: 7), state: .eventSuppressionStateSuppressionInterval)
        return source
    }()
    /// §6.7 / §8.2: the first input after display sleep or ≥ 10 s of idleness declares user activity
    /// *before* the event is posted in the same tick, so the display wakes like it does for a real trackpad.
    func declareActivityIfNeeded() {
        let now = DispatchTime.now().uptimeNanoseconds
        if needsDisplayWake || now &- lastActivityTime >= 10_000_000_000 {
            var assertionID: IOPMAssertionID = 0
            _ = IOPMAssertionDeclareUserActivity("Trackglass pointer input" as CFString, kIOPMUserActiveLocal, &assertionID)
        }
        needsDisplayWake = false
        lastActivityTime = now
    }
    /// Posts `.mouseMoved`, or `.leftMouseDragged` / `.rightMouseDragged` while that button is held (§6.7),
    /// so AppKit drag tracking (selection, window moves, drag-and-drop) sees the motion.
    func move(dx: Double, dy: Double, heldButton: ButtonKind? = nil) {
        guard let current = CGEvent(source: nil)?.location else { return }
        declareActivityIfNeeded()
        remainderX += dx; remainderY += dy
        let ix = remainderX.rounded(), iy = remainderY.rounded()
        guard ix != 0 || iy != 0 else { return }
        remainderX -= ix; remainderY -= iy
        let position = displayBounds.clamp(CGPoint(x: current.x + ix, y: current.y + iy), from: current)
        let type: CGEventType
        let button: CGMouseButton
        switch heldButton {
        case .left?: type = .leftMouseDragged; button = .left
        case .right?: type = .rightMouseDragged; button = .right
        case nil: type = .mouseMoved; button = .left
        }
        guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type,
                                  mouseCursorPosition: position, mouseButton: button) else { return }
        // Delta fields carry the requested motion (§6.7) so delta-reading apps keep moving at screen edges.
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(ix))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(iy))
        post(event)
    }
    func tick() { _ = CGEvent(source: nil)?.location }
}

final class DisplayBounds: @unchecked Sendable {
    private let lock = NSLock()
    private var displays: [CGRect] = []
    private var registered = false

    init() {
        refresh()
        registered = CGDisplayRegisterReconfigurationCallback(Self.changed, Unmanaged.passUnretained(self).toOpaque()) == .success
    }

    deinit {
        if registered {
            CGDisplayRemoveReconfigurationCallback(Self.changed, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    private static let changed: CGDisplayReconfigurationCallBack = { _, _, context in
        guard let context else { return }
        Unmanaged<DisplayBounds>.fromOpaque(context).takeUnretainedValue().refresh()
    }

    private func refresh() {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return }
        var identifiers = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &identifiers, &count) == .success else { return }
        var refreshed: [CGRect] = []
        refreshed.reserveCapacity(Int(count))
        for identifier in identifiers.prefix(Int(count)) { refreshed.append(CGDisplayBounds(identifier)) }
        lock.lock(); displays = refreshed; lock.unlock()
    }

    func clamp(_ proposed: CGPoint, from current: CGPoint) -> CGPoint {
        lock.lock(); let screens = displays; lock.unlock()
        return Self.resolve(proposed, from: current, screens: screens)
    }

    /// §6.7 multi-display rule, pure so `TrackglassMacTests` can drive it with synthetic display rectangles:
    /// accept a point inside any display; otherwise slide along the edge (`(new.x, cur.y)`, then `(cur.x, new.y)`);
    /// otherwise clamp into the display that contains the current point. §8.4 "pointer never lands
    /// off-screen": if even the current point is in no display (the window between an unplug and the
    /// reconfiguration callback), clamp into the display nearest to the proposed point.
    static func resolve(_ proposed: CGPoint, from current: CGPoint, screens: [CGRect]) -> CGPoint {
        guard !screens.isEmpty else { return proposed }
        if screens.contains(where: { $0.contains(proposed) }) { return proposed }
        let horizontalSlide = CGPoint(x: proposed.x, y: current.y)
        if screens.contains(where: { $0.contains(horizontalSlide) }) { return horizontalSlide }
        let verticalSlide = CGPoint(x: current.x, y: proposed.y)
        if screens.contains(where: { $0.contains(verticalSlide) }) { return verticalSlide }
        let target = screens.first(where: { $0.contains(current) }) ?? nearest(to: proposed, in: screens)
        return clampInside(proposed, target)
    }

    private static func clampInside(_ point: CGPoint, _ rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX.nextDown),
                y: min(max(point.y, rect.minY), rect.maxY.nextDown))
    }

    private static func nearest(to point: CGPoint, in screens: [CGRect]) -> CGRect {
        var best = screens[0]
        var bestDistance = Double.infinity
        for rect in screens {
            let inside = clampInside(point, rect)
            let distance = hypot(Double(inside.x - point.x), Double(inside.y - point.y))
            if distance < bestDistance { bestDistance = distance; best = rect }
        }
        return best
    }
}

final class QuartzInjector: InputInjector {
    private let pointer: PointerState
    private let scrollFactory = ScrollEventFactory()
    static var runtimeCapabilities: PrivateAPICapabilities {
        if UserDefaults.standard.bool(forKey: "TGDisablePrivateGestures") { return PrivateAPICapabilities() }
        return TGPrivateAPIGetCapabilities()
    }
    /// Gates G-FORCE / G-NC (M7.6, M7.7): until a physical gate passes, `inject` takes the fallbacks regardless
    /// of the resolved capability flags; a `PrivateGestureTrials` flag switches one gesture to its private
    /// attempt for the gate run. The degraded list describes what `inject` does, not what the symbols allow.
    static func degradedGestures(capabilities: PrivateAPICapabilities = runtimeCapabilities, path: DockSwipePath = .current,
                                 trials: PrivateGestureTrials = .fromDefaults) -> [String] {
        var result = [String]()
        if !capabilities.gestureEvents || (path == .attachedHIDEvent && !capabilities.dockSwipe) {
            result.append("Spaces, Mission Control, App Exposé and Show Desktop use shortcuts")
            result.append("Launchpad / Apps gesture unavailable")
        }
        if trials.forceClick && capabilities.dockSwipe { result.append("Force click: private event trial (G-FORCE)") }
        else { result.append("Force click uses Look Up") }
        if path == .legacyFields && DockSwipePath.isLegacyTrial(trials) && capabilities.gestureEvents {
            result.append("Spaces, Mission Control, App Exposé, Launchpad, Show Desktop: legacy dock-swipe trial (macOS 27)")
        }
        if trials.notificationCenter && capabilities.gestureEvents { result.append("Notification Center: private gesture trial (G-NC)") }
        else { result.append("Notification Center uses Accessibility") }
        if !capabilities.gestureEvents { result.append("Scroll zoom gestures unavailable") }
        return result
    }
    private let capabilities: PrivateAPICapabilities
    private let trials: PrivateGestureTrials
    private let postKeyEvent: (CGEvent) -> Void
    private let dockFactory = DockSwipeEventFactory()
    private let dockPath: DockSwipePath
    private let postDockEvent: (CGEvent) -> Void
    private let now: () -> UInt64
    var needsTick: Bool { dockEnd != nil || forceLookupDeadline != nil || forceTrialStep != nil }
    private var forceLookupDeadline: UInt64?
    private var forceTrialStep: Int?
    private var forceTrialStart: UInt64 = 0
    private var dockEnd: (CGEvent?, CGEvent)?
    private var dockRepeatDeadline: UInt64 = 0
    private var dockFinalDeadline: UInt64 = 0
    private var naturalScroll = true
    private var heldButton: ButtonKind?
    private let postScrollEvent: (CGEvent) -> Void
    private let logger = Logger(subsystem: "app.trackglass.mac", category: "inject")
    /// §2.4: the injector is confined to the `input-pipeline` queue; `InputPipeline` sets this so every entry point
    /// checks it in debug builds. Unit tests that drive the injector directly leave it nil.
    var confinementQueue: DispatchQueue?
    private func assertConfined() {
        #if DEBUG
        if let confinementQueue { dispatchPrecondition(condition: .onQueue(confinementQueue)) }
        #endif
    }
    init(postScrollEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
         dockPath: DockSwipePath = .current,
         capabilities: PrivateAPICapabilities = QuartzInjector.runtimeCapabilities,
         trials: PrivateGestureTrials = .fromDefaults,
         postKeyEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
         postDockEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) },
         postPointerEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        pointer = PointerState(post: postPointerEvent)
        self.capabilities = capabilities; self.trials = trials; self.postKeyEvent = postKeyEvent
        self.dockPath = dockPath; self.postDockEvent = postDockEvent; self.now = now
        self.postScrollEvent = postScrollEvent
    }
    func inject(_ event: GestureEvent) {
        assertConfined()
        switch event {
        case .pointerMove, .haptic, .scrollMomentum, .gestureEnd: break
        default: pointer.declareActivityIfNeeded()   // §8.2: any first touch wakes the display, not only moves
        }
        switch event {
        case .magnify, .rotate, .smartZoom, .gestureBegin, .gestureEnd:
            guard capabilities.gestureEvents else { return }
            guard let location = CGEvent(source: nil)?.location,
                  let gesture = GestureEventFactory.make(event, source: pointer.eventSource, location: location) else { return }
            postScrollEvent(gesture)
        case let .scrollMomentum(phase, dx, dy):
            guard let location = CGEvent(source: nil)?.location,
                  let wheel = scrollFactory.makeMomentum(dx: dx, dy: dy, phase: phase, natural: naturalScroll,
                      source: pointer.eventSource, location: location) else { return }
            postScrollEvent(wheel)
        case let .scroll(dx, dy, phase, natural):
            naturalScroll = natural
            guard let location = CGEvent(source: nil)?.location,
                  let pair = scrollFactory.make(dx: dx, dy: dy, phase: phase, natural: natural,
                      source: pointer.eventSource, location: location) else { return }
            postScrollEvent(pair.wheel)
            if capabilities.gestureEvents { postScrollEvent(pair.companion) }
        case let .pointerMove(dx, dy): pointer.move(dx: dx, dy: dy, heldButton: heldButton)
        case let .button(kind, phase, clickCount):
            if phase == .down { heldButton = kind } else if heldButton == kind { heldButton = nil }
            guard let location = CGEvent(source: nil)?.location else { return }
            let button: CGMouseButton = kind == .left ? .left : .right
            let type: CGEventType
            switch (kind, phase) {
            case (.left, .down): type = .leftMouseDown
            case (.left, .up): type = .leftMouseUp
            case (.right, .down): type = .rightMouseDown
            case (.right, .up): type = .rightMouseUp
            }
            guard let event = CGEvent(mouseEventSource: pointer.eventSource, mouseType: type,
                                      mouseCursorPosition: location, mouseButton: button) else { return }
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            postScrollEvent(event)
        case .forceClick(stage: 2):
            if trials.forceClick, capabilities.dockSwipe, forceTrialStep == nil, postForceTrialStep(0) {
                forceTrialStep = 1; forceTrialStart = now()
                logger.notice("force click: private force event trial (G-FORCE)")
                return
            }
            if trials.forceClick { logger.notice("force click trial: HID attachment unavailable, keyboard fallback") }
            inject(.button(kind: .left, phase: .down, clickCount: 1))
            inject(.button(kind: .left, phase: .up, clickCount: 1))
            forceLookupDeadline = now() + 30_000_000
            logger.notice("force click: keyboard fallback")
        case .lookUpAtPointer:
            guard let down = CGEvent(keyboardEventSource: pointer.eventSource, virtualKey: 0x02, keyDown: true),
                  let up = CGEvent(keyboardEventSource: pointer.eventSource, virtualKey: 0x02, keyDown: false) else { return }
            let modifiers: CGEventFlags = [.maskControl, .maskCommand]
            down.flags = modifiers; up.flags = modifiers
            postKeyEvent(down); postKeyEvent(up)
        case .haptic(let kind): logger.debug("gesture haptic suggestion: \(String(describing: kind), privacy: .public)")
        case let .dockSwipe(kind, delta, phase, velocity):
            if phase == .began { dockEnd = nil }
            guard let location = CGEvent(source: nil)?.location,
                  let pair = dockFactory.make(kind: kind, delta: delta, phase: phase, exitVelocity: velocity,
                      inverted: naturalScroll, source: pointer.eventSource, location: location) else { return }
            if !capabilities.gestureEvents || (dockPath == .attachedHIDEvent && !capabilities.dockSwipe) {
                if phase == .ended { fallbackDock(kind: kind, progress: dockFactory.progress) }
                return
            }
            let output: (CGEvent?, CGEvent)
            if dockPath == .attachedHIDEvent {
                guard let attached = DockSwipeEventFactory.attached(from: pair.1, source: pointer.eventSource) else {
                    if phase == .ended { fallbackDock(kind: kind, progress: dockFactory.progress) }
                    return
                }
                output = (nil, attached)
            } else { output = pair }
            if let marker = output.0 { postDockEvent(marker) }
            postDockEvent(output.1)
            if phase == .ended || phase == .cancelled {
                dockEnd = output
                let time = now()
                dockRepeatDeadline = time + 200_000_000; dockFinalDeadline = time + 500_000_000
            }
        case let .navigationSwipe(direction):
            guard capabilities.gestureEvents else { return }
            guard let location = CGEvent(source: nil)?.location,
                  let pair = GestureEventFactory.navigation(direction, source: pointer.eventSource, location: location) else { return }
            postScrollEvent(pair.0); postScrollEvent(pair.1)
        case .notificationCenter:
            if trials.notificationCenter, capabilities.gestureEvents, let location = CGEvent(source: nil)?.location {
                let attached = dockPath == .attachedHIDEvent && capabilities.dockSwipe
                let sequence = attached
                    ? FluidGestureEventFactory.attachedNotificationCenterSequence(source: pointer.eventSource, location: location)
                    : FluidGestureEventFactory.notificationCenterSequence(source: pointer.eventSource, location: location)
                if let sequence {
                    for event in sequence { postScrollEvent(event) }
                    logger.notice("Notification Center: private fluid gesture trial (G-NC), attached=\(attached)")
                    return
                }
                logger.notice("Notification Center trial: private gesture unavailable, Accessibility fallback")
            }
            Task { @MainActor [logger] in
                if !NotificationCenterAction.perform() { logger.notice("Notification Center Clock action unavailable") }
            }
        default: break
        }
    }
    func displayDidSleep() { pointer.displayDidSleep() }

    /// G-FORCE trial: posts one step of the force sequence; false when the attached event cannot be built.
    private func postForceTrialStep(_ index: Int) -> Bool {
        guard let location = CGEvent(source: nil)?.location,
              let event = ForceEventFactory.attachedEvent(ForceEventFactory.steps[index], source: pointer.eventSource,
                                                          location: location) else { return false }
        postScrollEvent(event)
        return true
    }

    /// Discrete fallback (§6.9.4). It fires only when the swipe got at least half way (|progress| ≥ 0.5, owner
    /// decision 2026-10-28) — the threshold of the phone's `spaceSwitched` haptic, and a short swipe snaps back
    /// as §10.3 C7 requires instead of switching a whole Space.
    static let fallbackProgressThreshold = 0.5
    private func fallbackDock(kind: DockSwipeKind, progress: Double) {
        guard abs(progress) >= Self.fallbackProgressThreshold else { return }
        let key: CGKeyCode
        let flags: CGEventFlags
        switch kind {
        case .horizontal: key = progress > 0 ? 124 : 123; flags = .maskControl
        case .vertical: key = progress > 0 ? 126 : 125; flags = .maskControl
        case .pinch:
            guard progress > 0 else { logger.notice("Launchpad / Apps has no reliable shortcut fallback"); return }
            key = 103; flags = []
        }
        guard let down = CGEvent(keyboardEventSource: pointer.eventSource, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: pointer.eventSource, virtualKey: key, keyDown: false) else { return }
        down.flags = flags; up.flags = flags
        postKeyEvent(down); postKeyEvent(up)
        logger.notice("Dock gesture: keyboard fallback")
    }
    func tick() {
        assertConfined()
        pointer.tick()
        let time = now()
        if let deadline = forceLookupDeadline, time >= deadline {
            forceLookupDeadline = nil; inject(.lookUpAtPointer)
        }
        if let step = forceTrialStep {
            if step >= ForceEventFactory.steps.count { forceTrialStep = nil }
            else if time >= forceTrialStart &+ ForceEventFactory.steps[step].delayNs {
                if !postForceTrialStep(step) { logger.notice("force click trial: step \(step) could not be built") }
                forceTrialStep = step + 1
                if forceTrialStep == ForceEventFactory.steps.count { forceTrialStep = nil }
            }
        }
        guard let pair = dockEnd else { return }
        if dockRepeatDeadline != 0 && time >= dockRepeatDeadline {
            if let marker = pair.0 { postDockEvent(marker) }; postDockEvent(pair.1); dockRepeatDeadline = 0
        }
        if time >= dockFinalDeadline {
            if let marker = pair.0 { postDockEvent(marker) }; postDockEvent(pair.1); dockEnd = nil
        }
    }
}
