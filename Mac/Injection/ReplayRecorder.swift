import Foundation
import OSLog
import TrackglassEngine
import TrackglassKit

final class ReplayRecorder {
    let url: URL
    private let writer: TGRecFileWriter
    private let logger = Logger(subsystem: "app.trackglass.mac", category: "engine")

    init(geometry: EngineGeometry) throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("Trackglass/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let filename = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".tgrec"
        url = directory.appendingPathComponent(filename)
        // Streamed to disk as frames arrive: a crash loses at most the last quarter second and memory stays flat (§7).
        writer = try TGRecFileWriter(header: try TGRecHeader(origin: .mac,
            surfaceWidthMM: geometry.widthMM, surfaceHeightMM: geometry.heightMM), url: url)
    }

    /// False when the frame could not be written (disk full, volume gone); the writer has closed itself and the
    /// pipeline stops the recording, so the failure is logged once instead of on every frame (§7).
    func append(frameBytes: Data, captureTimeNs: UInt64) -> Bool {
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

    func finish() throws { try writer.finish() }
}
