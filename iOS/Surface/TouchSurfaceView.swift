import UIKit
import TrackglassKit

final class TouchSurfaceView: UIView {
    private lazy var renderer = SurfaceRenderer(layer: layer)
    var geometryDidChange: ((SurfaceGeometry) -> Void)?
    private var lastGeometry: SurfaceGeometry?
    let frameSender: FrameSender
    private var touchFrame = TouchFrame()
    private let contacts = LiveContactTable<UITouch>()
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
    }

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
        let geometry = SurfaceGeometry(ppi: ppi, nativeScale: screen.nativeScale,
                                       boundsInPoints: SurfaceSize(width: bounds.width, height: bounds.height))
        renderer.layout(bounds: bounds, mmPerPoint: geometry.mmPerPoint)
        guard geometry != lastGeometry else { return }
        lastGeometry = geometry
        geometryDidChange?(geometry)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where TouchSample.kind(touch.type) != nil && TouchSample.phase(touch.phase) != nil {
            contacts.insert(touch)
        }
        emit(event: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        displayLinkDriver.recordMovedEvent()
        // UIKit splits one UIEvent into began/moved/ended calls; a frame for this event with the same
        // contacts was already emitted by `touchesBegan`, so sending it again would only double the traffic.
        if let event, TouchSample.timestampNanoseconds(event.timestamp) == lastEmitTimeNs,
           contacts.count == lastEmitContactCount { return }
        emit(event: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let hadContacts = contacts.count > 0
        emit(event: event)
        for touch in touches { contacts.remove(touch) }
        if hadContacts && contacts.count == 0 { emitSyntheticLiftoff(event: event) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let hadContacts = contacts.count > 0
        emit(event: event)
        for touch in touches { contacts.remove(touch) }
        if hadContacts && contacts.count == 0 { emitSyntheticLiftoff(event: event) }
    }

    private func emit(event: UIEvent?) {
        guard let event, let screen = window?.screen, contacts.count > 0 else { return }
        let geometry = SurfaceGeometry(ppi: ppi, nativeScale: screen.nativeScale,
                                       boundsInPoints: SurfaceSize(width: bounds.width, height: bounds.height))
        touchFrame.removeAllContacts()
        touchFrame.isSyntheticLiftoff = false
        touchFrame.header.sequence = sequence
        touchFrame.frameTime = TouchSample.timestampNanoseconds(event.timestamp)
        touchFrame.surfaceIsLandscape = bounds.width > bounds.height
        for index in 0..<LiveContactTable<UITouch>.capacity {
            guard let entry = contacts[index], let phase = TouchSample.phase(entry.touch.phase),
                  let kind = TouchSample.kind(entry.touch.type) else { continue }
            touchFrame.append(TouchSample.contact(id: entry.contactID, phase: phase, kind: kind,
                                             location: entry.touch.preciseLocation(in: self),
                                             majorRadius: entry.touch.majorRadius, geometry: geometry))
        }
        guard touchFrame.contactCount > 0 else { return }
        sequence &+= 1
        lastEmitTimeNs = touchFrame.frameTime
        lastEmitContactCount = contacts.count
        frameSender.enqueue(touchFrame)
    }

    /// §4.7: the Mac force-releases every held button after 1.5 s without a frame or heartbeat while
    /// contacts are tracked, and UIKit delivers nothing for a finger that holds still. While any contact
    /// is down, a frame with every contact marked `.stationary` goes out at least every 0.5 s.
    /// Runs on the display-link tick; reuses `touchFrame`, so it allocates nothing.
    private func emitStationaryKeepAliveIfNeeded() {
        guard contacts.count > 0, let screen = window?.screen else { return }
        let now = MonotonicClock.nanoseconds()
        guard now &- lastEmitTimeNs >= 500_000_000 else { return }
        let geometry = SurfaceGeometry(ppi: ppi, nativeScale: screen.nativeScale,
                                       boundsInPoints: SurfaceSize(width: bounds.width, height: bounds.height))
        touchFrame.removeAllContacts()
        touchFrame.isSyntheticLiftoff = false
        touchFrame.header.sequence = sequence
        touchFrame.frameTime = now
        touchFrame.surfaceIsLandscape = bounds.width > bounds.height
        for index in 0..<LiveContactTable<UITouch>.capacity {
            guard let entry = contacts[index], TouchSample.phase(entry.touch.phase) != nil,
                  let kind = TouchSample.kind(entry.touch.type) else { continue }
            // The UIKit phase may still read `.began`/`.moved`; `.stationary` keeps the Mac's contact ages intact.
            touchFrame.append(TouchSample.contact(id: entry.contactID, phase: .stationary, kind: kind,
                                             location: entry.touch.preciseLocation(in: self),
                                             majorRadius: entry.touch.majorRadius, geometry: geometry))
        }
        guard touchFrame.contactCount > 0 else { return }
        sequence &+= 1
        lastEmitTimeNs = now
        frameSender.enqueue(touchFrame)
    }

    private func emitSyntheticLiftoff(event: UIEvent?) {
        guard let event else { return }
        touchFrame.removeAllContacts()
        touchFrame.header.sequence = sequence
        touchFrame.frameTime = TouchSample.timestampNanoseconds(event.timestamp)
        touchFrame.surfaceIsLandscape = bounds.width > bounds.height
        touchFrame.isSyntheticLiftoff = true
        sequence &+= 1
        lastEmitTimeNs = touchFrame.frameTime
        frameSender.enqueue(touchFrame)
    }

    private static func modelIdentifier() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
