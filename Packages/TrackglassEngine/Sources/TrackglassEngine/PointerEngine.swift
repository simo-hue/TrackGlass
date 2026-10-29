import Foundation
import TrackglassKit

public struct EngineGeometry: Sendable, Equatable, Codable {
    public var widthMM: Double
    public var heightMM: Double
    public var isLandscape: Bool
    public init(widthMM: Double, heightMM: Double, isLandscape: Bool) {
        self.widthMM = widthMM; self.heightMM = heightMM; self.isLandscape = isLandscape
    }
}

public struct EventBuffer: Sendable {
    private var values = [GestureEvent?](repeating: nil, count: 48)
    public private(set) var count = 0
    public init() {}
    public subscript(_ index: Int) -> GestureEvent { values[index]! }
    public var events: [GestureEvent] { (0..<count).map { values[$0]! } }
    public mutating func clear() { for i in 0..<count { values[i] = nil }; count = 0 }
    mutating func append(_ event: GestureEvent) {
        guard count < values.count else { assertionFailure("Gesture event buffer overflow"); return }
        values[count] = event; count += 1
    }
    /// Inserts before the event at `index` (fixed storage, no allocation).
    mutating func insert(_ event: GestureEvent, at index: Int) {
        guard count < values.count, index <= count else { assertionFailure("Gesture event buffer overflow"); return }
        var position = count
        while position > index { values[position] = values[position - 1]; position -= 1 }
        values[index] = event; count += 1
    }
}

public protocol AccelerationModel: Sendable {
    func accelerate(dxMM: Double, dyMM: Double, dtNanoseconds: UInt64) -> (Double, Double)
}
public struct UnitGainAcceleration: AccelerationModel {
    public init() {}
    public func accelerate(dxMM: Double, dyMM: Double, dtNanoseconds: UInt64) -> (Double, Double) { (dxMM, dyMM) }
}
public struct ConstantGainAcceleration: AccelerationModel {
    public let pointsPerMM: Double
    public init(pointsPerMM: Double = 4) { self.pointsPerMM = pointsPerMM }
    public func accelerate(dxMM: Double, dyMM: Double, dtNanoseconds: UInt64) -> (Double, Double) { (dxMM * pointsPerMM, dyMM * pointsPerMM) }
}

/// `releasing`: three or more fingers were down and some have lifted; nothing new starts (no scroll arming,
/// no pointer motion) until the last finger is up (owner decision 2026-10-28, staggered lift-off).
private enum EngineMode: Equatable { case idle, pointer, pendingScroll, multiFinger, releasing }
private struct ContactSlot {
    var id: UInt8 = 0
    var active = false
    var seen = false
    var palm = false
    var resting = false
    var restingEligible = true
    var ignoredForMode = false
    var moved = false
    var x = 0.0
    var y = 0.0
    var startX = 0.0
    var startY = 0.0
    var time: UInt64 = 0
    var beganAt: UInt64 = 0
    var pathLength = 0.0
    /// For a late finger: the centroid of the effective fingers when it landed, to tell whether it then moves
    /// together with them (a second finger joining to scroll) or alone (§6.5.3, 2026-10-29).
    var partnerX = 0.0
    var partnerY = 0.0
    /// For a late finger: where it was when `partnerX/Y` were taken. Both references are taken again whenever
    /// one of the two fingers moves without the other, so only motion made together counts.
    var lateAnchorX = 0.0
    var lateAnchorY = 0.0
    var anchored = false
    /// This frame's motion (0 when the contact did not move or was not in the frame).
    var frameDX = 0.0
    var frameDY = 0.0
}

private struct TapContact {
    let id: UInt8
    let beganAt: UInt64
    let startX: Double
    let startY: Double
    var pathLength: Double
    var endedAt: UInt64?
    var dragSequence = false
    var releasesDragLock = false
}

private struct ContactTracker {
    var slots = [ContactSlot](repeating: ContactSlot(), count: TouchFrame.maximumContacts)
    var effectiveCount = 0
    var trackedCount: Int { slots.reduce(into: 0) { if $1.active { $0 += 1 } } }
    mutating func beginFrame() { for i in slots.indices { slots[i].seen = false; slots[i].frameDX = 0; slots[i].frameDY = 0 } }
    func index(for id: UInt8) -> Int? { slots.firstIndex(where: { $0.id == id && $0.active }) }
    func freeIndex() -> Int? { slots.firstIndex(where: { !$0.active }) }
    mutating func finishFrame() {
        for i in slots.indices where slots[i].active && !slots[i].seen { slots[i].active = false }
        recount()
    }
    mutating func recount() {
        effectiveCount = slots.reduce(into: 0) { if $1.active && !$1.palm && !$1.resting { $0 += 1 } }
    }
    mutating func clear() { for i in slots.indices { slots[i].active = false; slots[i].seen = false }; effectiveCount = 0 }
}

public final class GestureEngine: @unchecked Sendable {
    private let acceleration: any AccelerationModel
    private let scrollAcceleration: any AccelerationModel
    private var twoFinger = TwoFingerRecognizer()
    private var multiFinger = MultiFingerRecognizer()
    private var momentum = ScrollMomentum()
    private var stopMomentumRequested = false
    private var tapConsumedByGesture = false
    private var forceHoldCancelled = false
    private var geometry: EngineGeometry
    private var settings: TrackpadSettings
    private var pendingSettings: TrackpadSettings?
    private var pendingTwoFingerTap: (deadline: UInt64, secondaryEnabled: Bool)?
    private var tracker = ContactTracker()
    private var mode = EngineMode.idle
    private var settleDeadline: UInt64 = 0
    private var accumulatedX = 0.0
    private var accumulatedY = 0.0
    private var tapContacts = [TapContact]()
    private var previousClickTime: UInt64?
    private var previousClickX = 0.0
    private var previousClickY = 0.0
    private var previousClickCount = 0
    private var dragButtonHeld = false
    private var dragLockEngaged = false
    private var dragContactID: UInt8?
    private var dragClickCount = 2
    private var dragReleaseDeadline: UInt64?
    /// Frame time of a drag contact lifted quickly in this frame (§6.5.6 "if that contact ends within
    /// TAP_MAX_DURATION having moved less than TAP_MAX_MOVEMENT"): `emitTapIfComplete` normally turns it into the
    /// release; if it does not, the grace window opens after tap evaluation so the button is never left held.
    private var quickDragLiftAt: UInt64?
    private var threeFingerDragStart: (Double, Double)?
    private var threeFingerDragPrevious: (Double, Double)?
    private var threeFingerDragPreviousTime: UInt64 = 0
    private var threeFingerDragActive = false
    /// Frame time at which the current two-finger set formed (`.pendingScroll`); a lift within TAP_MAX_DURATION of
    /// it may still be a two-finger tap, so the remaining finger does not point (§6.5.8 staggered lift-off).
    private var pendingScrollSince: UInt64 = 0
    /// Touch-down hysteresis (§6.5.5 "taps never move the pointer"): the motion of a contact that has not yet
    /// travelled TAP_HYSTERESIS from where it landed is held back, released once it has, and dropped if it taps.
    private var heldMotion: (id: UInt8, dx: Double, dy: Double, dt: UInt64)?
    static let tapHysteresisMM = 0.5
    /// Tap-and-a-half (§6.5.6, 2026-10-29): the repeat tap's press waits for the settle window to show one finger
    /// (or for the finger to move beyond TAP_HYSTERESIS, or to lift as a double-click). A second finger joining
    /// inside the window makes the repeat tap part of a scroll, a two-finger tap or a swipe, and nothing is pressed.
    private var pendingDragPress: (id: UInt8, count: Int, pressAt: UInt64)?
    /// A finger re-landing inside the drag grace window continues the held button; if a second finger joins it
    /// inside the settle window (a scroll or a two-finger tap), the drag ends there instead.
    private var pendingRegrab: (id: UInt8, until: UInt64)?
    /// Time of the last processed frame: a lift-off forced by a heartbeat ends contacts there (§6.5.10).
    private var lastFrameTime: UInt64 = 0
    public private(set) var needsTick = false
    /// The settings the engine currently applies (a change made during a gesture waits until it is idle, §6.4)
    /// and a counter that changes with them, so the injector follows the same snapshot (natural scrolling).
    public var appliedSettings: TrackpadSettings { settings }
    public private(set) var settingsGeneration = 0
    public var hasActiveContacts: Bool { tracker.trackedCount > 0 }
    /// True while the left button is held by an engaged drag lock (§6.5.6): a deliberate user state that only
    /// a tap, a BYE or connection loss ends. Diagnostics and `tgreplay invariants` use it to tell a legitimate
    /// held button from a stuck one.
    public var isDragLockEngaged: Bool { dragButtonHeld && dragLockEngaged }
    /// STATUS `engineState` (§4.5): 0 idle, 1 pointer, 2 scroll, 3 gesture, 4 drag.
    public var diagnosticState: UInt8 {
        if dragButtonHeld { return 4 }
        switch mode {
        case .idle: return momentum.active ? 2 : 0
        case .pointer: return 1
        case .pendingScroll: return twoFinger.scrollActive ? 2 : (twoFinger.hasActiveGesture ? 3 : 1)
        case .multiFinger, .releasing: return 3
        }
    }

