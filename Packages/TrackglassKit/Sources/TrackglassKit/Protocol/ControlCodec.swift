import Foundation

public enum ControlCodecError: Error, Equatable, Sendable {
    case stringTooLong
    case invalidUTF8
    case invalidKeyLength
    case trailingBytes
    case invalidValue
}

public struct ControlPacket: Equatable, Sendable {
    public let header: MessageHeader
    public let message: ControlMessage
}

extension ControlMessage {
    public func encode(sequence: UInt32, sentAt: UInt64) throws -> Data {
        var writer = ControlWriter()
        var headerBytes = Data(count: MessageHeader.byteCount)
        _ = try headerBytes.withUnsafeMutableBytes {
            try MessageHeader(type: type, sequence: sequence, sentAt: sentAt).encode(into: $0)
        }
        writer.data = headerBytes
        switch self {
        case .hello(let value):
            writer.write(value.protocolVersion)
            writer.write(value.peerID)
            try writer.write(value.name)
            try writer.write(value.modelIdentifier)
            writer.write(value.surfaceWidthMM)
            writer.write(value.surfaceHeightMM)
            writer.write(value.ppi)
            writer.write(value.maxContacts)
            writer.write(value.displayHz)
            writer.write(value.caps)
            writer.write(value.trackingOverride)
        case .welcome(let value):
            writer.write(value.status)
            writer.write(value.macPeerID)
            try writer.write(value.macName)
            try writer.write(value.macOSVersion)
            writer.write(value.injectorMode)
            writer.settings(value.settings)
            try writer.write(value.activePhoneName)
        case .settings(let value):
            writer.settings(value)
        case .ping(let value):
            writer.write(value.nonce)
        case .pong(let value):
            writer.write(value.nonce)
            writer.write(value.echoSentAt)
        case .haptic(let value):
            writer.write(value.kind)
            writer.write(value.intensity)
        case .status(let value):
            writer.write(value.lossPermille)
            writer.write(value.rttMicros)
            writer.write(value.framesPerSecond)
            writer.write(value.pipelineP50Micros)
            writer.write(value.pipelineP95Micros)
            writer.write(value.engineState)
        case .surface(let value):
            writer.write(value.surfaceWidthMM)
            writer.write(value.surfaceHeightMM)
            writer.write(value.ppi)
            writer.write(value.trackingOverride)
        case .bye(let value):
            writer.write(value.reason)
        case .pairRequest(let value):
            writer.write(value.peerID)
            try writer.write(value.name)
            try writer.write(value.modelIdentifier)
            writer.write(value.protocolVersion)
            guard value.ephemeralPublicKey.count == 32 else { throw ControlCodecError.invalidKeyLength }
            writer.data.append(value.ephemeralPublicKey)
        case .pairResponse(let value):
            writer.write(value.peerID)
            try writer.write(value.name)
            guard value.ephemeralPublicKey.count == 32 else { throw ControlCodecError.invalidKeyLength }
            writer.data.append(value.ephemeralPublicKey)
        case .pairCommit(let value):
            writer.write(value.peerID)
            try writer.write(value.name)
            guard value.ephemeralPublicKey.count == 32, value.commitment.count == 32 else { throw ControlCodecError.invalidKeyLength }
            writer.data.append(value.ephemeralPublicKey)
            writer.data.append(value.commitment)
        case .pairNonce(let value), .pairReveal(let value):
            guard value.nonce.count == 32 else { throw ControlCodecError.invalidKeyLength }
            writer.data.append(value.nonce)
        case .pairConfirm, .unknown: break
        }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> ControlPacket {
        let header = try data.withUnsafeBytes { try MessageHeader.decode($0) }
        var reader = ControlReader(data: data, offset: MessageHeader.byteCount)
        let message: ControlMessage
        switch MessageType(rawValue: header.type) {
        case .hello:
            message = .hello(try HelloMessage(
                protocolVersion: reader.integer(UInt8.self),
                peerID: reader.uuid(),
                name: reader.string(),
                modelIdentifier: reader.string(),
                surfaceWidthMM: reader.float(),
                surfaceHeightMM: reader.float(),
                ppi: reader.float(),
                maxContacts: reader.integer(UInt8.self),
                displayHz: reader.integer(UInt16.self),
                caps: reader.integer(UInt32.self),
                trackingOverride: reader.float()
            ))
        case .welcome:
            message = .welcome(try WelcomeMessage(
                status: reader.integer(UInt8.self),
                macPeerID: reader.uuid(),
                macName: reader.string(),
                macOSVersion: reader.string(),
                injectorMode: reader.integer(UInt8.self),
                settings: reader.settings(),
                activePhoneName: reader.string()
            ))
        case .settings:
            message = .settings(try reader.settings())
        case .ping:
            message = .ping(try PingMessage(
                nonce: reader.integer(UInt32.self)
            ))
        case .pong:
            message = .pong(try PongMessage(
                nonce: reader.integer(UInt32.self),
                echoSentAt: reader.integer(UInt64.self)
            ))
        case .haptic:
            message = .haptic(try HapticMessage(
                kind: reader.integer(UInt8.self),
                intensity: reader.integer(UInt8.self)
            ))
        case .status:
            message = .status(try StatusMessage(
                lossPermille: reader.integer(UInt16.self),
                rttMicros: reader.integer(UInt32.self),
                framesPerSecond: reader.integer(UInt16.self),
                pipelineP50Micros: reader.integer(UInt32.self),
                pipelineP95Micros: reader.integer(UInt32.self),
                engineState: reader.integer(UInt8.self)
            ))
        case .surface:
            message = .surface(try SurfaceMessage(
                surfaceWidthMM: reader.float(),
                surfaceHeightMM: reader.float(),
                ppi: reader.float(),
                trackingOverride: reader.float()
            ))
        case .bye:
            message = .bye(try ByeMessage(
                reason: reader.integer(UInt8.self)
            ))
        case .pairRequest:
            message = .pairRequest(try PairRequestMessage(
                peerID: reader.uuid(),
                name: reader.string(),
                modelIdentifier: reader.string(),
                protocolVersion: reader.integer(UInt8.self),
                ephemeralPublicKey: reader.bytes(count: 32)
            ))
        case .pairResponse:
            message = .pairResponse(try PairResponseMessage(
                peerID: reader.uuid(),
                name: reader.string(),
                ephemeralPublicKey: reader.bytes(count: 32)
            ))
        case .pairCommit:
            message = .pairCommit(try PairCommitMessage(
                peerID: reader.uuid(),
                name: reader.string(),
                ephemeralPublicKey: reader.bytes(count: 32),
                commitment: reader.bytes(count: 32)
            ))
        case .pairNonce:
            message = .pairNonce(try PairNonceMessage(nonce: reader.bytes(count: 32)))
        case .pairReveal:
            message = .pairReveal(try PairNonceMessage(nonce: reader.bytes(count: 32)))
        case .pairConfirm:
            message = .pairConfirm
        default:
            return ControlPacket(header: header, message: .unknown(type: header.type))
        }
        // §4.1 forward compatibility: bytes after the fields this version knows are fields a newer peer
        // appended; they are ignored, so the Mac (Sparkle) and the phone (App Store) can update separately.
        try validateGeometry(message)
        return ControlPacket(header: header, message: message)
    }

    /// Surface dimensions and density feed pointer math and CGEvent coordinates directly; NaN and infinite values
    /// are rejected here rather than propagating (§8 robustness), and so is a non-positive HELLO size or density.
    /// A SURFACE with a zero or negative width/height still decodes (L9, 2026-10-31): the Mac ignores it and keeps
    /// the previous geometry instead of ending the session as "incompatible", which the phone treats as final.
    private static func validateGeometry(_ message: ControlMessage) throws {
        switch message {
        case .hello(let hello):
            guard [hello.surfaceWidthMM, hello.surfaceHeightMM, hello.ppi].allSatisfy({ $0.isFinite && $0 > 0 }),
                  hello.trackingOverride.isFinite else { throw ControlCodecError.invalidValue }
        case .surface(let surface):
            guard [surface.surfaceWidthMM, surface.surfaceHeightMM, surface.trackingOverride].allSatisfy(\.isFinite),
                  surface.ppi.isFinite, surface.ppi > 0 else { throw ControlCodecError.invalidValue }
        default: return
        }
    }
}

private struct ControlWriter {
    var data = Data()

