import CryptoKit
import Foundation
import IOKit
import OSLog
import TrackglassKit

/// The Mac's `peerID` (§3.2) lives in UserDefaults, which Migration Assistant copies to a new Mac, while the pairings
/// (data-protection Keychain, this device only) stay behind; two Macs would then advertise one `id` (L7). A fingerprint
/// of the hardware is stored next to the ID: on other hardware a new peerID is made. Pairings are kept per phone ID in
/// the Keychain, so nothing else needs migrating.
enum MacIdentity {
    static let peerIDKey = "peerID"
    static let hardwareKey = "peerIDHardware"

    enum Decision: Equatable { case keep, generate }

    /// Pure, so `TrackglassMacTests` drives it without IOKit or the Keychain. `hasPairings` is asked only for an ID
    /// written before the fingerprint existed.
    static func decide(storedID: UUID?, storedFingerprint: String?, currentFingerprint: String?,
                       hasPairings: @autoclosure () -> Bool) -> Decision {
        guard storedID != nil else { return .generate }
        // Without a readable fingerprint nothing can be told apart: never drop a working identity.
        guard let currentFingerprint else { return .keep }
        if let storedFingerprint { return storedFingerprint == currentFingerprint ? .keep : .generate }
        // Written by a version without the fingerprint. An ID this Mac has pairings for is the one its phones know.
        // With none (also what a fresh migration looks like) no phone can connect under it anyway, so a new one is safe.
        return hasPairings() ? .keep : .generate
    }

    /// The `peerID` to advertise; stores a new one and the current fingerprint as needed.
    static func resolve(defaults: UserDefaults, store: PairingStore,
                        currentFingerprint: String? = MacIdentity.hardwareFingerprint()) -> UUID {
        let storedID = defaults.string(forKey: peerIDKey).flatMap(UUID.init(uuidString:))
        let decision = decide(storedID: storedID, storedFingerprint: defaults.string(forKey: hardwareKey),
                              currentFingerprint: currentFingerprint,
                              hasPairings: (try? store.all()).map { !$0.isEmpty } ?? true)
        let peerID: UUID
        if decision == .keep, let storedID {
            peerID = storedID
        } else {
            peerID = UUID()
            defaults.set(peerID.uuidString, forKey: peerIDKey)
            if storedID != nil {
                Logger(subsystem: "app.trackglass.mac", category: "net")
                    .notice("this Mac's identity was made on other hardware (Migration Assistant?); using a new one")
            }
        }
        if let currentFingerprint { defaults.set(currentFingerprint, forKey: hardwareKey) }
        return peerID
    }

    /// SHA-256 of `IOPlatformUUID` (public IOKit), hex: identifies this Mac's hardware without storing the UUID itself.
    static func hardwareFingerprint() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String, !uuid.isEmpty else { return nil }
        return SHA256.hash(data: Data(uuid.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