    public init(settings: TrackpadSettings = TrackpadSettings(), geometry: EngineGeometry,
                acceleration: (any AccelerationModel)? = nil,
                scrollAcceleration: any AccelerationModel = ConstantGainAcceleration()) {
        self.settings = settings; self.geometry = geometry
        self.acceleration = acceleration ?? PointerAccelerator.fallback(trackingSpeed: settings.trackingSpeed)
        self.scrollAcceleration = scrollAcceleration
        tapContacts.reserveCapacity(TouchFrame.maximumContacts)
    }

    public func process(_ frame: TouchFrame, into events: inout EventBuffer) {
        guard frame.isSyntheticLiftoff else { processContacts(frame, into: &events); return }
        // §4.7 / §6.5.10: contacts the lift-off still finds tracked lost their `ended` frame. They end at the
        // lift-off's time through the ordinary vanished-contact path, so a tap still clicks, an activated
        // gesture ends with `.ended` and a drag contact opens its grace window (or engages the lock).
        if hasActiveContacts { processContacts(frame, into: &events) }
        // A held button with no contact, no grace window and no deliberate lock is a stuck state
        // (every path that ends a drag contact opens one of those); the phone's lift-off clears it.
        if dragButtonHeld && !dragLockEngaged && dragReleaseDeadline == nil {
            events.append(.button(kind: .left, phase: .up, clickCount: dragClickCount))
            dragButtonHeld = false; dragContactID = nil
            threeFingerDragActive = false; threeFingerDragStart = nil; threeFingerDragPrevious = nil
            if tracker.trackedCount == 0, !momentum.active { applyPendingSettings() }
            updateNeedsTick()
        }
    }

    private func updateNeedsTick() {
        needsTick = tracker.trackedCount > 0 || dragReleaseDeadline != nil || momentum.active || pendingTwoFingerTap != nil
    }

