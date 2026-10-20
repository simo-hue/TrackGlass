import Foundation

public enum TGRecError: Error, Equatable, Sendable {
    case badMagic
    case unsupportedVersion(UInt8)
    case invalidOrigin(UInt8)
    case invalidGeometry
    case truncated
    case invalidFrameLength
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
        guard (28...TouchFrame.maximumByteCount).contains(frameBytes.count) else { throw TGRecError.invalidFrameLength }
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
            guard (28...TouchFrame.maximumByteCount).contains(length) else { throw TGRecError.invalidFrameLength }
            guard data.count - offset - 10 >= length else { throw TGRecError.truncated }
            let payload = UnsafeRawBufferPointer(rebasing: bytes[(offset + 10)..<(offset + 10 + length)])
            _ = try TouchFrameDecoder.decode(payload)
            return TGRecRecord(captureTimeNs: timestamp, frameBytes: Data(payload))
        }
        offset += 10 + record.frameBytes.count
        return record
    }
}
