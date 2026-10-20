import Foundation

public struct PeerIdentity: Codable, Equatable, Sendable {
    public let peerID: UUID
    public var name: String

    public init(peerID: UUID = UUID(), name: String) {
        self.peerID = peerID
        self.name = name
    }

    public var tlsIdentity: String { peerID.uuidString.lowercased() }
}