    private func processContacts(_ frame: TouchFrame, into events: inout EventBuffer) {
        if momentum.active {
            for index in 0..<frame.contactCount where frame[index].phase == .began && frame[index].kind == .finger {
                momentum.cancel(into: &events)
                appendScroll(.mayBegin, into: &events); appendScroll(.cancelled, into: &events)
                break
            }
        }
        expireTwoFingerTap(now: frame.frameTime, into: &events)
        expireDragGrace(now: frame.frameTime, into: &events)
        lastFrameTime = max(lastFrameTime, frame.frameTime)
        let oldCentroid = activeCentroid()
        tracker.beginFrame()
        let oldEffectiveCount = tracker.effectiveCount
        var contactCancelled = false
        var contactLifted = false
        var moveDX = 0.0; var moveDY = 0.0; var moveDT: UInt64 = 0; var hasPointerDelta = false
        var dragDX = 0.0; var dragDY = 0.0; var dragDT: UInt64 = 0; var hasDragDelta = false
        var movingPath = 0.0   // path of the contact driving the pointer this frame (pending secondary click flush)
        var movingID: UInt8 = 0

        for i in 0..<frame.contactCount {
            let contact = frame[i]
            guard contact.kind == .finger else { continue }
            let x = Double(contact.x), y = Double(contact.y)
            var slotIndex = tracker.index(for: contact.contactID)
            if slotIndex == nil {
                // A terminal phase for an ID that is not tracked has nothing to end: UIKit repeats an `ended`
                // the phone already sent when one finger lifts while another moves in the same event.
                if contact.phase == .ended || contact.phase == .cancelled { continue }
                slotIndex = tracker.freeIndex()
            }
            guard let index = slotIndex else { continue }
            if contact.phase == .ended || contact.phase == .cancelled {
                if pendingDragPress?.id == contact.contactID {
                    // Lifted before the press went out: a quick repeat tap is a double-click (down then up below);
                    // a cancelled contact never clicks (§5.2).
                    if contact.phase == .ended { pressPendingDrag(into: &events) } else { pendingDragPress = nil }
                }
                if pendingRegrab?.id == contact.contactID { pendingRegrab = nil }
                contactCancelled = contactCancelled || contact.phase == .cancelled
                contactLifted = contactLifted || tracker.slots[index].active
                // UIKit's terminal sample routinely moves a little past the last `moved` one: fold it into the
                // path (so a tap that only moved on lift is not a tap) and into a held drag's delta.
                let previous = tracker.slots[index]
                if previous.active, frame.frameTime > previous.time, !previous.palm, !previous.resting,
                   x != previous.x || y != previous.y {
                    tracker.slots[index].pathLength += hypot(x - previous.x, y - previous.y)
                    if dragButtonHeld && dragContactID == contact.contactID {
                        dragDX += x - previous.x; dragDY += y - previous.y
                        dragDT = frame.frameTime - previous.time; hasDragDelta = true
                        movingPath = tracker.slots[index].pathLength; movingID = contact.contactID
                    }
                    // Plain pointer motion on the lift frame is not emitted: the mode leaves `.pointer` in the
                    // same frame and a sub-frame jump at lift-off is not what a trackpad does either.
                }
                let pathLength = tracker.slots[index].pathLength
                if contact.phase == .ended, let tapIndex = tapContacts.firstIndex(where: { $0.id == contact.contactID }) {
                    tapContacts[tapIndex].endedAt = frame.frameTime
                    tapContacts[tapIndex].pathLength = pathLength
                    let quickTap = pathLength < 2.0 && frame.frameTime >= tapContacts[tapIndex].beganAt &&
                        frame.frameTime - tapContacts[tapIndex].beganAt <= 300_000_000
                    endDragContact(id: contact.contactID, quickTap: quickTap, now: frame.frameTime, into: &events)
                } else {
                    // A cancelled contact never clicks (§5.2); if it was dragging, release safely.
                    if contact.phase == .cancelled { tapContacts.removeAll { $0.id == contact.contactID } }
                    endDragContact(id: contact.contactID, quickTap: false, now: frame.frameTime, into: &events)
                }
                tracker.slots[index].active = false; tracker.slots[index].seen = true
                if heldMotion?.id == contact.contactID, !hasDragDelta || movingID != contact.contactID { heldMotion = nil }
                continue
            }
            if contact.phase == .began || !tracker.slots[index].active {
                if heldMotion?.id == contact.contactID { heldMotion = nil }
                if tracker.slots[index].active {
                    // §4.7: a `began` for a still-tracked ID first ends the old contact — as a lift whose `ended`
                    // was lost — so the count drops and the new contact follows the rules for a finger landing now.
                    endReusedContact(at: index, now: frame.frameTime, into: &events)
                    contactLifted = true
                }
                let lateExtra = mode != .idle && frame.frameTime > settleDeadline && tracker.effectiveCount > 0
                tracker.slots[index] = ContactSlot(id: contact.contactID, active: true, seen: true,
                    palm: Double(contact.majorRadius) > 11, x: x, y: y, startX: x, startY: y,
                    time: frame.frameTime, beganAt: frame.frameTime)
                if lateExtra {
                    tracker.slots[index].resting = true; tracker.slots[index].ignoredForMode = true
                    if let partner = activeCentroid() { tracker.slots[index].partnerX = partner.0; tracker.slots[index].partnerY = partner.1 }
                }
                tapContacts.removeAll { $0.id == contact.contactID }
                // A palm is never part of a tap (§6.5.2); it must not hold the tap open until it lifts.
                guard !tracker.slots[index].palm else { continue }
                tapContacts.append(TapContact(id: contact.contactID, beganAt: frame.frameTime,
                    startX: x, startY: y, pathLength: 0, endedAt: nil))
                let tapIndex = tapContacts.count - 1
                if dragLockEngaged {
                    tapContacts[tapIndex].releasesDragLock = true
                } else if dragButtonHeld, let deadline = dragReleaseDeadline, frame.frameTime <= deadline {
                    dragReleaseDeadline = nil
                    dragContactID = contact.contactID
                    tapContacts[tapIndex].dragSequence = true
                    pendingRegrab = (contact.contactID, frame.frameTime &+ 60_000_000)
                } else if !dragButtonHeld, !lateExtra, settings.dragging || !settings.clicking, let previousClickTime,
                          frame.frameTime >= previousClickTime,
                          frame.frameTime - previousClickTime < settings.doubleClickIntervalNs,
                          hypot(x - previousClickX, y - previousClickY) <= 5 {
                    dragContactID = contact.contactID
                    dragClickCount = min(previousClickCount + 1, 3); self.previousClickTime = nil
                    tapContacts[tapIndex].dragSequence = true
                    pendingDragPress = (contact.contactID, dragClickCount, frame.frameTime &+ 60_000_000)
                }
                continue
            }
            let previous = tracker.slots[index]
            tracker.slots[index].seen = true
            if frame.frameTime > previous.time {
                let originDistance = hypot(x - previous.startX, y - previous.startY)
                tracker.slots[index].pathLength += hypot(x - previous.x, y - previous.y)
                tracker.slots[index].frameDX = x - previous.x; tracker.slots[index].frameDY = y - previous.y
                if previous.resting && !previous.ignoredForMode && originDistance > 3 {
                    tracker.slots[index].resting = false
                    tracker.slots[index].restingEligible = false
                    tracker.slots[index].moved = true
                }
                // A late finger (§6.5.3) does not drive the mode, but its motion is "another contact moves" for
                // the resting-thumb rule (§6.5.2): a thumb that landed first and stays put is classified resting,
                // and the moving finger then takes over (below, in `classifyRestingContacts`).
                if previous.ignoredForMode && !previous.palm && hypot(x - previous.x, y - previous.y) > 0.05 {
                    tracker.slots[index].moved = true
                }
                if !previous.palm && !previous.resting && (x != previous.x || y != previous.y) {
                    // Movement below 0.05 mm is accumulated by the emitters below, never dropped (§6.5.4).
                    if hypot(x - previous.x, y - previous.y) > 0.05 { tracker.slots[index].moved = true }
                    if dragButtonHeld && dragContactID == contact.contactID {
                        dragDX = x - previous.x; dragDY = y - previous.y
                        dragDT = frame.frameTime - previous.time; hasDragDelta = true
                        movingPath = tracker.slots[index].pathLength; movingID = contact.contactID
                    } else if oldEffectiveCount == 1 && mode == .pointer {
                        moveDX = x - previous.x; moveDY = y - previous.y
                        moveDT = frame.frameTime - previous.time; hasPointerDelta = true
                        movingPath = tracker.slots[index].pathLength; movingID = contact.contactID
                    }
                }
                if hypot(x - previous.startX, y - previous.startY) > 1.5 { tracker.slots[index].restingEligible = false }
                tracker.slots[index].x = x; tracker.slots[index].y = y; tracker.slots[index].time = frame.frameTime
            }
        }
        for slot in tracker.slots where slot.active && !slot.seen {
            // §4.7: a tracked contact absent from a newer frame is ended at that frame's time.
            contactLifted = true
            if pendingDragPress?.id == slot.id { pressPendingDrag(into: &events) }
            if pendingRegrab?.id == slot.id { pendingRegrab = nil }
            var quickTap = false
            if let tapIndex = tapContacts.firstIndex(where: { $0.id == slot.id }) {
                tapContacts[tapIndex].endedAt = frame.frameTime
                tapContacts[tapIndex].pathLength = slot.pathLength
                quickTap = slot.pathLength < 2.0 && frame.frameTime >= tapContacts[tapIndex].beganAt &&
                    frame.frameTime - tapContacts[tapIndex].beganAt <= 300_000_000
            }
            endDragContact(id: slot.id, quickTap: quickTap, now: frame.frameTime, into: &events)
        }
        tracker.finishFrame()
        promoteLateFingerMovingWithThePrimary()
        classifyRestingContacts(now: frame.frameTime)
        // A thumb that has settled into resting is excluded from finger counting (§6.5.2), including taps:
        // the index finger's tap must click while the thumb stays down.
        for slot in tracker.slots where slot.active && slot.resting && !slot.ignoredForMode {
            tapContacts.removeAll { $0.id == slot.id }
        }
        transitionMode(previousCount: oldEffectiveCount, now: frame.frameTime, cancelled: contactCancelled,
                       lifted: contactLifted, into: &events)
        resolvePendingDragPress(now: frame.frameTime, into: &events)
        if mode == .pendingScroll, tracker.effectiveCount == 2, let pair = twoFingerGeometry() {
            let start = events.count
            let wasActive = twoFinger.hasActiveGesture
            twoFinger.update(x: pair.x, y: pair.y, distance: pair.distance, angle: pair.angle, time: frame.frameTime, settings: settings,
                             acceleration: scrollAcceleration, suppressActivation: hasRestingThumbCandidate, into: &events)
            for index in start..<events.count {
                if case let .scroll(dx, dy, _, _) = events[index] {
                    momentum.record(dx: dx, dy: dy, dt: twoFinger.lastDeltaTime, at: frame.frameTime)
                }
            }
            // A scroll, pinch, rotation or edge swipe is not a second two-finger tap: the pending secondary click
            // goes out first, where the first tap was, instead of in the middle of the gesture (§6.5.7).
            if !wasActive && twoFinger.hasActiveGesture { flushPendingSecondaryClick(into: &events, at: start) }
            tapConsumedByGesture = tapConsumedByGesture || twoFinger.hasActiveGesture
        }
        if mode == .multiFinger, let sample = multiFingerSample() {
            let start = events.count
            let wasActive = multiFinger.active
            multiFinger.update(sample, time: frame.frameTime, settings: settings, into: &events)
            if !wasActive && multiFinger.active { flushPendingSecondaryClick(into: &events, at: start) }
            tapConsumedByGesture = tapConsumedByGesture || multiFinger.active
        }
        updateForceClick(now: frame.frameTime, into: &events)
        updateThreeFingerDrag(now: frame.frameTime, oldCentroid: oldCentroid, into: &events)
        emitTapIfComplete(now: frame.frameTime, into: &events)
        if let liftedAt = quickDragLiftAt {
            quickDragLiftAt = nil
            // The quick lift was not turned into the click release (the tap set had other fingers, was consumed
            // or purged): the button must not stay held with no deadline, so the grace window opens (§6.5.6, §8.8).
            if dragButtonHeld, !dragLockEngaged, dragContactID == nil, dragReleaseDeadline == nil, !threeFingerDragActive {
                dragReleaseDeadline = liftedAt &+ 300_000_000
            }
        }
        // Touch-down hysteresis: a contact still within TAP_HYSTERESIS of where it landed does not move the pointer
        // (it may be a tap); its motion is held and released, unchanged, once the contact has travelled further.
        if hasPointerDelta || hasDragDelta {
            if movingPath <= Self.tapHysteresisMM {
                var held: (id: UInt8, dx: Double, dy: Double, dt: UInt64) = (movingID, 0, 0, 0)
                if let current = heldMotion, current.id == movingID { held = current }
                held.dx += hasDragDelta ? dragDX : moveDX; held.dy += hasDragDelta ? dragDY : moveDY
                held.dt &+= hasDragDelta ? dragDT : moveDT
                heldMotion = held
                hasPointerDelta = false; hasDragDelta = false
            } else if let held = heldMotion, held.id == movingID {
                heldMotion = nil
                if hasDragDelta { dragDX += held.dx; dragDY += held.dy; dragDT &+= held.dt }
                else { moveDX += held.dx; moveDY += held.dy; moveDT &+= held.dt }
            }
        }
        // Held motion belongs to one pointing contact: it is dropped when that contact lifted (a tap) or the
        // pointer is no longer what it drives (a second finger made it a scroll).
        if let held = heldMotion, (mode != .pointer && !dragButtonHeld) || tracker.index(for: held.id) == nil {
            heldMotion = nil
        }
        // Motion beyond TAP_MAX_MOVEMENT cannot be part of a second two-finger tap: a pending secondary click is
        // emitted before the pointer leaves the place the first tap was made (§6.5.7).
        if (hasDragDelta || hasPointerDelta), movingPath >= 2.0 { flushPendingSecondaryClick(into: &events) }
        // A drag contact drives the pointer only while it is the one pointing finger: a second finger joining makes
        // a scroll or a gesture, and its motion must not drag at the same time.
        if hasDragDelta, dragButtonHeld, !threeFingerDragActive, mode == .pointer {
            let delta = acceleration.accelerate(dxMM: dragDX, dyMM: dragDY, dtNanoseconds: dragDT)
            emitAccumulatedPointerMove(dx: delta.0, dy: delta.1, into: &events)
        }
        if mode == .pointer, tracker.effectiveCount == 1, hasPointerDelta {
            let delta = acceleration.accelerate(dxMM: moveDX, dyMM: moveDY, dtNanoseconds: moveDT)
            emitAccumulatedPointerMove(dx: delta.0, dy: delta.1, into: &events)
        }
        // Per-sequence flags end with the last *effective* finger: a resting thumb or a palm that stays down
        // must not swallow every later tap or block force click (§6.5.2: they are excluded from counting).
        if tracker.effectiveCount == 0 { tapConsumedByGesture = false; forceHoldCancelled = false }
        if tracker.trackedCount == 0, !momentum.active { applyPendingSettings() }
        updateNeedsTick()
    }

