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
                engine.isAutoShutdownEnabled = true
                engine.resetHandler = { [weak self] in Task { @MainActor in self?.restartIfActive() } }
                engine.stoppedHandler = { [weak self] reason in
                    Task { @MainActor in self?.engineStopped(reason) }
                }
                self.engine = engine
            }
            try engine?.start()
        } catch { logger.info("Haptic engine unavailable: \(error.localizedDescription, privacy: .public)") }
    }
    private func restartIfActive() { if active { start() } }

    /// Only genuine failures restart the engine. An idle shutdown is the auto-shutdown doing its job
    /// (`play` restarts the engine before each pattern), a suspended app cannot start one, and a
    /// destroyed engine must be recreated rather than restarted.
    private func engineStopped(_ reason: CHHapticEngine.StoppedReason) {
        switch reason {
        case .audioSessionInterrupt, .systemError: restartIfActive()
        case .engineDestroyed: engine = nil; restartIfActive()
        case .idleTimeout, .applicationSuspended, .notifyWhenFinished, .gameControllerDisconnect: break
        @unknown default: break
        }
    }
    func stop() {
        active = false; generation &+= 1
        engine?.stop(completionHandler: nil)
    }
    func play(_ message: HapticMessage) {
        guard active, enabled, message.intensity > 0 else { return }
        let pulses = Self.pulses(for: message.kind)
        guard !pulses.isEmpty else { return }
        let scale = strength * Float(message.intensity) / 255
        if let engine {
            do {
                try engine.start()
                let events = pulses.map { pulse in
                    CHHapticEvent(eventType: .hapticTransient, parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: pulse.intensity * scale),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: pulse.sharpness)
                    ], relativeTime: pulse.time)
                }
                let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
                try player.start(atTime: CHHapticTimeImmediate)
                return
            } catch { logger.info("Haptic playback fell back to impact feedback") }
        }
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
