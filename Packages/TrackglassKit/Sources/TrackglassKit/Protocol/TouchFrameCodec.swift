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
    /// Largest |x| or |y| a contact may carry (§4.4, L1): far beyond any screen, far below what overflows the Mac's
    /// pointer arithmetic.
    public static let maximumCoordinateMagnitudeMM: Float = 10_000
    /// Largest `majorRadius` a contact may carry (§4.4, L1); it is never negative.
    public static let maximumMajorRadiusMM: Float = 1_000

    public static func decode(_ buffer: UnsafeRawBufferPointer) throws -> TouchFrame {
        let header = try MessageHeader.decode(buffer)
        guard header.type == MessageType.touchFrame.rawValue else { throw TouchFrameCodecError.wrongMessageType }
        guard buffer.count >= 28 else { throw ProtocolError.truncated }
        let count = Int(buffer[24])
        guard count <= TouchFrame.maximumContacts else { throw TouchFrameCodecError.invalidContactCount }
        // §4.1 forward compatibility: reserved flag bits, reserved bytes and bytes after the contacts are
        // written as zero / not at all by this version and ignored on receipt (a newer phone may use them).
        guard buffer.count >= 28 + count * 16 else { throw TouchFrameCodecError.invalidLength }
        var frame = TouchFrame(
            sequence: header.sequence, sentAt: header.sentAt,
            frameTime: UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: 16, as: UInt64.self)),
            surfaceIsLandscape: buffer[25] & 1 != 0, isSyntheticLiftoff: buffer[25] & 2 != 0
        )
        for index in 0..<count {
            let offset = 28 + index * 16
            // §4.4 forward compatibility: a phase or kind added by a newer phone skips that contact only (the Mac
            // then treats it as absent, §4.7); its other fields may mean something else, so they are not checked.
            guard let phase = Contact.Phase(rawValue: buffer[offset + 1]),
                  let kind = Contact.Kind(rawValue: buffer[offset + 2]) else { continue }
            let x = Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)))
            let y = Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self)))
            let radius = Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self)))
            // NaN/infinite or absurd values would reach pointer deltas and integer conversions on the Mac; the whole
            // frame is rejected (allocation-free branch). The comparisons are false for NaN.
            guard x.isFinite, y.isFinite, radius.isFinite,
                  x.magnitude <= maximumCoordinateMagnitudeMM, y.magnitude <= maximumCoordinateMagnitudeMM,
                  radius >= 0, radius <= maximumMajorRadiusMM else { throw TouchFrameCodecError.invalidContact }
            frame.append(Contact(contactID: buffer[offset], phase: phase, kind: kind, x: x, y: y, majorRadius: radius))
        }
        return frame
    }
}