    public func tick(now: UInt64, into events: inout EventBuffer) {
        expireTwoFingerTap(now: now, into: &events)
        expireDragGrace(now: now, into: &events)
        let previousCount = tracker.effectiveCount
        classifyRestingContacts(now: now)
        transitionMode(previousCount: previousCount, now: now, into: &events)
        resolvePendingDragPress(now: now, into: &events)
        if stopMomentumRequested { momentum.cancel(into: &events); stopMomentumRequested = false }
        momentum.tick(now: now, into: &events)
        updateForceClick(now: now, into: &events)
        if tracker.trackedCount == 0, !momentum.active, dragReleaseDeadline == nil { applyPendingSettings() }
        updateNeedsTick()
    }

    private func updateForceClick(now: UInt64, into events: inout EventBuffer) {
        // §6.5.9 "no other contact": a palm or a resting thumb is not a finger (§6.5.2), but a late finger landing
        // outside the resting zone is (it only does not change the mode, §6.5.3).
        if tracker.effectiveCount > 1 { forceHoldCancelled = true }
        for slot in tracker.slots where slot.active && slot.ignoredForMode && !slot.palm && slot.startY < geometry.heightMM - 18 {
            forceHoldCancelled = true
        }
        guard settings.forceClickEnabled, !forceHoldCancelled, !tapConsumedByGesture,
              !dragButtonHeld, !dragLockEngaged, tracker.effectiveCount == 1,
              let slot = tracker.slots.first(where: { $0.active && !$0.palm && !$0.resting }) else { return }
        if slot.pathLength >= 1 { forceHoldCancelled = true; return }
        // A contact that began in the bottom 18 mm is how a hand holds the phone (§6.5.2 resting zone): a thumb
        // resting there alone must not force-click — and through the fallback click — what is under the pointer.
        guard slot.startY < geometry.heightMM - 18 else { forceHoldCancelled = true; return }
        guard now >= slot.beganAt, now - slot.beganAt >= 600_000_000 else { return }
        tapConsumedByGesture = true
        flushPendingSecondaryClick(into: &events)
        events.append(.forceClick(stage: 2)); events.append(.haptic(.forceClickStage2))
    }

