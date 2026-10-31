import Foundation
import OSLog
import TrackglassEngine
import TrackglassKit

final class ReplayRecorder {
    let url: URL
    /// `<name>.settings.json` next to `<name>.tgrec` (§6.10): settings, surface and their changes for `tgreplay`.
    let settingsURL: URL
    private let writer: TGRecFileWriter
    private var sidecar: ReplaySidecar
    private let logger = Logger(subsystem: "app.trackglass.mac", category: "engine")

    /// `directory` nil: the user's Application Support/Trackglass/Recordings.
    init(geometry: EngineGeometry, settings: TrackpadSettings, directory: URL? = nil) throws {
        let folder: URL
        if let directory {
            folder = directory
        } else {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
            folder = support.appendingPathComponent("Trackglass/Recordings", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let name = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        url = folder.appendingPathComponent(name + ".tgrec")
        settingsURL = folder.appendingPathComponent(name + ".settings.json")
        sidecar = ReplaySidecar(settings: settings, geometry: geometry)
        // Streamed to disk as frames arrive: a crash loses at most the last quarter second and memory stays flat (§7).
        writer = try TGRecFileWriter(header: try TGRecHeader(origin: .mac,
            surfaceWidthMM: geometry.widthMM, surfaceHeightMM: geometry.heightMM), url: url)
        // Written now and after every change (they are rare), so a crash keeps a replayable pair.
        try writeSidecar()
    }

    /// False when the frame could not be written (disk full, volume gone); the writer has closed itself and the
    /// pipeline stops the recording, so the failure is logged once instead of on every frame (§7).
    func append(frameBytes: Data, captureTimeNs: UInt64) -> Bool {
        frameBytes.withUnsafeBytes { append(frameBytes: $0, captureTimeNs: captureTimeNs) }
    }

    func append(frameBytes: UnsafeRawBufferPointer, captureTimeNs: UInt64) -> Bool {
        do {
            try writer.append(captureTimeNs: captureTimeNs, frameBytes: frameBytes)
            return true
        } catch TGRecError.invalidFrameLength {
            return true   // a frame the recording format cannot hold is skipped, the recording goes on
        } catch {
            logger.error("recording stopped: cannot write replay frame: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// C1 (M6): a lift-off `InputPipeline.heartbeat()` forced is recorded as the TOUCH_FRAME the engine processed for
    /// it (no contacts, synthetic lift-off flag, the last frame's time), so the replay lifts off where the Mac did.
    /// Rare (a lost lift-off datagram); encoded on the stack. False when the write failed, as for `append`.
    func appendSyntheticLiftoff(frameTime: UInt64, sequence: UInt32, captureTimeNs: UInt64) -> Bool {
        let encoder = TouchFrameEncoder(frame: TouchFrame(sequence: sequence, frameTime: frameTime, isSyntheticLiftoff: true))
        return withUnsafeTemporaryAllocation(byteCount: 28, alignment: 8) { buffer in
            guard let written = try? encoder.encode(into: buffer) else { return true }
            return append(frameBytes: UnsafeRawBufferPointer(start: buffer.baseAddress, count: written), captureTimeNs: captureTimeNs)
        }
    }

    /// C1: the session ended while recording; the pipeline forced a lift-off that releases a drag lock.
    func recordSessionEnd() { sidecar.forceLiftoffReleaseDragLock = true }

    /// `atNs`: the frame time of the last frame processed before the pipeline handed the change to the engine.
    func recordSettings(_ settings: TrackpadSettings, atNs: UInt64) {
        sidecar.settingsChanges.append(.init(atNs: atNs, settings: settings)); saveSidecar()
    }

    func recordGeometry(_ geometry: EngineGeometry, atNs: UInt64) {
        sidecar.geometryChanges.append(.init(atNs: atNs, geometry: geometry)); saveSidecar()
    }

    func finish() throws {
        try writer.finish()
        try writeSidecar()
    }

    private func saveSidecar() {
        do { try writeSidecar() } catch {
            logger.error("cannot write recording settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeSidecar() throws { try sidecar.encoded().write(to: settingsURL, options: .atomic) }
}
