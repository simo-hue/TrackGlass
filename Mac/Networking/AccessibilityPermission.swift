import AppKit
import ApplicationServices
import Observation

@MainActor @Observable
final class AccessibilityPermission {
    private(set) var isTrusted = false
    private var timer: Timer?
    private var pollTicks = 0
    var onChange: ((Bool) -> Void)?

    func requestAndMonitor() {
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        update(AXIsProcessTrustedWithOptions(prompt))
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pollTicks += 1
                if self.isTrusted && self.pollTicks < 5 { return }
                self.pollTicks = 0
                self.update(AXIsProcessTrusted())
            }
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func update(_ trusted: Bool) {
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        onChange?(trusted)
    }
}
