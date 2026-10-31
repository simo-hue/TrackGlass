import Foundation

public enum TGRecError: Error, Equatable, Sendable {
    case badMagic
    case unsupportedVersion(UInt8)
    case invalidOrigin(UInt8)
    case invalidGeometry
    case truncated
    case invalidFrameLength
    /// The file writer stopped after a failed write (disk full, volume gone) or was already finished.
    case writerClosed
}

public struct TGRecHeader: Equatable, Sendable {
    public enum Origin: UInt8, Sendable { case phone = 1, mac = 2 }
    public let origin: Origin
    public let surfaceWidthHundredthsMM: UInt32
    public let surfaceHeightHundredthsMM: UInt32
    public var surfaceWidthMM: Double { Double(surfaceWidthHundredthsMM) / 100 }
    public var surfaceHeightMM: Double { Double(surfaceHeightHundredthsMM) / 100 }

    public init(origin: Origin, surfaceWidthMM: Double, surfaceHeightMM: Double) throws {
        let width = (surfaceWidthMM * 100).rounded()
        let height = (surfaceHeightMM * 100).rounded()
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= Double(UInt32.max), height <= Double(UInt32.max) else { throw TGRecError.invalidGeometry }
        self.origin = origin
        surfaceWidthHundredthsMM = UInt32(width)
        surfaceHeightHundredthsMM = UInt32(height)
    }

    fileprivate init(origin: Origin, width: UInt32, height: UInt32) throws {
        guard width > 0, height > 0 else { throw TGRecError.invalidGeometry }
        self.origin = origin
        surfaceWidthHundredthsMM = width
        surfaceHeightHundredthsMM = height
    }
}

public struct TGRecRecord: Equatable, Sendable {
    /// One TOUCH_FRAME per record: at least its 28-byte fixed part, at most what the `u16 length` holds, so a frame
    /// a newer phone extends with appended bytes (§4.1) is still recorded and replayed (§6.10, 2026-10-31).
    public static let frameByteCountRange = 28...Int(UInt16.max)
    public let captureTimeNs: UInt64
    public let frameBytes: Data
}

public struct TGRecWriter {
    public private(set) var data: Data

    public init(header: TGRecHeader) {
        data = Data([0x54, 0x47, 0x52, 0x45, 0x43, 1, header.origin.rawValue])
        appendInteger(header.surfaceWidthHundredthsMM)
        appendInteger(header.surfaceHeightHundredthsMM)
    }

    public mutating func append(captureTimeNs: UInt64, frameBytes: Data) throws {
        guard TGRecRecord.frameByteCountRange.contains(frameBytes.count) else { throw TGRecError.invalidFrameLength }
        _ = try frameBytes.withUnsafeBytes { try TouchFrameDecoder.decode($0) }
        appendInteger(captureTimeNs)
        appendInteger(UInt16(frameBytes.count))
        data.append(frameBytes)
    }

    public func write(to url: URL) throws { try data.write(to: url, options: .atomic) }

    private mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

public struct TGRecReader {
    public let header: TGRecHeader
    private let data: Data
    private var offset = 15

    public init(data: Data) throws {
        guard data.count >= 15 else { throw TGRecError.truncated }
        header = try data.withUnsafeBytes { bytes in
            guard bytes[0] == 0x54, bytes[1] == 0x47, bytes[2] == 0x52,
                  bytes[3] == 0x45, bytes[4] == 0x43 else { throw TGRecError.badMagic }
            guard bytes[5] == 1 else { throw TGRecError.unsupportedVersion(bytes[5]) }
            guard let origin = TGRecHeader.Origin(rawValue: bytes[6]) else { throw TGRecError.invalidOrigin(bytes[6]) }
            return try TGRecHeader(origin: origin,
                width: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 7, as: UInt32.self)),
                height: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 11, as: UInt32.self)))
        }
        self.data = data
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public mutating func next() throws -> TGRecRecord? {
        if offset == data.count { return nil }
        guard data.count - offset >= 10 else { throw TGRecError.truncated }
        let record = try data.withUnsafeBytes { bytes -> TGRecRecord in
            let timestamp = UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
            let length = Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 8, as: UInt16.self)))
            guard TGRecRecord.frameByteCountRange.contains(length) else { throw TGRecError.invalidFrameLength }
            guard data.count - offset - 10 >= length else { throw TGRecError.truncated }
            let payload = UnsafeRawBufferPointer(rebasing: bytes[(offset + 10)..<(offset + 10 + length)])
            _ = try TouchFrameDecoder.decode(payload)
            return TGRecRecord(captureTimeNs: timestamp, frameBytes: Data(payload))
        }
        offset += 10 + record.frameBytes.count
        return record
    }
}

