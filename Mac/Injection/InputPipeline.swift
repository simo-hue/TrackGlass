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
    /// One timer per pipeline (§2.4), resumed while the engine or injector needs ticks and suspended otherwise.
    private let timer: DispatchSourceTimer
    private var timerRunning = false
    var onRecordingChanged: ((Bool) -> Void)?
    private var lastFrameTime: UInt64?
    private var lastReceiveTime: UInt64 = 0
    private var lastInputUptime: UInt64 = 0
    /// Uptime when the pipeline was created, i.e. when the phone was admitted (dead-input-path detection).
    private let createdUptime: UInt64
    /// The phone sends a frame or a heartbeat at least every 0.5 s (§4.5), so this much silence means the
    /// datagram path is gone even though the control channel still answers PINGs.
    static let inputPathSilenceNs: UInt64 = 3_000_000_000
    /// Before the first datagram the phone is still resolving `_trackglass._udp` and running the DTLS handshake;
    /// its own watchdog gives up after 5 s (`SessionClient.inputPathTimeout`), so the Mac waits a little longer.
    static let firstDatagramGraceNs: UInt64 = 6_000_000_000
    var diagnosticEngineState: UInt8 { engine.diagnosticState }
    var onHaptic: ((HapticKind) -> Void)?
    var onEstimatedTick: ((UInt64) -> Void)?
    private(set) var outOfOrderFrames = 0
    private(set) var backwardsTimeFrames = 0
    /// Receive → post durations of accepted frames (SPEC §6.10), read by the status timer.
    private(set) var latency = LatencyStats()
    /// The settings the Mac asked for last; the engine applies them when no gesture is in progress (§6.4).
    private var requestedSettings: TrackpadSettings
    /// The engine's applied-settings generation the injector last learned (F11): the injector follows the engine's
    /// snapshot, so a change made mid-gesture reaches the injector only when the engine applies it.
    private var injectorSettingsGeneration: Int
    /// Where `startRecording` writes (tests); nil is the user's Application Support/Trackglass/Recordings.
    var recordingsDirectory: URL?

    /// UserDefaults key: `defaults write <bundle id> TGUseAppleScrollCurves -bool YES` scrolls with Apple's
    /// parametric scroll curves instead of the shipped fallback (2026-10-29, F2). The parametric path's units and
    /// report-rate scaling are not verified against a real trackpad yet (G-SCR / tgaccel data from the owner's
    /// Mac): it measured 3–23 × the trackpad's scroll distance and depended on the frame rate, so it is opt-in.
    static let appleScrollCurvesKey = "TGUseAppleScrollCurves"

    static func makeScrollAcceleration(settings: TrackpadSettings, defaults: UserDefaults = .standard) -> any AccelerationModel {
        guard defaults.bool(forKey: appleScrollCurvesKey) else { return ScrollFallbackAcceleration() }
        return PointerAccelerationProvider.makeScroll(settings: settings)
    }

    init(queue: DispatchQueue, geometry: EngineGeometry, settings: TrackpadSettings = TrackpadSettings(),
         injector: InputInjector = QuartzInjector(), acceleration: (any AccelerationModel)? = nil,
         createdUptime: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.queue = queue; self.geometry = geometry; self.createdUptime = createdUptime
        let accelerationModel = acceleration ?? PointerAccelerationProvider.make(settings: settings)
        let engine = GestureEngine(settings: settings, geometry: geometry, acceleration: accelerationModel,
            scrollAcceleration: InputPipeline.makeScrollAcceleration(settings: settings))
        self.engine = engine
        self.injector = injector
        requestedSettings = settings
        injectorSettingsGeneration = engine.settingsGeneration
        // Before confinement is armed: the pipeline may be created off its queue (tests); nothing runs on it yet.
        injector.settingsDidChange(engine.appliedSettings)
        (injector as? QuartzInjector)?.confinementQueue = queue
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))
        timer.setEventHandler { [weak self] in self?.tick() }
        // Created suspended; `updateTimer` resumes it. A suspended source must be resumed before release.
    }

    deinit {
        if !timerRunning { timer.resume() }
        timer.cancel()
    }
    func consume(_ data: Data) {
        dispatchPrecondition(condition: .onQueue(queue))
        let receiveTime = DispatchTime.now().uptimeNanoseconds
        guard let frame = try? data.withUnsafeBytes({ try TouchFrameDecoder.decode($0) }) else { return }
        if let lastSequence, !MessageHeader.sequence(frame.header.sequence, isNewerThan: lastSequence) { outOfOrderFrames += 1; return }
        if let lastFrameTime {
            if frame.frameTime < lastFrameTime { backwardsTimeFrames += 1; return }
        }
        lastSequence = frame.header.sequence
        lastFrameTime = frame.frameTime
        lastReceiveTime = receiveTime
        lastInputUptime = lastReceiveTime
        events.clear(); engine.process(frame, into: &events); injectEvents(); syncInjectorSettings(); updateTimer()
        latency.record(nanoseconds: DispatchTime.now().uptimeNanoseconds &- receiveTime)
        // After the events are posted (P9): the disk write is not part of the receive → post latency.
        if let recorder, !recorder.append(frameBytes: data, captureTimeNs: receiveTime) { stopRecording() }
    }
    func resetLatency() { dispatchPrecondition(condition: .onQueue(queue)); latency.reset() }
    private var lastSequence: UInt32?
    private var prematureHeartbeatSequence: UInt32?
    func setGeometry(_ geometry: EngineGeometry) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard geometry != self.geometry else { return }
        self.geometry = geometry
        recorder?.recordGeometry(geometry, atNs: lastFrameTime ?? 0)
        events.clear(); engine.setGeometry(geometry, into: &events); injectEvents(); syncInjectorSettings(); updateTimer()
    }
    func setSettings(_ settings: TrackpadSettings) {
        dispatchPrecondition(condition: .onQueue(queue))
        // Every SURFACE re-sends the settings; only a real change is a recording event.
        if settings != requestedSettings { recorder?.recordSettings(settings, atNs: lastFrameTime ?? 0) }
        requestedSettings = settings
        engine.setSettings(settings); syncInjectorSettings()
    }
    /// The injector learns the settings the engine applies, when it applies them (§6.4 deferral, F11).
    private func syncInjectorSettings() {
        guard engine.settingsGeneration != injectorSettingsGeneration else { return }
        injectorSettingsGeneration = engine.settingsGeneration
        injector.settingsDidChange(engine.appliedSettings)
    }
    func displayDidSleep() { dispatchPrecondition(condition: .onQueue(queue)); injector.displayDidSleep() }

    /// §4.7: a heartbeat says "no finger is down as of the frame with this `sequence`". One older than the last
    /// accepted frame was overtaken by a newer touch and is ignored. One naming a frame not received yet means
    /// frames are still in flight: it is ignored once, and acted on when the next heartbeat (0.5 s later) still
    /// names that frame — then the frames were lost and the lift-off must not wait for the 1.5 s timeout.
    func heartbeat(sequence: UInt32) {
        dispatchPrecondition(condition: .onQueue(queue))
        lastInputUptime = DispatchTime.now().uptimeNanoseconds
        if let lastSequence, sequence != lastSequence {
            guard MessageHeader.sequence(sequence, isNewerThan: lastSequence) else { return }
            guard prematureHeartbeatSequence == sequence else { prematureHeartbeatSequence = sequence; return }
        }
        prematureHeartbeatSequence = nil
        guard engine.hasActiveContacts else { return }
        events.clear(); engine.forceLiftoff(releaseDragLock: false, into: &events); injectEvents(); syncInjectorSettings(); updateTimer()
        // C1 (M6): the recording gets the frame the engine just processed, so its replay lifts off here too.
        if let recorder, let lastFrameTime,
           !recorder.appendSyntheticLiftoff(frameTime: lastFrameTime, sequence: lastSequence ?? 0, captureTimeNs: lastInputUptime) {
            stopRecording()
        }
    }
    func startRecording() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard recorder == nil else { return }
        do {
            let recorder = try ReplayRecorder(geometry: geometry, settings: engine.appliedSettings, directory: recordingsDirectory)
            // A change still waiting for the end of the current gesture is replayed from the first frame on.
            if requestedSettings != engine.appliedSettings { recorder.recordSettings(requestedSettings, atNs: 0) }
            self.recorder = recorder
            logger.info("recording input session to \(self.recorder!.url.path, privacy: .private)")
            onRecordingChanged?(true)
        } catch {
            logger.error("cannot start input recording: \(error.localizedDescription, privacy: .public)")
        }
    }
    func stopRecording() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let recorder else { return }
        self.recorder = nil
        onRecordingChanged?(false)
        do {
            try recorder.finish()
            logger.info("saved input recording to \(recorder.url.path, privacy: .private)")
        } catch {
            logger.error("cannot save input recording: \(error.localizedDescription, privacy: .public)")
        }
    }
    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        if timerRunning { timer.suspend(); timerRunning = false }
        events.clear(); engine.forceLiftoff(releaseDragLock: true, into: &events); injectEvents(); syncInjectorSettings()
        // The timer will not run again: whatever the injector still had scheduled is posted now (§6.9.4).
        injector.flush()
        // C1 (M6): the replay ends with the same drag-lock-releasing lift-off (written with the sidecar by `finish`).
        recorder?.recordSessionEnd()
        stopRecording()
    }

    /// True when the admitted phone's datagrams stopped (or never started) while its control channel may still be
    /// alive: the session is then ended so the phone rebuilds both channels instead of showing "Connected" with a
    /// trackpad that does nothing (§8).
    func inputPathIsDead(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        if lastInputUptime == 0 { return now >= createdUptime && now - createdUptime >= Self.firstDatagramGraceNs }
        return now >= lastInputUptime && now - lastInputUptime >= Self.inputPathSilenceNs
    }

    /// §6.3: three seconds without any datagram (frame or heartbeat) while connected means the engine
    /// is reset and STATUS reports idle; the 1.5 s lift-off timeout in `tick` covers tracked contacts,
    /// this covers everything else (momentum, grace windows, pending taps, a deliberate drag lock).
    func idleCheck(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard lastInputUptime != 0, now &- lastInputUptime >= 3_000_000_000,
              engine.needsTick || engine.hasActiveContacts || engine.diagnosticState != 0 else { return }
        events.clear(); engine.forceLiftoff(releaseDragLock: true, into: &events); injectEvents(); syncInjectorSettings(); updateTimer()
    }
    private func injectEvents() {
        for index in 0..<events.count {
            if case let .haptic(kind) = events[index] { onHaptic?(kind) }
            else { injector.inject(events[index]) }
        }
    }
    private func updateTimer() {
        let needed = engine.needsTick || injector.needsTick
        if needed && !timerRunning {
            timer.schedule(deadline: .now(), repeating: .milliseconds(8))
            timer.resume(); timerRunning = true
        } else if !needed && timerRunning {
            timer.suspend(); timerRunning = false
        }
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
        syncInjectorSettings()
        updateTimer()
    }
}
