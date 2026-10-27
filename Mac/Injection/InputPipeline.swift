import Foundation
import Network
import OSLog
import TrackglassEngine
import TrackglassKit

final class InputPipeline: @unchecked Sendable {
    let queue: DispatchQueue
    private let engine: GestureEngine
    private let injector: InputInjector
    private let logger = Logger(subsystem: "app.trackglass.mac", category: "engine")
    private var geometry: EngineGeometry
    private var recorder: ReplayRecorder?
    private var events = EventBuffer()
    private var timer: DispatchSourceTimer?
    private var lastFrameTime: UInt64?
    private var lastReceiveTime: UInt64 = 0
    private var lastInputUptime: UInt64 = 0
    var diagnosticEngineState: UInt8 { engine.hasActiveContacts ? 1 : 0 }
    var onHaptic: ((HapticKind) -> Void)?
    var onEstimatedTick: ((UInt64) -> Void)?
    private(set) var outOfOrderFrames = 0
    private(set) var backwardsTimeFrames = 0
    /// Receive → post durations of accepted frames (SPEC §6.10), read by the status timer.
    private(set) var latency = LatencyStats()

    init(queue: DispatchQueue, geometry: EngineGeometry, settings: TrackpadSettings = TrackpadSettings(),
         injector: InputInjector = QuartzInjector(), acceleration: (any AccelerationModel)? = nil) {
        self.queue = queue; self.geometry = geometry
        let accelerationModel = acceleration ?? PointerAccelerationProvider.make(settings: settings)
        self.engine = GestureEngine(settings: settings, geometry: geometry, acceleration: accelerationModel,
            scrollAcceleration: PointerAccelerationProvider.makeScroll(settings: settings))
        self.injector = injector
    }
    func consume(_ data: Data) {
        dispatchPrecondition(condition: .onQueue(queue))
        let receiveTime = DispatchTime.now().uptimeNanoseconds
        guard let frame = try? data.withUnsafeBytes({ try TouchFrameDecoder.decode($0) }) else { return }
        if let lastSequence {
            let sequenceDelta = frame.header.sequence &- lastSequence
            if sequenceDelta == 0 || sequenceDelta >= 0x8000_0000 { outOfOrderFrames += 1; return }
        }
        if let lastFrameTime {
            if frame.frameTime < lastFrameTime { backwardsTimeFrames += 1; return }
        }
        lastSequence = frame.header.sequence
        lastFrameTime = frame.frameTime
        lastReceiveTime = receiveTime
        lastInputUptime = lastReceiveTime
        recorder?.append(frameBytes: data, captureTimeNs: lastReceiveTime)
        events.clear(); engine.process(frame, into: &events); injectEvents(); updateTimer()
        latency.record(nanoseconds: DispatchTime.now().uptimeNanoseconds &- receiveTime)
    }
    func resetLatency() { dispatchPrecondition(condition: .onQueue(queue)); latency.reset() }
    private var lastSequence: UInt32?
    func setGeometry(_ geometry: EngineGeometry) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard geometry != self.geometry else { return }
        self.geometry = geometry
        events.clear(); engine.setGeometry(geometry, into: &events); injectEvents(); updateTimer()
    }
    func setSettings(_ settings: TrackpadSettings) {
        dispatchPrecondition(condition: .onQueue(queue)); engine.setSettings(settings)
    }
    func displayDidSleep() { dispatchPrecondition(condition: .onQueue(queue)); injector.displayDidSleep() }

    func heartbeat() {
        dispatchPrecondition(condition: .onQueue(queue))
        lastInputUptime = DispatchTime.now().uptimeNanoseconds
        guard engine.hasActiveContacts else { return }
        events.clear(); engine.forceLiftoff(releaseDragLock: false, into: &events); injectEvents(); updateTimer()
    }
    func startRecording() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard recorder == nil else { return }
        do {
            recorder = try ReplayRecorder(geometry: geometry)
            logger.info("recording input session to \(self.recorder!.url.path, privacy: .private)")
        } catch {
            logger.error("cannot start input recording: \(error.localizedDescription, privacy: .public)")
        }
    }
    func stopRecording() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let recorder else { return }
        self.recorder = nil
        do {
            try recorder.finish()
            logger.info("saved input recording to \(recorder.url.path, privacy: .private)")
        } catch {
            logger.error("cannot save input recording: \(error.localizedDescription, privacy: .public)")
        }
    }
    func stop() {
        dispatchPrecondition(condition: .onQueue(queue)); timer?.cancel(); timer = nil
        events.clear(); engine.forceLiftoff(releaseDragLock: true, into: &events); injectEvents()
        stopRecording()
    }
    private func injectEvents() {
        for index in 0..<events.count {
            if case let .haptic(kind) = events[index] { onHaptic?(kind) }
            else { injector.inject(events[index]) }
        }
    }
    private func updateTimer() {
        if (engine.needsTick || injector.needsTick) && timer == nil {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(8))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source; source.resume()
        } else if !engine.needsTick && !injector.needsTick { timer?.cancel(); timer = nil }
    }
    private func tick() {
        dispatchPrecondition(condition: .onQueue(queue))
        injector.tick(); events.clear()
        let macNow = DispatchTime.now().uptimeNanoseconds
        let elapsed = DispatchTime.now().uptimeNanoseconds &- lastReceiveTime
        let estimatedPhoneTime = (lastFrameTime ?? 0) &+ elapsed
        onEstimatedTick?(estimatedPhoneTime)
        if engine.hasActiveContacts, macNow &- lastInputUptime >= 1_500_000_000 {
            engine.forceLiftoff(releaseDragLock: true, into: &events)
        } else {
            engine.tick(now: estimatedPhoneTime, into: &events)
        }
        injectEvents()
        updateTimer()
    }
}
