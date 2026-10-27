import Foundation
import Darwin
import TrackglassKit

@MainActor
final class PhoneIdentityStore {
    let peerID: UUID
    private let defaults: UserDefaults

    var name: String {
        get { defaults.string(forKey: "peerName") ?? "iPhone" }
        set { defaults.set(newValue, forKey: "peerName") }
    }

    init(defaults: UserDefaults = .standard, modelIdentifier: String = PhoneIdentityStore.modelIdentifier()) {
        self.defaults = defaults
        if let stored = defaults.string(forKey: "peerID"), let id = UUID(uuidString: stored) {
            peerID = id
        } else {
            peerID = UUID()
            defaults.set(peerID.uuidString, forKey: "peerID")
        }
        if defaults.string(forKey: "peerName") == nil {
            defaults.set(DeviceModelName.marketingName(modelIdentifier: modelIdentifier), forKey: "peerName")
        }
    }

    nonisolated static func modelIdentifier() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
