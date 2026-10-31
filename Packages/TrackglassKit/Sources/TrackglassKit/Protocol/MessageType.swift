public enum MessageType: UInt8, CaseIterable, Sendable {
    case hello = 0x01
    case welcome = 0x02
    case settings = 0x03
    case ping = 0x04
    case pong = 0x05
    case haptic = 0x06
    case status = 0x07
    case surface = 0x08
    case bye = 0x09
    case touchFrame = 0x10
    case inputHeartbeat = 0x11
    case pairRequest = 0x20
    case pairResponse = 0x21
    // §3.4 / §4.5 code pairing (2026-10-31): pairing channel only.
    case pairCommit = 0x22
    case pairNonce = 0x23
    case pairReveal = 0x24
    case pairConfirm = 0x25
}
