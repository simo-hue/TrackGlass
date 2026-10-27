import Foundation
import TrackglassKit

actor SessionCoordinator {
    struct Session: Sendable {
        let id: UUID
        let peer: HelloMessage
        var surface: SurfaceMessage
    }
    private(set) var activeSession: Session?

    func admit(id: UUID, peer: HelloMessage) -> String? {
        if let activeSession { return activeSession.peer.name }
        activeSession = Session(id: id, peer: peer, surface: SurfaceMessage(
            surfaceWidthMM: peer.surfaceWidthMM, surfaceHeightMM: peer.surfaceHeightMM,
            ppi: peer.ppi, trackingOverride: peer.trackingOverride))
        return nil
    }

    func updateSurface(id: UUID, surface: SurfaceMessage) {
        guard activeSession?.id == id else { return }
        activeSession?.surface = surface
    }

    func release(id: UUID) {
        guard activeSession?.id == id else { return }
        activeSession = nil
    }
}