/// Streams a recording to disk as frames arrive (SPEC §6.10): the header is written when the file is
/// opened and every record is appended through a bounded buffer, so a long session never grows memory.
/// The buffer is written out at every lift-off and at least every 250 ms of capture time, so a process that
/// dies before `finish()` loses at most the last quarter second. One owner, one queue; not thread-safe.
public final class TGRecFileWriter {
    public let url: URL
    public private(set) var recordCount = 0
    private let handle: FileHandle
    private var buffer = Data()
    private var closed = false
    private var failed = false
    private var lastFlushTimeNs: UInt64?
    private static let flushThreshold = 64 * 1_024
    private static let flushIntervalNs: UInt64 = 250_000_000

    public init(header: TGRecHeader, url: URL) throws {
        self.url = url
        let writer = TGRecWriter(header: header)
        try writer.data.write(to: url, options: .atomic)
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        // Room for the largest record on top of a not-yet-flushed buffer, so appending never reallocates (§7).
        buffer.reserveCapacity(Self.flushThreshold + 10 + TGRecRecord.frameByteCountRange.upperBound)
    }

    deinit {
        // Dropped without `finish()` (owner torn down): keep what is still buffered.
        guard !closed else { return }
        try? flush()
        try? handle.close()
    }

    /// Appends one validated TOUCH_FRAME without copying it into a `Data` first. After a failed write the
    /// writer is closed for good and every later call throws `writerClosed` without touching the disk.
    public func append(captureTimeNs: UInt64, frameBytes: UnsafeRawBufferPointer) throws {
        guard !closed else { throw TGRecError.writerClosed }
        guard TGRecRecord.frameByteCountRange.contains(frameBytes.count) else { throw TGRecError.invalidFrameLength }
        _ = try TouchFrameDecoder.decode(frameBytes)
        var timestamp = captureTimeNs.littleEndian
        var length = UInt16(frameBytes.count).littleEndian
        withUnsafeBytes(of: &timestamp) { buffer.append(contentsOf: $0) }
        withUnsafeBytes(of: &length) { buffer.append(contentsOf: $0) }
        buffer.append(contentsOf: frameBytes)
        recordCount += 1
        let liftoff = frameBytes[24] == 0   // contactCount 0: the gesture is over, a natural moment to write
        let lastFlush = lastFlushTimeNs ?? captureTimeNs
        if lastFlushTimeNs == nil { lastFlushTimeNs = captureTimeNs }
        if buffer.count >= Self.flushThreshold || liftoff || captureTimeNs &- lastFlush >= Self.flushIntervalNs {
            lastFlushTimeNs = captureTimeNs
            try flush()
        }
    }

    public func append(captureTimeNs: UInt64, frameBytes: Data) throws {
        try frameBytes.withUnsafeBytes { try append(captureTimeNs: captureTimeNs, frameBytes: $0) }
    }

    /// Flushes, syncs and closes the file. Idempotent; throws `writerClosed` if an earlier write failed.
    public func finish() throws {
        guard !closed else {
            if failed { throw TGRecError.writerClosed }
            return
        }
        try flush()
        try handle.synchronize()
        try handle.close()
        closed = true
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        do {
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        } catch {
            // Disk full or volume gone: stop instead of retrying an ever larger buffer on every frame (a partial
            // write retried would also duplicate bytes and corrupt the file).
            buffer.removeAll(keepingCapacity: true)
            closed = true; failed = true
            try? handle.close()
            throw error
        }
    }
}
