import AppKit
import Network
import Observation

/// macOS 15+ asks before an app may advertise or browse Bonjour services (§6.2). When the user said no, every
/// listener reports `kDNSServiceErr_PolicyDenied`; this turns that into a state the menu, the pairing window and
/// Welcome can explain with a button, instead of a raw DNS-SD error code.
@MainActor @Observable
final class LocalNetworkPermission {
    static let shared = LocalNetworkPermission()

    /// True once a listener reported the policy denial, false again once a service registered.
    private(set) var isDenied = false

    /// `kDNSServiceErr_PolicyDenied`.
    nonisolated static let policyDeniedCode: Int32 = -65570

    nonisolated static func isPolicyDenied(_ error: NWError) -> Bool {
        if case let .dns(code) = error { return code == policyDeniedCode }
        return false
    }

    /// Plain-language status for a listener that is waiting or failed.
    nonisolated static func message(for error: NWError, failed: Bool) -> String {
        if isPolicyDenied(error) {
            return "Local Network access is off for Trackglass for Mac. Turn it on in System Settings → Privacy & Security → Local Network."
        }
        return (failed ? "Discovery failed: " : "Discovery waiting: ") + error.localizedDescription
    }

    /// Records what a listener reported: a denial sets the flag, any other outcome leaves it alone.
    func report(_ error: NWError) {
        if Self.isPolicyDenied(error) { isDenied = true }
    }

    /// A Bonjour service registered, so advertising is allowed.
    func reportRegistered() { isDenied = false }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") else { return }
        NSWorkspace.shared.open(url)
    }
}