    public func setSettings(_ settings: TrackpadSettings) {
        if momentum.active && !settings.momentumScrollEnabled { stopMomentumRequested = true }
        if tracker.trackedCount == 0, !momentum.active, dragReleaseDeadline == nil, pendingTwoFingerTap == nil { applySettings(settings) }
        else { pendingSettings = settings }
    }

    public func setGeometry(_ geometry: EngineGeometry, into events: inout EventBuffer) {
        // §8.7: a surface change cancels whatever was in progress (the Dock snaps back).
        reset(into: &events, releaseDragLock: false, cancelGestures: true); self.geometry = geometry
    }

    /// §6.5.10: a lift-off forced by a heartbeat, the 1.5 s timeout, a BYE or connection loss ends activated
    /// gestures with `.ended` (`.cancelled` only for never-activated ones), like the phone's own lift-off.
    ///
    /// Without `releaseDragLock` (a heartbeat: the phone's own lift-off datagram was lost, §4.7) it is exactly that
    /// lift-off, at the last frame's time: a pending tap still clicks, a drag opens its grace window or engages the
    /// lock, and a scroll may coast.
    public func forceLiftoff(releaseDragLock: Bool = true, into events: inout EventBuffer) {
        guard releaseDragLock else {
            process(TouchFrame(frameTime: lastFrameTime, isSyntheticLiftoff: true), into: &events)
            return
        }
        reset(into: &events, releaseDragLock: releaseDragLock, cancelGestures: false)
    }

    private var hasRestingThumbCandidate: Bool {
        tracker.slots.contains { contact in
            contact.active && !contact.palm && !contact.resting && contact.restingEligible &&
            contact.startY >= geometry.heightMM - 18 &&
            hypot(contact.x - contact.startX, contact.y - contact.startY) <= 1.5
        }
    }

    private func classifyRestingContacts(now: UInt64) {
        // §6.5.3: an activated sub-gesture keeps its mode until lift. Reclassifying one of its contacts as
        // resting would end it midway (a thumb-anchored four-finger pinch on a landscape phone passes 150 ms).
        let gestureActive = threeFingerDragActive || (mode == .multiFinger && multiFinger.active) ||
            (mode == .pendingScroll && twoFinger.hasActiveGesture)
        for i in tracker.slots.indices where !gestureActive {
            let contact = tracker.slots[i]
            var anotherFingerMoved = false
            for j in tracker.slots.indices where j != i && tracker.slots[j].active && !tracker.slots[j].palm && tracker.slots[j].moved {
                anotherFingerMoved = true
            }
            guard contact.active, !contact.palm, !contact.resting, contact.restingEligible,
                  anotherFingerMoved,
                  contact.y >= geometry.heightMM - 18, now >= contact.beganAt,
                  now - contact.beganAt >= 150_000_000,
                  hypot(contact.x - contact.startX, contact.y - contact.startY) <= 1.5 else { continue }
            tracker.slots[i].resting = true
        }
        tracker.recount()
        // A late finger left as the only one on the glass becomes the primary: when the fingers that fixed the
        // mode lift (or rest), the pointer follows the finger that remains, as on a real trackpad.
        guard tracker.effectiveCount == 0 else { return }
        var promoted = false
        for i in tracker.slots.indices where tracker.slots[i].active && tracker.slots[i].ignoredForMode && !tracker.slots[i].palm {
            tracker.slots[i].resting = false; tracker.slots[i].ignoredForMode = false; promoted = true
        }
        guard promoted else { return }
        tracker.recount()
        // The fingers of a released gesture are all gone: the finger left on the glass points (§6.5.3).
        if mode == .releasing { mode = .pointer; accumulatedX = 0; accumulatedY = 0 }
    }

    private func transitionMode(previousCount: Int, now: UInt64, cancelled: Bool = false, lifted: Bool = false,
                                into events: inout EventBuffer) {
        let count = tracker.effectiveCount
        if mode == .releasing {
            // Staggered lift-off of a 3+ finger gesture: wait for the last finger (owner decision 2026-10-28).
            if count == 0 { mode = .idle; accumulatedX = 0; accumulatedY = 0 }
            return
        }
        if mode == .idle, count > 0 {
            mode = .pointer
            let beganAt = earliestActiveContactTime()
            settleDeadline = beganAt &+ 60_000_000
        }
        // Fingers lifting out of a set of three or more never start anything new: real fingers do not leave the
        // glass in one 8 ms frame, so the set passes through "two" and "one" on its way to zero. A count that
        // drops because a contact was reclassified as resting (no lift) still re-evaluates normally (§6.5.3).
        // The same holds for two fingers (2026-10-29) once a sub-gesture activated or while the pair may still be a
        // two-finger tap: the last finger's motion as it leaves the glass is not pointer motion.
        let twoFingerRelease = mode == .pendingScroll && previousCount == 2 && count == 1 &&
            (twoFinger.hasActiveGesture || (now >= pendingScrollSince && now - pendingScrollSince <= 300_000_000))
        if lifted, count > 0, count < previousCount, previousCount >= 3 || mode == .multiFinger || twoFingerRelease {
            switch mode {
            case .multiFinger: multiFinger.end(cancelled: cancelled, now: now, into: &events)
            case .pendingScroll:
                if previousCount >= 3 { twoFinger.end(cancelled: true, natural: settings.naturalScrolling, into: &events) }
                else { endTwoFinger(now: now, cancelled: cancelled, into: &events) }
            case .idle, .pointer, .releasing: break
            }
            mode = .releasing
            return
        }
        if mode == .multiFinger, count < multiFinger.fingerCount {
            multiFinger.end(cancelled: cancelled, now: now, into: &events)
            mode = count == 0 ? .idle : .pointer
        }
        if (3...5).contains(count), now <= settleDeadline,
           !(count == 3 && settings.threeFingerDrag),
           (mode != .multiFinger || (!multiFinger.active && multiFinger.fingerCount != count)),
           let sample = multiFingerSample() {
            if mode == .pendingScroll { twoFinger.end(cancelled: true, natural: settings.naturalScrolling, into: &events) }
            mode = .multiFinger; multiFinger.begin(fingers: count, sample: sample, time: now)
        }
        // Two effective fingers in pointer mode always arm scrolling: inside the settle window (a normal
        // two-finger landing), after a thumb stops resting (§6.5.2), or when a multi-finger set drops to two
        // because one contact was reclassified as resting (a set that drops by *lifting* is `releasing`, above).
        // Late extra fingers never raise the count (they are `ignoredForMode`), so no window check is needed.
        if mode == .pointer, previousCount != 2, count == 2 {
            mode = .pendingScroll; appendScroll(.mayBegin, into: &events); pendingScrollSince = now
            (scrollAcceleration as? ScrollAccelerator)?.reset()
            momentum.clearSamples()
            if let pair = twoFingerGeometry() { twoFinger.begin(x: pair.x, y: pair.y, distance: pair.distance, angle: pair.angle, time: now, rightEdge: pair.rightEdge) }
        } else if mode == .pendingScroll, count < 2 {
            endTwoFinger(now: now, cancelled: cancelled, into: &events)
            mode = count == 0 ? .idle : .pointer
        } else if count == 0 {
            mode = .idle; accumulatedX = 0; accumulatedY = 0
        }
    }