    mutating func write<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func write(_ value: Float) { write(value.bitPattern) }

    mutating func write(_ value: UUID) {
        var bytes = value.uuid
        withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
    }

    mutating func write(_ value: String) throws {
        let bytes = value.utf8
        guard bytes.count <= Int(UInt16.max) else { throw ControlCodecError.stringTooLong }
        write(UInt16(bytes.count))
        data.append(contentsOf: bytes)
    }

    mutating func settings(_ value: SettingsMessage) {
        write(value.naturalScrolling)
        write(value.tapToClick)
        write(value.forceClickEnabled)
        write(value.hapticsSuggested)
        write(value.trackingSpeed)
        write(value.secondaryClickMode)
        write(value.scrollEnabled)
        write(value.horizontalScrollEnabled)
        write(value.momentumScrollEnabled)
        write(value.pinchEnabled)
        write(value.rotateEnabled)
        write(value.smartZoomEnabled)
        write(value.swipeNavigationEnabled)
    }
}

private struct ControlReader {
    let data: Data
    var offset: Int

    mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let count = MemoryLayout<T>.size
        guard data.count - offset >= count else { throw ProtocolError.truncated }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        offset += count
        return T(littleEndian: value)
    }

    mutating func bytes(count: Int) throws -> Data {
        guard data.count - offset >= count else { throw ProtocolError.truncated }
        defer { offset += count }
        return data.withUnsafeBytes { Data($0[offset..<(offset + count)]) }
    }

    mutating func float() throws -> Float { Float(bitPattern: try integer(UInt32.self)) }

    mutating func uuid() throws -> UUID {
        let bytes = try bytes(count: 16)
        return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }

    mutating func string() throws -> String {
        let length = Int(try integer(UInt16.self))
        guard let value = String(data: try bytes(count: length), encoding: .utf8) else {
            throw ControlCodecError.invalidUTF8
        }
        return value
    }

    mutating func settings() throws -> SettingsMessage {
        try SettingsMessage(naturalScrolling: integer(UInt8.self), tapToClick: integer(UInt8.self),
                            forceClickEnabled: integer(UInt8.self), hapticsSuggested: integer(UInt8.self),
                            trackingSpeed: float(), secondaryClickMode: integer(UInt8.self),
                            scrollEnabled: integer(UInt8.self),
                            horizontalScrollEnabled: integer(UInt8.self),
                            momentumScrollEnabled: integer(UInt8.self),
                            pinchEnabled: integer(UInt8.self),
                            rotateEnabled: integer(UInt8.self),
                            smartZoomEnabled: integer(UInt8.self),
                            swipeNavigationEnabled: integer(UInt8.self))
    }
}
