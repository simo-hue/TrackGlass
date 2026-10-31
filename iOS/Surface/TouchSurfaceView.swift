import UIKit
import TrackglassKit

final class TouchSurfaceView: UIView {
    private lazy var renderer = SurfaceRenderer(layer: layer)
    var geometryDidChange: ((SurfaceGeometry) -> Void)?
    private var lastGeometry: SurfaceGeometry?
    let frameSender: FrameSender
    private var touchFrame = TouchFrame()
    private let contacts = LiveContactTable<any TouchLike>()
    private let ppi = DevicePPI.lookup(modelIdentifier: TouchSurfaceView.modelIdentifier())
    private var sequence: UInt32 = 0
    /// Stamp of the last frame sent (monotonic: §4.7 makes the Mac drop any frame whose time goes backwards).
    private var lastEmitTimeNs: UInt64 = 0
    /// Raw event time of the last frame sent, before the monotonic clamp; used only to spot UIKit's
    /// began/moved split of one event (`ingestMoved`).
    private var lastRawEmitTimeNs: UInt64 = 0
    private var lastEmitContactCount = 0
    private let displayLinkDriver = DisplayLinkDriver()
    /// Called when the first finger of a touch sequence lands (the haptic engine starts warming up then).
    var onFirstContactBegan: (() -> Void)?
    /// Frame times leave the device as time since this launch, not as device uptime (which would identify the
    /// device across sessions). Only differences matter to the Mac (§4.7 monotonicity, engine timing). The epoch is
    /// the wire clock's, so `frameTime` and every header's `sentAt` (§4.2) count from the same instant.
    static var launchEpochNs: UInt64 { MonotonicClock.wireEpochNanoseconds }
    /// Tests pin it to 0 to assert raw event times.
    var timeEpochNs = TouchSurfaceView.launchEpochNs

    override init(frame: CGRect) {
        frameSender = FrameSender(sink: ConsoleFrameSink())
        super.init(frame: frame)
        configure()
    }

    init(frame: CGRect, sink: any FrameSink) {
        frameSender = FrameSender(sink: sink)
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        frameSender = FrameSender(sink: ConsoleFrameSink())
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = .black
        _ = renderer
        // VoiceOver: one element whose touches pass straight through to the Mac.
        isAccessibilityElement = true
        accessibilityLabel = "Trackpad"
        accessibilityHint = "Move, tap and use gestures here to control your Mac."
        accessibilityTraits = .allowsDirectInteraction
        displayLinkDriver.onTick = { [weak self] in
            guard let self, let geometry = self.lastGeometry else { return }
            self.emitStationaryKeepAliveIfNeeded()
            self.renderer.render(self.touchFrame, mmPerPoint: geometry.mmPerPoint)
        }
        isMultipleTouchEnabled = true
        isExclusiveTouch = true
        isUserInteractionEnabled = true
    }

    func suspend() {
        displayLinkDriver.stop()
        contacts.removeAll()
        // Same clock domain and monotonic clamp as every other frame (§4.7).
        emitSyntheticLiftoff(timeNs: MonotonicClock.nanoseconds())
        if let geometry = lastGeometry { renderer.render(touchFrame, mmPerPoint: geometry.mmPerPoint) }
    }
    func resume() { if let screen = window?.screen { displayLinkDriver.start(screen: screen) } }

    func applyTheme(_ theme: Theme) {
        renderer.apply(theme)
        setNeedsLayout()
    }

    /// Disables halo rendering while the device is thermally constrained (SPEC §5.9). Frames keep flowing.
    func setHalosSuppressed(_ suppressed: Bool) { renderer.setHalosSuppressed(suppressed) }
    var halosSuppressed: Bool { renderer.halosSuppressed }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let screen = window?.screen {
            displayLinkDriver.start(screen: screen)
            // A layout pass that ran while the view was out of the window (rotated behind a full-screen sheet) was
            // skipped: re-derive the geometry now, or frames would stay refused by the orientation check.
            setNeedsLayout()
        } else {
            displayLinkDriver.stop()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A zero-size (or NaN) layout pass during a scene transition is skipped: the last valid geometry stands (C3).
        guard let screen = window?.screen, bounds.width > 0, bounds.height > 0 else { return }
        updateGeometry(SurfaceGeometry(ppi: ppi, nativeScale: screen.nativeScale,
                                       boundsInPoints: SurfaceSize(width: bounds.width, height: bounds.height)))
    }