    /// Ends the two-finger gesture; a scroll coasts (§6.8) unless a zoom or rotation took part in it.
    private func endTwoFinger(now: UInt64, cancelled: Bool, into events: inout EventBuffer) {
        if twoFinger.scrollActive && !twoFinger.zoomOrRotateActive && !cancelled {
            momentum.start(now: now, enabled: settings.momentumScrollEnabled)
        }
        twoFinger.end(cancelled: cancelled, natural: settings.naturalScrolling, into: &events)
    }

    /// §6.5.3 (2026-10-29): a late finger that landed outside the resting zone and then moves together with the
    /// one pointing finger is a second finger joining to scroll, as on a trackpad: it becomes effective and the
    /// mode re-evaluates (two fingers → scroll). A late finger moving alone, or a thumb in the resting zone, keeps
    /// the late-finger rules.
    private func promoteLateFingerMovingWithThePrimary() {
        let applies = mode == .pointer && tracker.effectiveCount == 1 && !dragButtonHeld
        let primary = applies ? tracker.slots.first(where: { $0.active && !$0.palm && !$0.resting }) : nil
        for i in tracker.slots.indices {
            let late = tracker.slots[i]
            guard late.active, late.ignoredForMode, !late.palm else { continue }
            guard let primary, late.startY < geometry.heightMM - 18 else { tracker.slots[i].anchored = false; continue }
            // Only motion made together counts: travel the primary made before (or while the late finger stayed
            // still), or a late finger moving alone, starts the measurement over from where both are now.
            let lateMoved = hypot(late.frameDX, late.frameDY) > 0.02
            let primaryMoved = hypot(primary.frameDX, primary.frameDY) > 0.02
            if !late.anchored || lateMoved != primaryMoved {
                tracker.slots[i].lateAnchorX = late.x; tracker.slots[i].lateAnchorY = late.y
                tracker.slots[i].partnerX = primary.x; tracker.slots[i].partnerY = primary.y
                tracker.slots[i].anchored = true
                continue
            }
            let lateDX = late.x - late.lateAnchorX, lateDY = late.y - late.lateAnchorY
            let primaryDX = primary.x - late.partnerX, primaryDY = primary.y - late.partnerY
            let meanDX = (lateDX + primaryDX) / 2, meanDY = (lateDY + primaryDY) / 2
            let meanLength = hypot(meanDX, meanDY)
            guard meanLength > 0 else { continue }
            let lateAlong = (lateDX * meanDX + lateDY * meanDY) / meanLength
            let primaryAlong = (primaryDX * meanDX + primaryDY * meanDY) / meanLength
            guard min(lateAlong, primaryAlong) > 1.5 else { continue }
            tracker.slots[i].resting = false; tracker.slots[i].ignoredForMode = false
            tracker.slots[i].restingEligible = false
            tracker.recount()
            return
        }
    }

    private func appendScroll(_ phase: GesturePhase, into events: inout EventBuffer) {
        events.append(.scroll(dxPoints: 0, dyPoints: 0, phase: phase, naturalInverted: settings.naturalScrolling))
    }

    private func earliestActiveContactTime() -> UInt64 {
        var earliest = UInt64.max
        for slot in tracker.slots where slot.active && !slot.palm && !slot.resting { earliest = min(earliest, slot.beganAt) }
        return earliest == UInt64.max ? 0 : earliest
    }

    private func reset(into events: inout EventBuffer, releaseDragLock: Bool, cancelGestures: Bool) {
        momentum.cancel(into: &events); stopMomentumRequested = false
        pendingTwoFingerTap = nil
        pendingDragPress = nil; pendingRegrab = nil
        if mode == .multiFinger { multiFinger.end(cancelled: cancelGestures, into: &events) }
        heldMotion = nil
        if mode == .pendingScroll { twoFinger.end(cancelled: cancelGestures, natural: settings.naturalScrolling, into: &events) }
        tapConsumedByGesture = false
        forceHoldCancelled = false
        let preserveLock = dragButtonHeld && dragLockEngaged && !releaseDragLock
        if dragButtonHeld && !preserveLock { events.append(.button(kind: .left, phase: .up, clickCount: dragClickCount)) }
        tracker.clear(); tapContacts.removeAll(keepingCapacity: true); mode = .idle; needsTick = false; accumulatedX = 0; accumulatedY = 0
        dragButtonHeld = preserveLock; dragLockEngaged = preserveLock; dragContactID = nil; dragReleaseDeadline = nil
        threeFingerDragStart = nil; threeFingerDragPrevious = nil; threeFingerDragPreviousTime = 0; threeFingerDragActive = false
        applyPendingSettings()
    }

    private func applyPendingSettings() {
        guard tracker.trackedCount == 0, !momentum.active, dragReleaseDeadline == nil, pendingTwoFingerTap == nil else { return }
        if let pendingSettings { applySettings(pendingSettings); self.pendingSettings = nil }
    }

    private func applySettings(_ settings: TrackpadSettings) {
        if settings != self.settings { settingsGeneration &+= 1 }
        self.settings = settings
        (acceleration as? PointerAccelerator)?.updateTrackingSpeed(settings.trackingSpeed)
        (scrollAcceleration as? ScrollAccelerator)?.updateTrackingSpeed(settings.trackingSpeed)
    }

    private func expireDragGrace(now: UInt64, into events: inout EventBuffer) {
        guard let deadline = dragReleaseDeadline, now >= deadline else { return }
        events.append(.button(kind: .left, phase: .up, clickCount: dragClickCount))
        dragButtonHeld = false; dragContactID = nil; dragReleaseDeadline = nil
    }

    /// Sub-point remainders accumulate in `accumulatedX/Y` so slow motion is never dropped (§6.5.4).
    private func emitAccumulatedPointerMove(dx: Double, dy: Double, into events: inout EventBuffer) {
        accumulatedX += dx; accumulatedY += dy
        guard abs(accumulatedX) >= 0.05 || abs(accumulatedY) >= 0.05 else { return }
        events.append(.pointerMove(dx: accumulatedX, dy: accumulatedY)); accumulatedX = 0; accumulatedY = 0
    }

    /// Drag bookkeeping shared by every way a drag contact can go away (`.ended`, `.cancelled`,
    /// vanished per §4.7, or its ID re-used): the release grace window opens or drag lock engages,
    /// so a lost or cancelled `ended` can never leave the button held (§8.8). A quick lift
    /// (`quickTap`) is left to `emitTapIfComplete`, which turns it into the click release.
    private func endDragContact(id: UInt8, quickTap: Bool, now: UInt64, into events: inout EventBuffer) {
        guard dragContactID == id else { return }
        dragContactID = nil
        guard dragButtonHeld, !threeFingerDragActive else { return }
        if quickTap { quickDragLiftAt = now; return }   // resolved after tap evaluation (`processContacts`)
        engageDragLockOrGrace(now: now, into: &events)
    }

