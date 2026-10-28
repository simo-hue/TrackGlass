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
    private var lastEmitTimeNs: UInt64 = 0
    private var lastEmitContactCount = 0
    private let displayLinkDriver = DisplayLinkDriver()

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
        // The Diagnostics toggle changes the default; refresh the cached flag off the touch path.
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.coalescedSamplesEnabled = UserDefaults.standard.bool(forKey: "coalescedSamples") }
        }
    }
    private var defaultsObserver: NSObjectProtocol?

    func suspend() {
        displayLinkDriver.stop()
        contacts.removeAll(); touchFrame.removeAllContacts()
        touchFrame.isSyntheticLiftoff = true
        touchFrame.header.sequence = sequence; sequence &+= 1
        touchFrame.frameTime = MonotonicClock.nanoseconds()
        frameSender.enqueue(touchFrame)
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
        } else {
            displayLinkDriver.stop()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let screen = window?.screen else { return }
        updateGeometry(SurfaceGeometry(ppi: ppi, nativeScale: screen.nativeScale,
                                       boundsInPoints: SurfaceSize(width: bounds.width, height: bounds.height)))
    }

    /// Tests have no window/screen; they inject the geometry the surface would derive from one.
    func updateGeometry(_ geometry: SurfaceGeometry) {
        renderer.layout(bounds: bounds, mmPerPoint: geometry.mmPerPoint)
        guard geometry != lastGeometry else { return }
        lastGeometry = geometry
        geometryDidChange?(geometry)
    }

    // MARK: UIKit entry points — thin wrappers over the testable ingest API below.

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        ingestBegan(touches, at: event?.timestamp ?? ProcessInfo.processInfo.systemUptime)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        displayLinkDriver.recordMovedEvent()
        if coalescedSamplesEnabled, let event, ingestCoalesced(touches, event: event) { return }
        ingestMoved(touches, at: event?.timestamp ?? ProcessInfo.processInfo.systemUptime)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        ingestEnded(touches, at: event?.timestamp ?? ProcessInfo.processInfo.systemUptime)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        ingestEnded(touches, at: event?.timestamp ?? ProcessInfo.processInfo.systemUptime)
    }

    // MARK: Ingest API (generic over the sequence so UIKit's `Set<UITouch>` is iterated without copying)

    func ingestBegan<S: Sequence>(_ touches: S, at timestamp: TimeInterval) where S.Element: TouchLike {
        for touch in touches where TouchSample.kind(touch.type) != nil && TouchSample.phase(touch.phase) != nil {
            contacts.insert(touch)
        }
        emitCurrentContacts(timeNs: TouchSample.timestampNanoseconds(timestamp))
    }

    func ingestMoved<S: Sequence>(_ touches: S, at timestamp: TimeInterval) where S.Element: TouchLike {
        // UIKit splits one UIEvent into began/moved/ended calls; a frame for this event with the same
        // contacts was already emitted by `ingestBegan`, so sending it again would only double the traffic.
        let timeNs = TouchSample.timestampNanoseconds(timestamp)
        if timeNs == lastEmitTimeNs, contacts.count == lastEmitContactCount { return }
        emitCurrentContacts(timeNs: timeNs)
    }

    /// Ended and cancelled alike: the terminal phases ship in a frame first, then the contacts are
    /// released and, when none remain, the synthetic lift-off follows (§5.2).
    func ingestEnded<S: Sequence>(_ touches: S, at timestamp: TimeInterval) where S.Element: TouchLike {
        let hadContacts = contacts.count > 0
        let timeNs = TouchSample.timestampNanoseconds(timestamp)
        emitCurrentContacts(timeNs: timeNs)
        for touch in touches { contacts.remove(touch) }
        if hadContacts && contacts.count == 0 { emitSyntheticLiftoff(timeNs: timeNs) }
    }

    /// M10.3 (capability bit 1): when the touch digitizer runs faster than the display, UIKit coalesces the
    /// intermediate samples into the delivered touch. Opt-in until the owner's velocity comparison decides.
    var coalescedSamplesEnabled = UserDefaults.standard.bool(forKey: "coalescedSamples")

    /// Emits one frame per coalesced sample index. Returns false when no touch carried extra samples,
    /// so the caller falls back to the plain path. UIKit allocates the sample arrays; our frames do not.
    private func ingestCoalesced(_ touches: Set<UITouch>, event: UIEvent) -> Bool {
        var sampleCount = 0
        for touch in touches { sampleCount = max(sampleCount, event.coalescedTouches(for: touch)?.count ?? 0) }
        guard sampleCount > 1 else { return false }
        for sampleIndex in 0..<sampleCount {
            var timeNs: UInt64 = 0
            emitFrame(timeNs: { timeNs == 0 ? TouchSample.timestampNanoseconds(event.timestamp) : timeNs }) { entry in
                guard let touch = entry.touch as? UITouch, touches.contains(touch),
                      let samples = event.coalescedTouches(for: touch), !samples.isEmpty else {
                    return (entry.touch.preciseLocation(in: self), entry.touch.phase, entry.touch.majorRadius)
                }
                let sample = samples[min(sampleIndex, samples.count - 1)]
                timeNs = TouchSample.timestampNanoseconds(sample.timestamp)
                return (sample.preciseLocation(in: self), sample.phase, sample.majorRadius)
            }
        }
        return true
    }

    private func emitCurrentContacts(timeNs: UInt64) {
        emitFrame(timeNs: { timeNs }) { entry in (entry.touch.preciseLocation(in: self), entry.touch.phase, entry.touch.majorRadius) }
    }

    /// Builds and sends one frame from the live table. `sample` is non-escaping, so neither closure allocates.
    private func emitFrame(timeNs: () -> UInt64,
                           sample: (LiveContactTable<any TouchLike>.Entry) -> (CGPoint, UITouch.Phase, CGFloat)) {
        guard let geometry = lastGeometry, contacts.count > 0 else { return }
        touchFrame.removeAllContacts()
        touchFrame.isSyntheticLiftoff = false
        touchFrame.header.sequence = sequence
        touchFrame.surfaceIsLandscape = bounds.width > bounds.height
        for index in 0..<LiveContactTable<any TouchLike>.capacity {
            guard let entry = contacts[index], let kind = TouchSample.kind(entry.touch.type) else { continue }
            let (location, uiPhase, radius) = sample(entry)
            guard let phase = TouchSample.phase(uiPhase) else { continue }
            touchFrame.append(TouchSample.contact(id: entry.contactID, phase: phase, kind: kind,
                                             location: location, majorRadius: radius, geometry: geometry))
        }
        guard touchFrame.contactCount > 0 else { return }
        touchFrame.frameTime = timeNs()
        sequence &+= 1
        lastEmitTimeNs = touchFrame.frameTime
        lastEmitContactCount = contacts.count
        frameSender.enqueue(touchFrame)
    }

    /// §4.7: the Mac force-releases every held button after 1.5 s without a frame or heartbeat while
    /// contacts are tracked, and UIKit delivers nothing for a finger that holds still. While any contact
    /// is down, a frame with every contact marked `.stationary` goes out at least every 0.5 s.
    /// Runs on the display-link tick; reuses `touchFrame`, so it allocates nothing.
    func emitStationaryKeepAliveIfNeeded(now: UInt64 = MonotonicClock.nanoseconds()) {
        guard contacts.count > 0, now &- lastEmitTimeNs >= 500_000_000 else { return }
        // The UIKit phase may still read `.began`/`.moved`; `.stationary` keeps the Mac's contact ages intact.
        emitFrame(timeNs: { now }) { entry in (entry.touch.preciseLocation(in: self), .stationary, entry.touch.majorRadius) }
    }

    private func emitSyntheticLiftoff(timeNs: UInt64) {
        touchFrame.removeAllContacts()
        touchFrame.header.sequence = sequence
        touchFrame.frameTime = timeNs
        touchFrame.surfaceIsLandscape = bounds.width > bounds.height
        touchFrame.isSyntheticLiftoff = true
        sequence &+= 1
        lastEmitTimeNs = timeNs
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
