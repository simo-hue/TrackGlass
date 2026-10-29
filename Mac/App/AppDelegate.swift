import AppKit

/// App-level events SwiftUI's `App` does not deliver (§6.1). `TrackglassMacApp.init` installs the hooks before the
/// first event arrives.
@MainActor
final class TrackglassAppDelegate: NSObject, NSApplicationDelegate {
    /// Opening the app while it runs (Finder, Launchpad, Spotlight, `open`, a second copy that yielded).
    static var onReopen: (() -> Void)?
    /// Tells every phone goodbye and stops the input pipeline; calls `done` once that went out (bounded).
    static var prepareForTermination: ((_ done: @escaping @MainActor @Sendable () -> Void) -> Void)?
    /// Posted (distributed) by a second copy before it exits, so the running one shows a window instead.
    static let showWindowNotification = Notification.Name("app.trackglass.mac.showWindow")

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.onReopen?()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepare = Self.prepareForTermination else { return .terminateNow }
        Self.prepareForTermination = nil
        prepare { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

/// Two copies of the menu-bar app would both advertise and both inject. When a second copy starts, exactly one
/// survives: the one launched first (ties and missing dates: the lower process ID), so two copies started at the same
/// moment never both exit.
enum SingleInstance {
    struct Instance: Equatable, Sendable {
        let processIdentifier: pid_t
        let launchDate: Date?
    }

    /// True when `a` was there first.
    static func precedes(_ a: Instance, _ b: Instance) -> Bool {
        // A strict total order (a copy without a launch date sorts last), so with any number of copies exactly
        // one survives.
        let first = a.launchDate ?? .distantFuture, second = b.launchDate ?? .distantFuture
        return first != second ? first < second : a.processIdentifier < b.processIdentifier
    }

    /// True when this copy must exit because another one precedes it.
    static func shouldYield(_ me: Instance, to others: [Instance]) -> Bool {
        others.contains { $0.processIdentifier != me.processIdentifier && precedes($0, me) }
    }
}

extension SingleInstance.Instance {
    init(_ application: NSRunningApplication) {
        self.init(processIdentifier: application.processIdentifier, launchDate: application.launchDate)
    }
}
