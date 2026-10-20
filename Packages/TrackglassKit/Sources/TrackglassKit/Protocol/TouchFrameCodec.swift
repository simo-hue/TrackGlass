public enum TouchFrameCodecError: Error, Equatable, Sendable {
    case wrongMessageType
    case invalidContactCount
    case invalidLength
    case reservedBits
    case invalidContact
}

public struct TouchFrameEncoder {
    public var frame: TouchFrame

    public init(frame: TouchFrame) { self.frame = frame }

    @discardableResult
    public func encode(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let size = 28 + 16 * frame.contactCount
        guard buffer.count >= size else { throw ProtocolError.bufferTooSmall }
        guard frame.header.type == MessageType.touchFrame.rawValue else { throw TouchFrameCodecError.wrongMessageType }
        try frame.header.encode(into: buffer)
        buffer.storeBytes(of: frame.frameTime.littleEndian, toByteOffset: 16, as: UInt64.self)
        buffer[24] = UInt8(frame.contactCount)
        buffer[25] = (frame.surfaceIsLandscape ? 1 : 0) | (frame.isSyntheticLiftoff ? 2 : 0)
        buffer[26] = 0
        buffer[27] = 0
        for index in 0..<frame.contactCount {
            let contact = frame[index]
            let offset = 28 + index * 16
            buffer[offset] = contact.contactID
            buffer[offset + 1] = contact.phase.rawValue
            buffer[offset + 2] = contact.kind.rawValue
            buffer[offset + 3] = 0
            buffer.storeBytes(of: contact.x.bitPattern.littleEndian, toByteOffset: offset + 4, as: UInt32.self)
            buffer.storeBytes(of: contact.y.bitPattern.littleEndian, toByteOffset: offset + 8, as: UInt32.self)
            buffer.storeBytes(of: contact.majorRadius.bitPattern.littleEndian, toByteOffset: offset + 12, as: UInt32.self)
        }
        return size
    }
}

public enum TouchFrameDecoder {
    public static func decode(_ buffer: UnsafeRawBufferPointer) throws -> TouchFrame {
        let header = try MessageHeader.decode(buffer)
        guard header.type == MessageType.touchFrame.rawValue else { throw TouchFrameCodecError.wrongMessageType }
        guard buffer.count >= 28 else { throw ProtocolError.truncated }
        let count = Int(buffer[24])
        guard count <= TouchFrame.maximumContacts else { throw TouchFrameCodecError.invalidContactCount }
        guard buffer.count == 28 + count * 16 else { throw TouchFrameCodecError.invalidLength }
        guard buffer[25] & 0xFC == 0, buffer[26] == 0, buffer[27] == 0 else { throw TouchFrameCodecError.reservedBits }
        var frame = TouchFrame(
            sequence: header.sequence, sentAt: header.sentAt,
            frameTime: UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: 16, as: UInt64.self)),
            surfaceIsLandscape: buffer[25] & 1 != 0, isSyntheticLiftoff: buffer[25] & 2 != 0
        )
        for index in 0..<count {
            let offset = 28 + index * 16
            guard let phase = Contact.Phase(rawValue: buffer[offset + 1]),
                  let kind = Contact.Kind(rawValue: buffer[offset + 2]) else { throw TouchFrameCodecError.invalidContact }
            guard buffer[offset + 3] == 0 else { throw TouchFrameCodecError.reservedBits }
            frame.append(Contact(
                contactID: buffer[offset], phase: phase, kind: kind,
                x: Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))),
                y: Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self))),
                majorRadius: Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self)))
            ))
        }
        return frame
    }
}
