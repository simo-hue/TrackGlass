import Foundation
import TrackglassEngine

/// `<name>.settings.json`, written next to a Mac recording `<name>.tgrec` (§6.10) in the fixture settings format
/// `tgreplay` reads, so `tgreplay run <name>.tgrec --settings <name>.settings.json` replays the session with the
/// settings and surface it had. Changes carry `atNs`, the frame time of the last frame the pipeline had processed
/// when it handed the change to the engine; `tgreplay` applies them before the next frame, at the same point of the
/// frame sequence, and the engine's own deferral (§6.4) then behaves as it did live.
struct ReplaySidecar: Codable, Equatable {
    struct Acceleration: Codable, Equatable { var model: String }
    struct SettingsChange: Codable, Equatable { var atNs: UInt64; var settings: TrackpadSettings }
    struct GeometryChange: Codable, Equatable { var atNs: UInt64; var geometry: EngineGeometry }

    var settings: TrackpadSettings
    var geometry: EngineGeometry
    /// Gestures are decided in millimetres and the acceleration only scales what they emit, so a recording replays
    /// with the unit-gain model: the outcome is the same on any Mac (the live curves belong to the recording Mac).
    var acceleration = Acceleration(model: "unitGain")
    var settingsChanges: [SettingsChange] = []
    var geometryChanges: [GeometryChange] = []
    /// C1 (M6): the recording holds frames only; `tgreplay` adds what `InputPipeline` did between them (the 8 ms tick
    /// while the engine needs it, the 1.5 s lift-off timeout), so momentum, drag release and force click replay too.
    var emulatePipeline = true
    /// C1: true when the session ended while recording (`InputPipeline.stop()` forced a lift-off that releases a drag
    /// lock); `tgreplay` then does the same once its emulated timer has settled after the last frame. Absent (nil)
    /// when the user stopped the recording.
    var forceLiftoffReleaseDragLock: Bool? = nil

    init(settings: TrackpadSettings, geometry: EngineGeometry) {
        self.settings = settings; self.geometry = geometry
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
