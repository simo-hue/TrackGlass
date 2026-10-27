import AppKit
import CoreFoundation
import IOKit.hid
import OSLog
import TrackglassEngine

final class TrackpadPreferences: @unchecked Sendable {
    private static let builtInDomain = "com.apple.AppleMultitouchTrackpad"
    private static let bluetoothDomain = "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    private let queue = DispatchQueue(label: "trackpad-preferences", qos: .utility)
    private let lock = NSLock()
    private let logger = Logger(subsystem: "app.trackglass.mac", category: "prefs")
    private var timer: DispatchSourceTimer?
    private var snapshot = TrackpadSettings()
    private var reportedUnknownKeys = Set<String>()
    var onChange: (@Sendable (TrackpadSettings) -> Void)?

    var currentSnapshot: TrackpadSettings {
        lock.lock(); defer { lock.unlock() }; return snapshot
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: self.queue)
            source.schedule(deadline: .now(), repeating: .seconds(2))
            source.setEventHandler { [weak self] in self?.poll() }
            self.timer = source; source.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in self?.timer?.cancel(); self?.timer = nil }
    }

    private func poll() {
        dispatchPrecondition(condition: .onQueue(queue))
        let next = Self.readSnapshot { key in
            if self.reportedUnknownKeys.insert(key).inserted {
                self.logger.info("Unrecognized trackpad preference value for \(key, privacy: .public); using default")
            }
        }
        lock.lock(); let changed = next != snapshot; snapshot = next; lock.unlock()
        if changed {
            logger.info("trackpad preferences changed clicking=\(next.clicking) secondary=\(next.trackpadRightClick) corner=\(next.cornerSecondaryClick) dragging=\(next.dragging) dragLock=\(next.dragLock) threeFingerDrag=\(next.threeFingerDrag) natural=\(next.naturalScrolling) trackingSpeed=\(next.trackingSpeed)")
            onChange?(next)
        }
    }

    static func parseFixture(_ data: Data, bluetoothTrackpadConnected: Bool) throws -> TrackpadSettings {
        guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let builtIn = root["builtIn"] as? [String: Any],
              let bluetooth = root["bluetooth"] as? [String: Any],
              let global = root["global"] as? [String: Any] else { throw FixtureError.invalidPropertyList }
        return makeSnapshot(selected: bluetoothTrackpadConnected ? builtIn.merging(bluetooth) { $1 } : builtIn,
                            global: global, dock: root["dock"] as? [String: Any] ?? [:], doubleClickInterval: 0.5)
    }

    private static func readSnapshot(reportUnknown: (String) -> Void) -> TrackpadSettings {
        let builtIn = readDomain(builtInDomain)
        let bluetooth = readDomain(bluetoothDomain)
        let global = readGlobalDomain()
        // §6.4: the Bluetooth trackpad's keys take precedence while it is connected; keys it lacks fall back to the built-in domain.
        let selected = validated(bluetoothTrackpadConnected() ? builtIn.merging(bluetooth) { $1 } : builtIn, reportUnknown: reportUnknown)
        return makeSnapshot(selected: selected, global: validated(global, reportUnknown: reportUnknown),
            dock: validated(readDomain("com.apple.dock"), reportUnknown: reportUnknown), doubleClickInterval: NSEvent.doubleClickInterval)
    }

    static func validated(_ values: [String: Any], reportUnknown: (String) -> Void) -> [String: Any] {
        var result = values
        let booleans = ["Clicking", "TrackpadRightClick", "Dragging", "DragLock", "TrackpadThreeFingerDrag", "ForceSuppressed",
            "TrackpadScroll", "TrackpadHorizScroll", "TrackpadMomentumScroll", "TrackpadPinch", "TrackpadRotate", "TrackpadTwoFingerDoubleTapGesture",
            "com.apple.swipescrolldirection", "com.apple.trackpad.forceClick", "com.apple.trackpad.threeFingerDragGesture",
            "AppleEnableSwipeNavigateWithScrolls", "showMissionControlGestureEnabled", "showAppExposeGestureEnabled",
            "showLaunchpadGestureEnabled", "showDesktopGestureEnabled"]
        let gestures = ["TrackpadCornerSecondaryClick", "TrackpadThreeFingerTapGesture", "TrackpadThreeFingerHorizSwipeGesture",
            "TrackpadFourFingerHorizSwipeGesture", "TrackpadThreeFingerVertSwipeGesture", "TrackpadFourFingerVertSwipeGesture",
            "TrackpadFourFingerPinchGesture", "TrackpadFiveFingerPinchGesture"]
        for key in booleans + gestures + ["TrackpadTwoFingerFromRightEdgeSwipeGesture", "com.apple.trackpad.scaling", "com.apple.mouse.tapBehavior"] {
            guard let raw = values[key] else { continue }
            let value = (raw as? NSNumber)?.doubleValue
            let valid: Bool
            if key == "com.apple.trackpad.scaling" { valid = value.map { $0.isFinite && $0 >= -1 && $0 <= 3 } ?? false }
            else if key == "TrackpadTwoFingerFromRightEdgeSwipeGesture" { valid = value == 0 || value == 3 }
            else if booleans.contains(key) { valid = value == 0 || value == 1 }
            else { valid = value == 0 || value == 1 || value == 2 }
            if !valid { result.removeValue(forKey: key); reportUnknown(key) }
        }
        return result
    }

    private static func makeSnapshot(selected: [String: Any], global: [String: Any], dock: [String: Any], doubleClickInterval: TimeInterval) -> TrackpadSettings {
        let globalClicking = number(global["com.apple.mouse.tapBehavior"])?.intValue
        let clicking = bool(selected["Clicking"]) ?? (globalClicking.map { $0 != 0 } ?? true)
        let forceEnabled = bool(global["com.apple.trackpad.forceClick"]) ?? true
        let forceSuppressed = bool(selected["ForceSuppressed"]) ?? false
        let threeFingerDrag = bool(selected["TrackpadThreeFingerDrag"])
            ?? bool(global["com.apple.trackpad.threeFingerDragGesture"]) ?? false
        return TrackpadSettings(
            naturalScrolling: bool(global["com.apple.swipescrolldirection"]) ?? true,
            clicking: clicking,
            trackpadRightClick: bool(selected["TrackpadRightClick"]) ?? true,
            cornerSecondaryClick: integer(selected["TrackpadCornerSecondaryClick"]) ?? 0,
            dragging: bool(selected["Dragging"]) ?? false,
            dragLock: bool(selected["DragLock"]) ?? false,
            threeFingerDrag: threeFingerDrag,
            forceClickEnabled: forceEnabled && !forceSuppressed,
            threeFingerTapGesture: integer(selected["TrackpadThreeFingerTapGesture"]) ?? 2,
            trackingSpeed: number(global["com.apple.trackpad.scaling"])?.doubleValue ?? 0.6875,
            scrollEnabled: bool(selected["TrackpadScroll"]) ?? true,
            horizontalScrollEnabled: bool(selected["TrackpadHorizScroll"]) ?? true,
            momentumScrollEnabled: bool(selected["TrackpadMomentumScroll"]) ?? true,
            pinchEnabled: bool(selected["TrackpadPinch"]) ?? true,
            rotateEnabled: bool(selected["TrackpadRotate"]) ?? true,
            smartZoomEnabled: bool(selected["TrackpadTwoFingerDoubleTapGesture"]) ?? true,
            swipeNavigationEnabled: bool(global["AppleEnableSwipeNavigateWithScrolls"]) ?? true,
            threeFingerHorizontalGesture: integer(selected["TrackpadThreeFingerHorizSwipeGesture"]) ?? 2,
            fourFingerHorizontalGesture: integer(selected["TrackpadFourFingerHorizSwipeGesture"]) ?? 2,
            threeFingerVerticalGesture: integer(selected["TrackpadThreeFingerVertSwipeGesture"]) ?? 2,
            fourFingerVerticalGesture: integer(selected["TrackpadFourFingerVertSwipeGesture"]) ?? 2,
            fourFingerPinchGesture: integer(selected["TrackpadFourFingerPinchGesture"]) ?? 2,
            fiveFingerPinchGesture: integer(selected["TrackpadFiveFingerPinchGesture"]) ?? 2,
            notificationCenterEdgeGesture: integer(selected["TrackpadTwoFingerFromRightEdgeSwipeGesture"]) ?? 3,
            missionControlEnabled: bool(dock["showMissionControlGestureEnabled"]) ?? true,
            appExposeEnabled: bool(dock["showAppExposeGestureEnabled"]) ?? true,
            launchpadEnabled: bool(dock["showLaunchpadGestureEnabled"]) ?? true,
            showDesktopEnabled: bool(dock["showDesktopGestureEnabled"]) ?? true,
            doubleClickIntervalNs: UInt64(max(0, doubleClickInterval) * 1_000_000_000)
        )
    }

    private static func readDomain(_ domain: String) -> [String: Any] {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyMultiple(nil, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
    }

    private static func readGlobalDomain() -> [String: Any] {
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        let shared = CFPreferencesCopyMultiple(nil, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
        let host = CFPreferencesCopyMultiple(nil, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? [String: Any] ?? [:]
        return mergeGlobal(shared: shared, currentHost: host)
    }

    static func mergeGlobal(shared: [String: Any], currentHost: [String: Any]) -> [String: Any] {
        shared.merging(currentHost) { _, hostValue in hostValue }
    }

    private static func bluetoothTrackpadConnected() -> Bool {
        // Enumerating and reading properties needs no IOHIDManagerOpen; opening would make macOS
        // request Input Monitoring, which §6.2 forbids.
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return false }
        return devices.contains { device in
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
            guard transport == "Bluetooth" else { return false }
            let usagePage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue
            let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
            return usagePage == 0x0D || (product?.localizedCaseInsensitiveContains("Trackpad") ?? false)
        }
    }

    private static func bool(_ value: Any?) -> Bool? { (value as? NSNumber)?.boolValue }
    private static func number(_ value: Any?) -> NSNumber? { value as? NSNumber }
    private static func integer(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

    enum FixtureError: Error { case invalidPropertyList }
}
