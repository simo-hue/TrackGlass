import Foundation

public struct HelloMessage: Equatable, Sendable {
    public var protocolVersion: UInt8
    public var peerID: UUID
    public var name: String
    public var modelIdentifier: String
    public var surfaceWidthMM: Float
    public var surfaceHeightMM: Float
    public var ppi: Float
    public var maxContacts: UInt8
    public var displayHz: UInt16
    public var caps: UInt32
    public var trackingOverride: Float

    public init(protocolVersion: UInt8, peerID: UUID, name: String, modelIdentifier: String, surfaceWidthMM: Float, surfaceHeightMM: Float, ppi: Float, maxContacts: UInt8, displayHz: UInt16, caps: UInt32, trackingOverride: Float) {
        self.protocolVersion = protocolVersion
        self.peerID = peerID
        self.name = name
        self.modelIdentifier = modelIdentifier
        self.surfaceWidthMM = surfaceWidthMM
        self.surfaceHeightMM = surfaceHeightMM
        self.ppi = ppi
        self.maxContacts = maxContacts
        self.displayHz = displayHz
        self.caps = caps
        self.trackingOverride = trackingOverride
    }
}

public struct WelcomeMessage: Equatable, Sendable {
    public var status: UInt8
    public var macPeerID: UUID
    public var macName: String
    public var macOSVersion: String
    public var injectorMode: UInt8
    public var settings: SettingsMessage
    public var activePhoneName: String

    public init(status: UInt8, macPeerID: UUID, macName: String, macOSVersion: String, injectorMode: UInt8, settings: SettingsMessage, activePhoneName: String = "") {
        self.status = status
        self.macPeerID = macPeerID
        self.macName = macName
        self.macOSVersion = macOSVersion
        self.injectorMode = injectorMode
        self.settings = settings
        self.activePhoneName = activePhoneName
    }
}

public struct SettingsMessage: Equatable, Sendable {
    public var naturalScrolling: UInt8
    public var tapToClick: UInt8
    public var forceClickEnabled: UInt8
    public var hapticsSuggested: UInt8
    public var trackingSpeed: Float
    public var secondaryClickMode: UInt8
    public var scrollEnabled: UInt8
    public var horizontalScrollEnabled: UInt8
    public var momentumScrollEnabled: UInt8
    public var pinchEnabled: UInt8
    public var rotateEnabled: UInt8
    public var smartZoomEnabled: UInt8
    public var swipeNavigationEnabled: UInt8

    public init(naturalScrolling: UInt8, tapToClick: UInt8, forceClickEnabled: UInt8, hapticsSuggested: UInt8, trackingSpeed: Float, secondaryClickMode: UInt8,
                scrollEnabled: UInt8 = 1, horizontalScrollEnabled: UInt8 = 1, momentumScrollEnabled: UInt8 = 1, pinchEnabled: UInt8 = 1, rotateEnabled: UInt8 = 1, smartZoomEnabled: UInt8 = 1, swipeNavigationEnabled: UInt8 = 1) {
        self.naturalScrolling = naturalScrolling
        self.tapToClick = tapToClick
        self.forceClickEnabled = forceClickEnabled
        self.hapticsSuggested = hapticsSuggested
        self.trackingSpeed = trackingSpeed
        self.secondaryClickMode = secondaryClickMode
        self.scrollEnabled = scrollEnabled
        self.horizontalScrollEnabled = horizontalScrollEnabled
        self.momentumScrollEnabled = momentumScrollEnabled
        self.pinchEnabled = pinchEnabled
        self.rotateEnabled = rotateEnabled
        self.smartZoomEnabled = smartZoomEnabled
        self.swipeNavigationEnabled = swipeNavigationEnabled
    }
}

public struct PingMessage: Equatable, Sendable {
    public var nonce: UInt32

    public init(nonce: UInt32) {
        self.nonce = nonce
    }
}

public struct PongMessage: Equatable, Sendable {
    public var nonce: UInt32
    public var echoSentAt: UInt64

    public init(nonce: UInt32, echoSentAt: UInt64) {
        self.nonce = nonce
        self.echoSentAt = echoSentAt
    }
}

public struct HapticMessage: Equatable, Sendable {
    public var kind: UInt8
    public var intensity: UInt8

    public init(kind: UInt8, intensity: UInt8) {
        self.kind = kind
        self.intensity = intensity
    }
}

public struct StatusMessage: Equatable, Sendable {
    public var lossPermille: UInt16
    public var rttMicros: UInt32
    public var framesPerSecond: UInt16
    public var pipelineP50Micros: UInt32
    public var pipelineP95Micros: UInt32
    public var engineState: UInt8

    public init(lossPermille: UInt16, rttMicros: UInt32, framesPerSecond: UInt16, pipelineP50Micros: UInt32, pipelineP95Micros: UInt32, engineState: UInt8) {
        self.lossPermille = lossPermille
        self.rttMicros = rttMicros
        self.framesPerSecond = framesPerSecond
        self.pipelineP50Micros = pipelineP50Micros
        self.pipelineP95Micros = pipelineP95Micros
        self.engineState = engineState
    }
}

