import AppKit
import ApplicationServices

/// The fallback uses the same accessible Clock menu item a user can press.
enum NotificationCenterAction {
    @MainActor static func perform() -> Bool {
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else { return false }
        let application = AXUIElementCreateApplication(process.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, "AXExtrasMenuBar" as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
        let menu = unsafeDowncast(bar, to: AXUIElement.self)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return false }
        for item in items {
            var description: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXDescriptionAttribute as CFString, &description) == .success,
                  description as? String == "Clock" else { continue }
            return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        }
        return false
    }
}
