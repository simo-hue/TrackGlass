import Foundation
import OSLog
import TrackglassKit

protocol FrameSink: AnyObject, Sendable {
    /// Bytes are borrowed until this call returns; sinks must not retain them.
    func consume(_ bytes: UnsafeRawBufferPointer)
}

final class ConsoleFrameSink: FrameSink {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.trackglass.ios", category: "TouchFrames")

    func consume(_ bytes: UnsafeRawBufferPointer) {
        guard let frame = try? TouchFrameDecoder.decode(bytes) else { return }
        // Log borrowed bytes directly instead of constructing per-contact strings.
        // The first two decoded contacts support the M2.2 ruler/lift-off check.
        let first = frame.contactCount > 0 ? frame[0] : Contact()
        let second = frame.contactCount > 1 ? frame[1] : Contact()
        let dx = first.x - second.x
        let dy = first.y - second.y
        let distance = frame.contactCount == 2 ? (dx * dx + dy * dy).squareRoot() : 0
        logger.debug("frame time=\(frame.frameTime) count=\(frame.contactCount) synthetic=\(frame.isSyntheticLiftoff) id0=\(first.contactID) phase0=\(first.phase.rawValue) id1=\(second.contactID) phase1=\(second.phase.rawValue) distanceMM=\(distance, privacy: .private) payload=\(bytes, privacy: .private)")
    }
}
