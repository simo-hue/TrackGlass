import CoreHaptics
import OSLog
import TrackglassKit
import UIKit

@MainActor
final class HapticEngine {
    struct Pulse: Equatable { let time: Double; let intensity: Float; let sharpness: Float }
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "app.trackglass.ios", category: "haptics")
    private var engine: CHHapticEngine?
    private var active = false
    private var generation = 0
    private var engineRunning = false
    private var engineStarting = false
    /// The haptic that arrived while the engine was starting (only the latest one is worth playing).
    private var pending: (kind: UInt8, pulses: [Pulse], scale: Float)?
    private var players: [Int: CHHapticPatternPlayer] = [:]
    private let fallback = UIImpactFeedbackGenerator(style: .rigid)
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// HELLO capability bit 0 (§4.5).
    nonisolated static var supportsHaptics: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

    var enabled: Bool {
        get { defaults.object(forKey: "hapticsEnabled") == nil || defaults.bool(forKey: "hapticsEnabled") }
        set { defaults.set(newValue, forKey: "hapticsEnabled") }
    }
    var strength: Float {
        get {
            let value = defaults.object(forKey: "hapticsStrength") == nil ? 1 : defaults.float(forKey: "hapticsStrength")
            return value.isFinite ? min(1, max(0.5, value)) : 1
        }
        set { defaults.set(newValue.isFinite ? min(1, max(0.5, newValue)) : 1, forKey: "hapticsStrength") }
    }
    nonisolated static func pulses(for kind: UInt8) -> [Pulse] {
        switch kind {
        case 1: return [.init(time: 0, intensity: 0.85, sharpness: 0.9)]
        case 2: return [.init(time: 0, intensity: 0.7, sharpness: 0.6)]
        case 3: return [.init(time: 0, intensity: 0.6, sharpness: 0.9), .init(time: 0.06, intensity: 1, sharpness: 1)]
        case 4: return [.init(time: 0, intensity: 0.5, sharpness: 0.3)]
        case 5: return [.init(time: 0, intensity: 0.35, sharpness: 0.3)]
        case 6: return [.init(time: 0, intensity: 0.4, sharpness: 0.8)]
        default: return []
        }
    }
    func start() {
        active = true
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { fallback.prepare(); return }
        do {
            if engine == nil {
                let engine = try CHHapticEngine()
                engine.playsHapticsOnly = true   // no audio session work: faster start, no audio interruptions
                engine.isAutoShutdownEnabled = true
                engine.resetHandler = { @Sendable [weak self] in Task { @MainActor in self?.engineReset() } }
                engine.stoppedHandler = { @Sendable [weak self] reason in
                    Task { @MainActor in self?.engineStopped(reason) }
                }
                self.engine = engine
                players.removeAll(); engineRunning = false; engineStarting = false
            }
            startEngine()
        } catch { logger.info("Haptic engine unavailable: \(error.localizedDescription, privacy: .public)") }
    }

    /// The first finger down starts an auto-shut-down engine early, so the Mac's first haptic plays on time.
    func prewarm() {
        guard active, enabled else { return }
        startEngine()
    }

    private func restartIfActive() { if active { start() } }

    private func engineReset() {
        // A reset (haptic server restart) invalidates every player made by the engine.
        engineRunning = false; engineStarting = false; players.removeAll()
        restartIfActive()
    }

    /// Only genuine failures restart the engine. An idle shutdown is the auto-shutdown doing its job
    /// (`play` and `prewarm` start the engine again), a suspended app cannot start one, and a
    /// destroyed engine must be recreated rather than restarted.
    private func engineStopped(_ reason: CHHapticEngine.StoppedReason) {
        engineRunning = false
        switch reason {
        case .audioSessionInterrupt, .systemError: restartIfActive()
        case .engineDestroyed: engine = nil; engineStarting = false; players.removeAll(); restartIfActive()
        case .idleTimeout, .applicationSuspended, .notifyWhenFinished, .gameControllerDisconnect: break
        @unknown default: break
        }
    }

    /// Starts the engine without blocking the main thread; a haptic that arrives meanwhile plays once it runs.
    private func startEngine() {
        guard let engine, !engineRunning, !engineStarting else { return }
        engineStarting = true
        let generation = self.generation
        let id = ObjectIdentifier(engine)
        engine.start(completionHandler: { @Sendable [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                guard let current = self.engine, ObjectIdentifier(current) == id, self.generation == generation else { return }
                self.engineStarting = false
                let pending = self.pending
                self.pending = nil
                if let error {
                    self.logger.info("Haptic engine did not start: \(error.localizedDescription, privacy: .public)")
                    if let pending { self.playFallback(pending.pulses, scale: pending.scale) }
                    return
                }
                self.engineRunning = true
                if let pending, !self.playPattern(kind: pending.kind, pulses: pending.pulses, scale: pending.scale) {
                    self.playFallback(pending.pulses, scale: pending.scale)
                }
            }
        })
    }

    func stop() {
        active = false; generation &+= 1
        engineRunning = false; engineStarting = false; pending = nil
        engine?.stop(completionHandler: nil)
    }

    func play(_ message: HapticMessage) {
        guard active, enabled, message.intensity > 0 else { return }
        let pulses = Self.pulses(for: message.kind)
        guard !pulses.isEmpty else { return }
        let scale = Self.quantizedScale(strength * Float(message.intensity) / 255)
        if engine != nil {
            if engineRunning {
                if playPattern(kind: message.kind, pulses: pulses, scale: scale) { return }
                engineRunning = false   // stopped under us (an idle shutdown not reported yet): start it again
            }
            // Auto-shutdown stopped the engine: start it asynchronously and play this haptic when it runs.
            pending = (message.kind, pulses, scale)
            startEngine()
            if engineStarting { return }
        }
        playFallback(pulses, scale: scale)
    }

    /// Players are cached per gesture kind and intensity step (20 steps: indistinguishable to the hand), so a
    /// haptic does not rebuild its pattern every time.
    nonisolated static func quantizedScale(_ scale: Float) -> Float {
        guard scale.isFinite else { return 1 }
        return (min(1, max(0, scale)) * 20).rounded() / 20
    }

    private func playPattern(kind: UInt8, pulses: [Pulse], scale: Float) -> Bool {
        guard let engine else { return false }
        let key = Int(kind) << 8 | Int((scale * 20).rounded())
        do {
            let player: CHHapticPatternPlayer
            if let cached = players[key] {
                player = cached
            } else {
                let events = pulses.map { pulse in
                    CHHapticEvent(eventType: .hapticTransient, parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: pulse.intensity * scale),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: pulse.sharpness)
                    ], relativeTime: pulse.time)
                }
                player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
                players[key] = player
            }
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            players[key] = nil
            logger.info("Haptic playback fell back to impact feedback")
            return false
        }
    }

    private func playFallback(_ pulses: [Pulse], scale: Float) {
        let currentGeneration = generation
        for pulse in pulses {
            if pulse.time == 0 { fallback.impactOccurred(intensity: CGFloat(pulse.intensity * scale)) }
            else {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(pulse.time))
                    guard let self, self.active, self.enabled, self.generation == currentGeneration else { return }
                    self.fallback.impactOccurred(intensity: CGFloat(pulse.intensity * scale))
                }
            }
        }
    }
}
