import AppKit
import ApplicationServices

/// The fallback uses the same accessible Clock menu item a user can press.
enum NotificationCenterAction {
    /// M16 (§6.9.5): the Clock menu extra's `AXIdentifier` does not depend on the system language; its description
    /// does ("Clock", "Uhr", "Orologio"), so the English description is only the fallback.
    static let clockIdentifier = "com.apple.menuextra.clock"
    static let clockDescription = "Clock"
    /// Set on every element queried (an element does not inherit its application's timeout): a hung Control Center
    /// must not block the main actor for the system's ~6 s default, which would stall the control channel's PINGs.
    static let messagingTimeout: Float = 0.2

    @MainActor static func perform() -> Bool {
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else { return false }
        let application = AXUIElementCreateApplication(process.processIdentifier)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, "AXExtrasMenuBar" as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
        let menu = unsafeDowncast(bar, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(menu, messagingTimeout)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return false }
        // One timed-out query means Control Center stopped answering: the remaining items are not asked.
        var stalled = false
        func string(_ attribute: CFString, of index: Int) -> String? {
            guard !stalled else { return nil }
            AXUIElementSetMessagingTimeout(items[index], messagingTimeout)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(items[index], attribute, &value)
            if result == .cannotComplete { stalled = true }
            return result == .success ? value as? String : nil
        }
        guard let index = clockIndex(count: items.count,
                                     identifier: { string("AXIdentifier" as CFString, of: $0) },
                                     description: { string(kAXDescriptionAttribute as CFString, of: $0) }) else { return false }
        return AXUIElementPerformAction(items[index], kAXPressAction as CFString) == .success
    }

    /// The Clock item among `count` menu extras: by identifier first, else by the English description. Pure (the
    /// attributes come from the closures, asked lazily and in order), so it is tested without Accessibility.
    static func clockIndex(count: Int, identifier: (Int) -> String?, description: (Int) -> String?) -> Int? {
        if let index = (0..<count).first(where: { identifier($0) == clockIdentifier }) { return index }
        return (0..<count).first(where: { description($0) == clockDescription })
    }
}
