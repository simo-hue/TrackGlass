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
        // Streamed to disk as frames arrive: a crash keeps what was recorded and memory stays flat (§7).
        writer = try TGRecFileWriter(header: try TGRecHeader(origin: .mac,
            surfaceWidthMM: geometry.widthMM, surfaceHeightMM: geometry.heightMM), url: url)
    }

    func append(frameBytes: Data, captureTimeNs: UInt64) {
        do { try writer.append(captureTimeNs: captureTimeNs, frameBytes: frameBytes) }
        catch { logger.error("cannot append replay frame: \(error.localizedDescription, privacy: .public)") }
    }

    func finish() throws { try writer.finish() }
}