    /// Emits the tap-and-a-half press that was waiting for the settle window (§6.5.6, 2026-10-29).
    private func pressPendingDrag(into events: inout EventBuffer) {
        guard let pending = pendingDragPress else { return }
        pendingDragPress = nil
        dragButtonHeld = true; dragClickCount = pending.count
        flushPendingSecondaryClick(into: &events)
        events.append(.button(kind: .left, phase: .down, clickCount: pending.count))
    }

    /// Decides a waiting tap-and-a-half press and a grace-window re-landing once the frame's mode is known: one
    /// finger after the settle window (or moving) presses / keeps the drag; a second finger joining inside it turns
    /// the repeat tap into whatever the fingers make, with no button held.
    private func resolvePendingDragPress(now: UInt64, into events: inout EventBuffer) {
        if let regrab = pendingRegrab {
            if mode != .pointer || tracker.effectiveCount > 1, !settings.threeFingerDrag, dragButtonHeld,
               dragContactID == regrab.id, !threeFingerDragActive {
                // With three-finger drag on, more fingers may be joining to continue the drag (§6.5.6).
                events.append(.button(kind: .left, phase: .up, clickCount: dragClickCount))
                dragButtonHeld = false; dragContactID = nil
                if let tapIndex = tapContacts.firstIndex(where: { $0.id == regrab.id }) { tapContacts[tapIndex].dragSequence = false }
                pendingRegrab = nil
            } else if now >= regrab.until || dragContactID != regrab.id {
                pendingRegrab = nil
            }
        }
        guard let pending = pendingDragPress else { return }
        guard let index = tracker.index(for: pending.id), mode == .pointer, tracker.effectiveCount == 1,
              !tracker.slots[index].resting else {
            pendingDragPress = nil
            if dragContactID == pending.id { dragContactID = nil }
            if let tapIndex = tapContacts.firstIndex(where: { $0.id == pending.id }) { tapContacts[tapIndex].dragSequence = false }
            return
        }
        if now >= pending.pressAt || tracker.slots[index].pathLength > Self.tapHysteresisMM { pressPendingDrag(into: &events) }
    }

    /// §4.7: a `began` for an ID that is still tracked means its `ended` was lost. The old contact ends here like
    /// a lift: its tap is decided before the new contact can join the tap set, and a drag opens its grace window.
    private func endReusedContact(at index: Int, now: UInt64, into events: inout EventBuffer) {
        let slot = tracker.slots[index]
        if pendingDragPress?.id == slot.id { pressPendingDrag(into: &events) }
        if pendingRegrab?.id == slot.id { pendingRegrab = nil }
        var quickTap = false
        if let tapIndex = tapContacts.firstIndex(where: { $0.id == slot.id }) {
            tapContacts[tapIndex].endedAt = now
            tapContacts[tapIndex].pathLength = slot.pathLength
            quickTap = slot.pathLength < 2.0 && now >= tapContacts[tapIndex].beganAt &&
                now - tapContacts[tapIndex].beganAt <= 300_000_000
        }
        endDragContact(id: slot.id, quickTap: quickTap, now: now, into: &events)
        tracker.slots[index].active = false
        tracker.recount()
        if tapContacts.allSatisfy({ $0.endedAt != nil }) { emitTapIfComplete(now: now, into: &events) }
        else { tapContacts.removeAll { $0.id == slot.id } }
    }

    private func engageDragLockOrGrace(now: UInt64, into events: inout EventBuffer) {
        guard dragButtonHeld, !dragLockEngaged, dragReleaseDeadline == nil else { return }
        if settings.dragLock {
            dragLockEngaged = true
            events.append(.haptic(.dragLockEngaged))
        } else {
            dragReleaseDeadline = now &+ 300_000_000
        }
    }

    private func multiFingerSample() -> MultiFingerRecognizer.Sample? {
        guard let center = activeCentroid(), tracker.effectiveCount >= 3 else { return nil }
        var radius = 0.0
        var meanDX = 0.0, meanDY = 0.0
        for contact in tracker.slots where contact.active && !contact.palm && !contact.resting {
            radius += hypot(contact.x - center.0, contact.y - center.1)
            meanDX += contact.x - contact.startX; meanDY += contact.y - contact.startY
        }
        let n = Double(tracker.effectiveCount)
        meanDX /= n; meanDY /= n
        // Travel every finger shares along the mean displacement (see `MultiFingerRecognizer.Sample`).
        let meanLength = hypot(meanDX, meanDY)
        var common = meanLength
        if meanLength > 0 {
            for contact in tracker.slots where contact.active && !contact.palm && !contact.resting {
                let along = ((contact.x - contact.startX) * meanDX + (contact.y - contact.startY) * meanDY) / meanLength
                common = min(common, max(0, along))
            }
        }
        return .init(x: center.0, y: center.1, radius: radius / n, commonTravel: common)
    }

    private func twoFingerGeometry() -> (x: Double, y: Double, distance: Double, angle: Double, rightEdge: Bool)? {
        var first: ContactSlot?
        for contact in tracker.slots where contact.active && !contact.palm && !contact.resting {
            if let first {
                let dx = contact.x - first.x, dy = contact.y - first.y
                return ((first.x + contact.x) / 2, (first.y + contact.y) / 2, hypot(dx, dy), -atan2(dy, dx), first.x >= geometry.widthMM - 3 && contact.x >= geometry.widthMM - 3)
            }
            first = contact
        }
        return nil
    }

    private func activeCentroid() -> (Double, Double)? {
        var x = 0.0, y = 0.0, count = 0
        for contact in tracker.slots where contact.active && !contact.palm && !contact.resting {
            x += contact.x; y += contact.y; count += 1
        }
        guard count > 0 else { return nil }
        return (x / Double(count), y / Double(count))
    }

    private func updateThreeFingerDrag(now: UInt64, oldCentroid: (Double, Double)?, into events: inout EventBuffer) {
        // A drag only starts from pointer or two-finger mode: fingers leaving a four-finger swipe pass through
        // three (`.releasing`) and must not press the button (§6.5.8 staggered lift-off).
        if settings.threeFingerDrag, tracker.effectiveCount == 3,
           threeFingerDragActive || mode == .pointer || mode == .pendingScroll, let center = activeCentroid() {
            if threeFingerDragStart == nil {
                threeFingerDragStart = center
                threeFingerDragPreviousTime = now
            }
            if let start = threeFingerDragStart, !threeFingerDragActive,
               hypot(center.0 - start.0, center.1 - start.1) > 2 {
                threeFingerDragActive = true
                dragContactID = nil; dragReleaseDeadline = nil
                if !dragButtonHeld {
                    // Re-landing inside the grace window or on a locked drag continues the held button.
                    dragButtonHeld = true; dragClickCount = 1
                    flushPendingSecondaryClick(into: &events)
                    events.append(.button(kind: .left, phase: .down, clickCount: 1))
                }
            }
            if threeFingerDragActive, let previous = oldCentroid {
                let delta = acceleration.accelerate(dxMM: center.0 - previous.0, dyMM: center.1 - previous.1,
                    dtNanoseconds: now &- threeFingerDragPreviousTime)
                // Slow motion accumulates like one-finger pointing (§6.5.4), never dropped.
                emitAccumulatedPointerMove(dx: delta.0, dy: delta.1, into: &events)
            }
            threeFingerDragPrevious = center; threeFingerDragPreviousTime = now
            return
        }
        threeFingerDragStart = nil; threeFingerDragPrevious = nil; threeFingerDragPreviousTime = 0
        guard threeFingerDragActive else { return }
        threeFingerDragActive = false; dragContactID = nil
        engageDragLockOrGrace(now: now, into: &events)
    }

