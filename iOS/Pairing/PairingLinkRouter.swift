import Foundation
import Observation
import TrackglassKit

struct PairingPresentation: Identifiable {
    let id = UUID()
    let payload: PairingPayload?
}

@MainActor @Observable
final class PairingLinkRouter {
    var presentation: PairingPresentation?

    func showPairing() { presentation = PairingPresentation(payload: nil) }

    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let payload = try? PairingPayload(url: url) else { return false }
        presentation = PairingPresentation(payload: payload)
        return true
    }
}
