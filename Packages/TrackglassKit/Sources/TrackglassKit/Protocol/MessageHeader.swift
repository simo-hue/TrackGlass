public enum ProtocolError: Error, Equatable, Sendable {
    case truncated
    case bufferTooSmall
    case badMagic
    case incompatibleVersion(UInt8)
}

public struct MessageHeader: Equatable, Sendable {
    public static let byteCount = 16
    public static let protocolVersion: UInt8 = 1

    // Keep the raw value so a future message type can be ignored by its receiver.
    public var type: UInt8
    public var sequence: UInt32
    public var sentAt: UInt64

    public init(type: UInt8, sequence: UInt32, sentAt: UInt64) {
        self.type = type
        self.sequence = sequence
        self.sentAt = sentAt
    }

    public init(type: MessageType, sequence: UInt32, sentAt: UInt64) {
        self.init(type: type.rawValue, sequence: sequence, sentAt: sentAt)
    }

    @discardableResult
    public func encode(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard buffer.count >= Self.byteCount else { throw ProtocolError.bufferTooSmall }
        buffer[0] = 0x54
        buffer[1] = 0x47
        buffer[2] = Self.protocolVersion
        buffer[3] = type
        buffer.storeBytes(of: sequence.littleEndian, toByteOffset: 4, as: UInt32.self)
        buffer.storeBytes(of: sentAt.littleEndian, toByteOffset: 8, as: UInt64.self)
        return Self.byteCount
    }

    public static func decode(_ buffer: UnsafeRawBufferPointer) throws -> Self {
        guard buffer.count >= byteCount else { throw ProtocolError.truncated }
        guard buffer[0] == 0x54, buffer[1] == 0x47 else { throw ProtocolError.badMagic }
        guard buffer[2] == protocolVersion else { throw ProtocolError.incompatibleVersion(buffer[2]) }
        return Self(
            type: buffer[3],
            sequence: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: 4, as: UInt32.self)),
            sentAt: UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        )
    }
}