    /// Tests have no window/screen; they inject the geometry the surface would derive from one. A geometry that
    /// cannot be sent in HELLO/SURFACE is ignored (C3, L9), so frames keep the last valid one.
    func updateGeometry(_ geometry: SurfaceGeometry, now: UInt64 = MonotonicClock.nanoseconds()) {
        guard geometry.isValid else { return }
        renderer.layout(bounds: bounds, mmPerPoint: geometry.mmPerPoint)
        guard geometry != lastGeometry else { return }
        if let previous = lastGeometry, Self.isLandscape(previous) != Self.isLandscape(geometry) {
            cancelLiveContactsForRotation(surfaceWasLandscape: Self.isLandscape(previous), timeNs: now)
        }
        lastGeometry = geometry
        geometryDidChange?(geometry)
    }

    private static func isLandscape(_ geometry: SurfaceGeometry) -> Bool { geometry.widthMM > geometry.heightMM }

    /// L10: after a rotation `preciseLocation` already reports the new orientation while the Mac still has the old
    /// SURFACE (TCP, unordered with these datagrams), so live contacts would jump tens of millimetres in one frame.
    /// They are cancelled where they were last sent, flagged with the old orientation, then lifted off; their
    /// UITouches are no longer in the table, so they are ignored until they end. A cancelled contact never clicks.
    private func cancelLiveContactsForRotation(surfaceWasLandscape: Bool, timeNs: UInt64) {
        guard contacts.count > 0 else { return }
        // `touchFrame` still holds the last frame built, i.e. every live contact at its last sent position.
        let last = touchFrame
        touchFrame.removeAllContacts()
        for index in 0..<last.contactCount where last[index].phase != .ended && last[index].phase != .cancelled {
            var contact = last[index]
            contact.phase = .cancelled
            touchFrame.append(contact)
        }
        contacts.removeAll()
        if touchFrame.contactCount > 0 {
            touchFrame.header.sequence = sequence
            touchFrame.frameTime = monotonicFrameTime(timeNs)
            touchFrame.surfaceIsLandscape = surfaceWasLandscape
            touchFrame.isSyntheticLiftoff = false
            sequence &+= 1
            lastEmitTimeNs = touchFrame.frameTime
            lastRawEmitTimeNs = timeNs
            lastEmitContactCount = 0
            frameSender.enqueue(touchFrame)
        }
        emitSyntheticLiftoff(timeNs: timeNs, surfaceIsLandscape: surfaceWasLandscape)
    }