public struct SurfaceMessage: Equatable, Sendable {
    public var surfaceWidthMM: Float
    public var surfaceHeightMM: Float
    public var ppi: Float
    public var trackingOverride: Float

    public init(surfaceWidthMM: Float, surfaceHeightMM: Float, ppi: Float, trackingOverride: Float) {
        self.surfaceWidthMM = surfaceWidthMM
        self.surfaceHeightMM = surfaceHeightMM
        self.ppi = ppi
        self.trackingOverride = trackingOverride
    }
}

public struct ByeMessage: Equatable, Sendable {
    public var reason: UInt8

    public init(reason: UInt8) {
        self.reason = reason
    }
}

/// §4.5 PAIR_REQUEST. `ephemeralPublicKey` (owner-approved 2026-10-28, pairing hardening): the phone's one-time
/// X25519 public key (32 bytes, raw). `PairingClient` fills it per attempt; encoding throws while it is empty.
public struct PairRequestMessage: Equatable, Sendable {
    public var peerID: UUID
    public var name: String
    public var modelIdentifier: String
    public var protocolVersion: UInt8
    public var ephemeralPublicKey: Data

    public init(peerID: UUID, name: String, modelIdentifier: String, protocolVersion: UInt8, ephemeralPublicKey: Data = Data()) {
        self.peerID = peerID
        self.name = name
        self.modelIdentifier = modelIdentifier
        self.protocolVersion = protocolVersion
        self.ephemeralPublicKey = ephemeralPublicKey
    }
}

/// §4.5 PAIR_RESPONSE. The LTK is never transmitted: the Mac answers with its own one-time X25519 public key and both
/// sides derive the LTK (§3.4: `KeyDerivation.pairingLTK` for QR, `codePairingLTK` for code pairing). In code pairing
/// the key repeats the one PAIR_COMMIT committed to, and the message is sent only after Allow and PAIR_CONFIRM.
public struct PairResponseMessage: Equatable, Sendable {
    public var peerID: UUID
    public var name: String
    public var ephemeralPublicKey: Data

    public init(peerID: UUID, name: String, ephemeralPublicKey: Data) {
        self.peerID = peerID
        self.name = name
        self.ephemeralPublicKey = ephemeralPublicKey
    }
}

/// §4.5 PAIR_COMMIT (code pairing, 2026-10-31; Mac → phone, the answer to PAIR_REQUEST): the Mac's identity, its
/// one-time X25519 public key and `commitment = SHA-256("trackglass-commit-v1" ‖ Nm ‖ macPK ‖ phonePK)`, which binds
/// the Mac's nonce before the phone reveals its own (`KeyDerivation.commitment`).
public struct PairCommitMessage: Equatable, Sendable {
    public var peerID: UUID
    public var name: String
    public var ephemeralPublicKey: Data
    public var commitment: Data

    public init(peerID: UUID, name: String, ephemeralPublicKey: Data, commitment: Data) {
        self.peerID = peerID
        self.name = name
        self.ephemeralPublicKey = ephemeralPublicKey
        self.commitment = commitment
    }
}

/// §4.5 PAIR_NONCE (phone → Mac, Np) and PAIR_REVEAL (Mac → phone, Nm): one 32-byte nonce.
public struct PairNonceMessage: Equatable, Sendable {
    public var nonce: Data

    public init(nonce: Data) {
        self.nonce = nonce
    }
}

public enum ControlMessage: Equatable, Sendable {
    case hello(HelloMessage)
    case welcome(WelcomeMessage)
    case settings(SettingsMessage)
    case ping(PingMessage)
    case pong(PongMessage)
    case haptic(HapticMessage)
    case status(StatusMessage)
    case surface(SurfaceMessage)
    case bye(ByeMessage)
    case pairRequest(PairRequestMessage)
    case pairResponse(PairResponseMessage)
    case pairCommit(PairCommitMessage)
    case pairNonce(PairNonceMessage)
    case pairReveal(PairNonceMessage)
    /// The phone's user tapped "Matches" (empty payload).
    case pairConfirm
    case unknown(type: UInt8)

    public var type: UInt8 {
        switch self {
        case .hello: return MessageType.hello.rawValue
        case .welcome: return MessageType.welcome.rawValue
        case .settings: return MessageType.settings.rawValue
        case .ping: return MessageType.ping.rawValue
        case .pong: return MessageType.pong.rawValue
        case .haptic: return MessageType.haptic.rawValue
        case .status: return MessageType.status.rawValue
        case .surface: return MessageType.surface.rawValue
        case .bye: return MessageType.bye.rawValue
        case .pairRequest: return MessageType.pairRequest.rawValue
        case .pairResponse: return MessageType.pairResponse.rawValue
        case .pairCommit: return MessageType.pairCommit.rawValue
        case .pairNonce: return MessageType.pairNonce.rawValue
        case .pairReveal: return MessageType.pairReveal.rawValue
        case .pairConfirm: return MessageType.pairConfirm.rawValue
        case .unknown(let type): return type
        }
    }
}
