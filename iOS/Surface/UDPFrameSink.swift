import Foundation
import Network
import OSLog
import TrackglassKit

final class UDPFrameSink: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?
    private let logger = Logger(subsystem: "app.trackglass.ios", category: "Input")

    func setConnection(_ connection: NWConnection?) {
        lock.lock()
        let old = self.connection
        self.connection = connection
        lock.unlock()
        if old !== connection { old?.cancel() }
    }

    func consume(_ bytes: UnsafeRawBufferPointer) {
        guard let connection = currentConnection() else { return }
        // Network.framework takes ownership of a `Data`, so this copy (≤ 188 bytes) is the one allocation
        // at the transport boundary that §7 cannot avoid; everything upstream reuses fixed storage.
        // A no-copy pool would hand NW a buffer it may still be reading when the slot is reused.
        let content = Data(bytes)
        connection.send(content: content, completion: .idempotent)
    }

    func sendHeartbeat(sequence: UInt32) {
        guard let connection = currentConnection() else { return }
        var bytes = Data(count: MessageHeader.byteCount)
        do {
            try bytes.withUnsafeMutableBytes { buffer in
                _ = try MessageHeader(type: .inputHeartbeat, sequence: sequence,
                                      sentAt: MonotonicClock.nanoseconds()).encode(into: buffer)
            }
            connection.send(content: bytes, completion: .idempotent)
        } catch {
            logger.error("Input heartbeat encoding failed")
        }
    }

    private func currentConnection() -> NWConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connection
    }
}