    // MARK: UIKit entry points — thin wrappers over the testable ingest API below.

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        ingestBegan(touches, at: event?.timestamp ?? ProcessInfo.processInfo.systemUptime)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        displayLinkDriver.recordMovedEvent()
        let timestamp = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
        if coalescedSamplesEnabled, let event {
            ingestCoalescedSamples(at: timestamp) { (contact: any TouchLike) -> [UITouch]? in
                // Only this event's moving touches take per-sample values (a hashed lookup, no Set iteration).
                guard let touch = contact as? UITouch, touches.contains(touch) else { return nil }
                return event.coalescedTouches(for: touch)
            }
        }
        ingestMoved(touches, at: timestamp)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        ingestEnded(touches, at: event?.timestamp ?? ProcessInfo.processInfo.systemUptime)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        ingestEnded(touches, at: event?.timestamp ?? ProcessInfo.processInfo.systemUptime)
    }

    // MARK: Ingest API (generic over the sequence so UIKit's `Set<UITouch>` is iterated without copying)

    func ingestBegan<S: Sequence>(_ touches: S, at timestamp: TimeInterval) where S.Element: TouchLike {
        let wasEmpty = contacts.count == 0
        for touch in touches where TouchSample.kind(touch.type) != nil && TouchSample.phase(touch.phase) != nil {
            contacts.insert(touch)
        }
        emitCurrentContacts(timeNs: TouchSample.timestampNanoseconds(timestamp))
        if wasEmpty, contacts.count > 0 { onFirstContactBegan?() }
    }

    func ingestMoved<S: Sequence>(_ touches: S, at timestamp: TimeInterval) where S.Element: TouchLike {
        // UIKit splits one UIEvent into began/moved/ended calls; a frame for this event with the same
        // contacts was already emitted by `ingestBegan`, so sending it again would only double the traffic.
        let timeNs = TouchSample.timestampNanoseconds(timestamp)
        if timeNs == lastRawEmitTimeNs, contacts.count == lastEmitContactCount { return }
        emitCurrentContacts(timeNs: timeNs)
    }

    /// Ended and cancelled alike: the terminal phases ship in a frame first, then the contacts are
    /// released and, when none remain, the synthetic lift-off follows (§5.2).
    func ingestEnded<S: Sequence>(_ touches: S, at timestamp: TimeInterval) where S.Element: TouchLike {
        let hadContacts = contacts.count > 0
        let timeNs = TouchSample.timestampNanoseconds(timestamp)
        // When one finger lifts while another moves, UIKit calls `touchesMoved` and then `touchesEnded` for the
        // same event; the moved call already sent this event's frame with the lifting finger's live `.ended`
        // phase, so it is not sent twice (§4.4: the Mac would see the terminal phase of an untracked contact).
        if timeNs != lastRawEmitTimeNs || contacts.count != lastEmitContactCount { emitCurrentContacts(timeNs: timeNs) }
        for touch in touches { contacts.remove(touch) }
        if hadContacts && contacts.count == 0 { emitSyntheticLiftoff(timeNs: timeNs) }
    }

    /// M10.3 (capability bit 1): when the touch digitizer runs faster than the display, UIKit coalesces the
    /// intermediate samples into the delivered touch. Opt-in until the owner's velocity comparison decides. HELLO
    /// declares it once per connection, so the root controller sets it when a session starts, not mid-session.
    var coalescedSamplesEnabled = UserDefaults.standard.bool(forKey: "coalescedSamples")

    /// Sends one frame per *intermediate* coalesced sample of this event's moving touches; the event's last sample is
    /// the frame `ingestMoved` sends right after, with every contact's live phase. A contact that does not move in this
    /// event is `.stationary` in the intermediate frames, so its `.began` or terminal phase goes out once: repeated
    /// per sample, a `.began` would make the Mac end and restart that finger (§4.7) and an `.ended` would end it at
    /// the first sample's time. `movingSamples` returns a contact's samples when it is one of `touchesMoved`'s touches
    /// and nil for any other: `UIEvent.coalescedTouches(for:)` in the app (UIKit allocates those arrays, the frames do
    /// not), fakes in tests.
    func ingestCoalescedSamples<Sample: TouchSampleLike>(at timestamp: TimeInterval,
                                                         movingSamples: (any TouchLike) -> [Sample]?) {
        let eventTimeNs = TouchSample.timestampNanoseconds(timestamp)
        // `ingestBegan` already sent this event's frame (a finger landed in it): older samples sent now would move the
        // contacts backwards, so that frame stands alone, as without coalescing (`ingestMoved` skips it too).
        if eventTimeNs == lastRawEmitTimeNs, contacts.count == lastEmitContactCount { return }
        // The moving contact with the most samples sets the sample times.
        var reference: [Sample] = []
        for index in 0..<LiveContactTable<any TouchLike>.capacity {
            guard let entry = contacts[index], let list = movingSamples(entry.touch), list.count > reference.count else { continue }
            reference = list
        }
        guard reference.count > 1 else { return }
        for sampleIndex in 0..<(reference.count - 1) {
            let sampleTimeNs = TouchSample.timestampNanoseconds(reference[sampleIndex].timestamp)
            // A sample stamped like the event is the event's own frame; sent here, `ingestMoved` would drop the
            // frame carrying the live phases as a duplicate.
            guard sampleTimeNs < eventTimeNs else { break }
            emitFrame(timeNs: { sampleTimeNs }) { entry in
                if let list = movingSamples(entry.touch), !list.isEmpty {
                    let sample = list[min(sampleIndex, list.count - 1)]
                    return (sample.preciseLocation(in: self), sample.phase, sample.majorRadius)
                }
                return (entry.touch.preciseLocation(in: self), .stationary, entry.touch.majorRadius)
            }
        }
    }

    private func emitCurrentContacts(timeNs: UInt64) {
        emitFrame(timeNs: { timeNs }) { entry in (entry.touch.preciseLocation(in: self), entry.touch.phase, entry.touch.majorRadius) }
    }

    /// Builds and sends one frame from the live table. `sample` is non-escaping, so neither closure allocates.
    private func emitFrame(timeNs: () -> UInt64,
                           sample: (LiveContactTable<any TouchLike>.Entry) -> (CGPoint, UITouch.Phase, CGFloat)) {
        // A frame's orientation always matches the last geometry reported (SURFACE): between a bounds change and the
        // layout pass that cancels the live contacts (L10), `preciseLocation` already answers in the new orientation.
        guard let geometry = lastGeometry, contacts.count > 0,
              (bounds.width > bounds.height) == Self.isLandscape(geometry) else { return }
        touchFrame.removeAllContacts()
        touchFrame.isSyntheticLiftoff = false
        touchFrame.surfaceIsLandscape = bounds.width > bounds.height
        for index in 0..<LiveContactTable<any TouchLike>.capacity {
            guard let entry = contacts[index], let kind = TouchSample.kind(entry.touch.type) else { continue }
            let (location, uiPhase, radius) = sample(entry)
            guard let phase = TouchSample.phase(uiPhase) else { continue }
            touchFrame.append(TouchSample.contact(id: entry.contactID, phase: phase, kind: kind,
                                             location: location, majorRadius: radius, geometry: geometry))
        }
        guard touchFrame.contactCount > 0 else { return }
        touchFrame.header.sequence = sequence
        let rawTimeNs = timeNs()
        touchFrame.frameTime = monotonicFrameTime(rawTimeNs)
        sequence &+= 1
        lastEmitTimeNs = touchFrame.frameTime
        lastRawEmitTimeNs = rawTimeNs
        lastEmitContactCount = contacts.count
        frameSender.enqueue(touchFrame)
    }

    /// A stationary keep-alive is stamped with the display-link time, which is a few milliseconds *after*
    /// the digitizer sample of the next UIKit event (`UIEvent.timestamp` is the sample time, delivery comes
    /// later). The Mac drops a frame whose time is lower than the last accepted one (§4.7, §8.9), and the
    /// dropped frame may be the `ended` phase plus its synthetic lift-off — a phantom finger until the
    /// 1.5 s timeout. Frame times therefore never go backwards: a late sample inherits the last stamp (the
    /// engine then carries its motion into the next frame instead of losing it).
    private func monotonicFrameTime(_ timeNs: UInt64) -> UInt64 { max(elapsedSinceEpoch(timeNs), lastEmitTimeNs) }

    private func elapsedSinceEpoch(_ timeNs: UInt64) -> UInt64 { timeNs > timeEpochNs ? timeNs - timeEpochNs : 0 }

    /// §4.7: the Mac force-releases every held button after 1.5 s without a frame or heartbeat while
    /// contacts are tracked, and UIKit delivers nothing for a finger that holds still. While any contact
    /// is down, a frame with every contact marked `.stationary` goes out at least every 0.5 s.
    /// Runs on the display-link tick; reuses `touchFrame`, so it allocates nothing.
    ///
    /// A contact whose UIKit phase already reads `.ended`/`.cancelled` (UIKit never delivered its end, e.g. the
    /// view left the window mid-touch) is not kept alive as `.stationary`: its terminal phase goes out once and
    /// the contact is dropped, followed by the lift-off when it was the last one.
    func emitStationaryKeepAliveIfNeeded(now: UInt64 = MonotonicClock.nanoseconds()) {
        let elapsed = elapsedSinceEpoch(now)
        guard contacts.count > 0, elapsed >= lastEmitTimeNs, elapsed - lastEmitTimeNs >= 500_000_000 else { return }
        var hasTerminal = false
        for index in 0..<LiveContactTable<any TouchLike>.capacity {
            if let entry = contacts[index], Self.isTerminal(entry.touch.phase) { hasTerminal = true; break }
        }
        // The UIKit phase may still read `.began`/`.moved`; `.stationary` keeps the Mac's contact ages intact.
        emitFrame(timeNs: { now }) { entry in
            let phase = entry.touch.phase
            return (entry.touch.preciseLocation(in: self), Self.isTerminal(phase) ? phase : .stationary, entry.touch.majorRadius)
        }
        guard hasTerminal else { return }
        for index in 0..<LiveContactTable<any TouchLike>.capacity {
            if let entry = contacts[index], Self.isTerminal(entry.touch.phase) { contacts.remove(entry.touch) }
        }
        if contacts.count == 0 { emitSyntheticLiftoff(timeNs: now) }
    }

    private static func isTerminal(_ phase: UITouch.Phase) -> Bool { phase == .ended || phase == .cancelled }

    private func emitSyntheticLiftoff(timeNs: UInt64, surfaceIsLandscape: Bool? = nil) {
        touchFrame.removeAllContacts()
        touchFrame.header.sequence = sequence
        touchFrame.frameTime = monotonicFrameTime(timeNs)
        touchFrame.surfaceIsLandscape = surfaceIsLandscape ?? (bounds.width > bounds.height)
        touchFrame.isSyntheticLiftoff = true
        sequence &+= 1
        lastEmitTimeNs = touchFrame.frameTime
        lastRawEmitTimeNs = timeNs
        frameSender.enqueue(touchFrame)
    }

    private static func modelIdentifier() -> String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        #endif
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