    private func appendSecondaryClick(into events: inout EventBuffer) {
        events.append(.button(kind: .right, phase: .down, clickCount: 1))
        events.append(.button(kind: .right, phase: .up, clickCount: 1))
        events.append(.haptic(.secondaryClick))
    }

    /// Emits a pending two-finger secondary click now (smart zoom on, §6.5.7) — at `index` when given, so it
    /// precedes the gesture events that made it final — because what follows can no longer be the second tap.
    private func flushPendingSecondaryClick(into events: inout EventBuffer, at index: Int? = nil) {
        guard let pending = pendingTwoFingerTap else { return }
        pendingTwoFingerTap = nil
        guard pending.secondaryEnabled else { return }
        guard let index else { appendSecondaryClick(into: &events); return }
        events.insert(.button(kind: .right, phase: .down, clickCount: 1), at: index)
        events.insert(.button(kind: .right, phase: .up, clickCount: 1), at: index + 1)
        events.insert(.haptic(.secondaryClick), at: index + 2)
    }

    private func expireTwoFingerTap(now: UInt64, into events: inout EventBuffer) {
        guard let pending = pendingTwoFingerTap, now >= pending.deadline else { return }
        pendingTwoFingerTap = nil
        if pending.secondaryEnabled { appendSecondaryClick(into: &events) }
    }

    private func emitTapIfComplete(now: UInt64, into events: inout EventBuffer) {
        guard !tapContacts.isEmpty else { return }
        guard tapContacts.allSatisfy({ $0.endedAt != nil }) else {
            // A finger that stays down keeps the tap set open. Ended entries older than TAP_MAX_DURATION can
            // no longer belong to any tap (every rule bounds lastEnded − firstBegan by 0.30 s), so they are
            // dropped here: repeated taps beside a held finger must not grow the array past its reserved
            // capacity (§6.5.1 / §7: no allocation on the frame path).
            tapContacts.removeAll { $0.endedAt != nil && now >= $0.beganAt && now - $0.beganAt > 300_000_000 }
            return
        }
        if tapConsumedByGesture { tapContacts.removeAll(keepingCapacity: true); return }
        let count = tapContacts.count
        var firstBegan = UInt64.max, lastEnded: UInt64 = 0
        var withinMovement = true
        for contact in tapContacts {
            firstBegan = min(firstBegan, contact.beganAt)
            lastEnded = max(lastEnded, contact.endedAt ?? 0)
            withinMovement = withinMovement && contact.pathLength < 2.0
        }
        guard count <= 3, lastEnded >= firstBegan,
              lastEnded - firstBegan <= 300_000_000, withinMovement else {
            tapContacts.removeAll(keepingCapacity: true)
            return
        }
        if count == 3 {
            flushPendingSecondaryClick(into: &events)
            if settings.threeFingerTapGesture == 2 { events.append(.lookUpAtPointer) }
            tapContacts.removeAll(keepingCapacity: true)
            return
        }
        if count == 2 {
            let first = tapContacts[0], second = tapContacts[1]
            guard settings.trackpadRightClick || settings.smartZoomEnabled,
                  max(first.beganAt, second.beganAt) - min(first.beganAt, second.beganAt) <= 100_000_000 else {
                tapContacts.removeAll(keepingCapacity: true)
                return
            }
            if settings.smartZoomEnabled {
                if let pending = pendingTwoFingerTap, now < pending.deadline {
                    pendingTwoFingerTap = nil
                    events.append(.smartZoom)
                } else {
                    pendingTwoFingerTap = (now &+ settings.doubleClickIntervalNs, settings.trackpadRightClick)
                }
            } else { appendSecondaryClick(into: &events) }
            tapContacts.removeAll(keepingCapacity: true)
            return
        }
        guard let contact = tapContacts.first else { tapContacts.removeAll(keepingCapacity: true); return }
        // A one-finger tap is not the second two-finger tap a pending secondary click waits for (§6.5.7).
        flushPendingSecondaryClick(into: &events)
        if contact.releasesDragLock {
            events.append(.button(kind: .left, phase: .up, clickCount: dragClickCount))
            events.append(.haptic(.dragLockReleased))
            dragButtonHeld = false; dragLockEngaged = false; dragContactID = nil
            previousClickTime = nil; previousClickCount = 0
            tapContacts.removeAll(keepingCapacity: true)
            return
        }
        if contact.dragSequence {
            // `dragButtonHeld`: the grace window may already have released it (§6.5.6) — never a second up.
            if dragButtonHeld, contact.pathLength < 2.0, let ended = contact.endedAt,
               ended >= contact.beganAt, ended - contact.beganAt <= 300_000_000 {
                events.append(.button(kind: .left, phase: .up, clickCount: dragClickCount))
                events.append(.haptic(.click))
                dragButtonHeld = false; dragContactID = nil; dragReleaseDeadline = nil
                previousClickTime = ended; previousClickX = contact.startX; previousClickY = contact.startY
                previousClickCount = dragClickCount
            }
            tapContacts.removeAll(keepingCapacity: true)
            return
        }
        let corner = settings.cornerSecondaryClick
        let inBottom = contact.startY >= geometry.heightMM - 22
        let secondaryCorner = inBottom && ((corner == 1 && contact.startX <= 22) ||
            (corner == 2 && contact.startX >= geometry.widthMM - 22))
        let kind: ButtonKind = secondaryCorner ? .right : .left
        var clickCount = 1
        if kind == .left, let previousClickTime, let ended = contact.endedAt,
           ended >= previousClickTime, ended - previousClickTime < settings.doubleClickIntervalNs,
           hypot(contact.startX - previousClickX, contact.startY - previousClickY) <= 5 {
            clickCount = min(previousClickCount + 1, 3)
        }
        events.append(.button(kind: kind, phase: .down, clickCount: clickCount))
        events.append(.button(kind: kind, phase: .up, clickCount: clickCount))
        events.append(.haptic(secondaryCorner ? .secondaryClick : .click))
        if kind == .left, let ended = contact.endedAt {
            previousClickTime = ended; previousClickX = contact.startX; previousClickY = contact.startY
            previousClickCount = clickCount
        }
        tapContacts.removeAll(keepingCapacity: true)
        _ = now
    }
}
