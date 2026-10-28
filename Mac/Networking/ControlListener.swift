import Foundation
import Network
import Observation
import OSLog
import TrackglassKit
import TrackglassEngine

@MainActor @Observable
final class ControlListener {
    private(set) var sessionActive = true
    private(set) var status = "No phone connected"
    let coordinator = SessionCoordinator()
    var inputIdentityChanged: ((UUID?, EngineGeometry?) -> Void)?
    var inputGeometryChanged: ((EngineGeometry) -> Void)?
    var inputSettingsChanged: ((TrackpadSettings) -> Void)?
    private let identity: PeerIdentity
    private let store: PairingStore
    private let preferences = TrackpadPreferences()
    private(set) var trackingOverride: Double = 0
    /// Most recent STATUS sent to the admitted phone; shown in Settings → Advanced (M10.1).
    private(set) var lastStatus: StatusMessage?
    var currentTrackingSpeed: Double { trackpadSettings.trackingSpeed }
    private var trackpadSettings = TrackpadSettings()
    private var channels: [UUID: ControlChannel] = [:]
    private var rttByChannel: [UUID: UInt32] = [:]
    private var admitted: [UUID: UUID] = [:]
    private var generation = UUID()
    private let logger = Logger(subsystem: "app.trackglass.mac", category: "net")
    // Appendix A defaults until TrackpadPreferences is introduced in M4.4.
    static let defaultSettings = SettingsMessage(naturalScrolling: 1, tapToClick: 1,
        forceClickEnabled: 1, hapticsSuggested: 1, trackingSpeed: 0.6875, secondaryClickMode: 1)

    /// Hosted tests keep the Appendix A defaults; the app reads the Mac's real preferences.
    private let livePreferences = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil

    init(identity: PeerIdentity, store: PairingStore = PairingStore()) {
        self.identity = identity
        self.store = store
        preferences.onChange = { [weak self] settings in
            Task { @MainActor [weak self] in self?.apply(settings) }
        }
        if livePreferences { preferences.start() }
    }

    func sendStatus(_ message: StatusMessage, to peerID: UUID) {
        for (channelID, admittedPeer) in admitted where admittedPeer == peerID {
            var message = message
            message.rttMicros = rttByChannel[channelID] ?? 0
            lastStatus = message
            channels[channelID]?.send(.status(message))
        }
    }

    func sendHaptic(_ kind: HapticKind, to peerID: UUID) {
        let code: UInt8
        switch kind {
        case .click: code = 1
        case .secondaryClick: code = 2
        case .forceClickStage2: code = 3
        case .dragLockEngaged: code = 4
        case .dragLockReleased: code = 5
        case .spaceSwitched: code = 6
        }
        for (channelID, admittedPeer) in admitted where admittedPeer == peerID {
            channels[channelID]?.send(.haptic(HapticMessage(kind: code, intensity: 255)))
        }
    }

    func accept(_ connection: NWConnection) {
        let id = UUID()
        let channel = ControlChannel(connection: connection)
        channels[id] = channel
        channel.onMessage = { [weak self, weak channel] packet in
            guard let self, let channel, self.channels[id] === channel else { return }
            switch packet.message {
            case .hello(let hello):
                guard self.admitted[id] == nil else { channel.end(reason: 1); return }
                guard hello.protocolVersion == 1 else { channel.end(reason: 1); return }
                do {
                    guard try self.store.load(peerID: hello.peerID) != nil else {
                        channel.end(reason: 3, message: "Pair again"); return
                    }
                    guard self.sessionActive else {
                        channel.send(.welcome(WelcomeMessage(status: 1, macPeerID: self.identity.peerID,
                            macName: self.identity.name, macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                            injectorMode: 1, settings: Self.message(for: self.trackpadSettings), activePhoneName: "another macOS user session")))
                        channel.end(reason: 2); return
                    }
                    let generation = self.generation
                    // §6.4: read the Mac's preferences immediately on session start, so WELCOME and the
                    // engine's first snapshot never lag a change made inside the last 2 s poll interval.
                    if self.livePreferences { self.trackpadSettings = self.preferences.readNow() }
                    // The same phone reconnecting (Wi-Fi blip, app relaunch) supersedes its stale session
                    // instead of waiting for the heartbeat timeout and being told it is busy with itself.
                    if let stale = self.admitted.first(where: { $0.value == hello.peerID })?.key, stale != id {
                        self.admitted.removeValue(forKey: stale)
                        await self.coordinator.release(id: stale)
                        self.channels[stale]?.end(reason: 0, message: "Superseded by a reconnect")
                    }
                    let busyName = await self.coordinator.admit(id: id, peer: hello)
                    guard self.channels[id] === channel, generation == self.generation else {
                        await self.coordinator.release(id: id); channel.close("Pairing changed"); return
                    }
                    let welcome = WelcomeMessage(status: busyName == nil ? 0 : 1,
                        macPeerID: self.identity.peerID, macName: self.identity.name,
                        macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                        injectorMode: 1, settings: Self.message(for: self.trackpadSettings), activePhoneName: busyName ?? "")
                    if busyName != nil { channel.send(.welcome(welcome)); channel.end(reason: 2); return }
                    self.admitted[id] = hello.peerID
                    // Input listener first, WELCOME second: the phone resolves `_trackglass._udp` as soon as it reads WELCOME.
                    self.inputIdentityChanged?(hello.peerID, EngineGeometry(widthMM: Double(hello.surfaceWidthMM), heightMM: Double(hello.surfaceHeightMM), isLandscape: hello.surfaceWidthMM > hello.surfaceHeightMM))
                    self.trackingOverride = Double(hello.trackingOverride)
                    self.inputSettingsChanged?(Self.effectiveSettings(self.trackpadSettings, override: self.trackingOverride))
                    self.status = "Connected to \(hello.name)"
                    channel.send(.welcome(welcome))
                    channel.startHeartbeat()
                } catch { channel.close("Cannot read paired devices") }
            case .surface(let surface):
                guard self.admitted[id] != nil else { channel.end(reason: 1); return }
                await self.coordinator.updateSurface(id: id, surface: surface)
                self.trackingOverride = Double(surface.trackingOverride)
                self.inputSettingsChanged?(Self.effectiveSettings(self.trackpadSettings, override: self.trackingOverride))
                self.inputGeometryChanged?(EngineGeometry(widthMM: Double(surface.surfaceWidthMM), heightMM: Double(surface.surfaceHeightMM), isLandscape: surface.surfaceWidthMM > surface.surfaceHeightMM))
                self.logger.info("SURFACE widthMM=\(surface.surfaceWidthMM) heightMM=\(surface.surfaceHeightMM) ppi=\(surface.ppi) override=\(surface.trackingOverride)")
            default: channel.end(reason: 1)
            }
        }
        channel.onRTT = { [weak self] rtt in self?.rttByChannel[id] = rtt }
        channel.onClose = { [weak self] _ in
            guard let self else { return }
            self.channels.removeValue(forKey: id)
            self.rttByChannel.removeValue(forKey: id)
            if self.admitted.removeValue(forKey: id) != nil {
                self.status = "No phone connected"
                self.trackingOverride = 0
                self.lastStatus = nil
                self.inputIdentityChanged?(nil, nil)
            }
            Task { await self.coordinator.release(id: id) }
        }
        channel.start()
    }

    func stop() {
        generation = UUID()
        preferences.stop()
        for channel in Array(channels.values) { channel.close() }
    }

    func setSessionActive(_ active: Bool) {
        sessionActive = active
        if !active {
            generation = UUID()
            for channel in Array(channels.values) { channel.end(reason: 2, message: "Mac user session is inactive") }
        }
    }

    func prepareForSleep() { endAllSessions(reason: 4, message: "Mac sleeping") }

    /// §8.5: Accessibility was revoked while connected — every session ends with a user-reason BYE.
    func permissionRevoked() { endAllSessions(reason: 0, message: "Accessibility permission revoked") }

    private func endAllSessions(reason: UInt8, message: String) {
        generation = UUID()
        for (id, channel) in channels {
            if admitted[id] != nil { channel.end(reason: reason, message: message) }
            else { channel.close(message) }
        }
    }

    func forget(_ peerID: UUID) throws {
        try store.delete(peerID: peerID)
        generation = UUID()
        for (id, channel) in channels {
            if admitted[id] == peerID { channel.end(reason: 3, message: "Pair again") }
            // A handshake-complete channel that has not sent HELLO yet cannot be attributed to a peer
            // (Network.framework hides the PSK identity); drop it so a forgotten phone cannot keep it.
            else if admitted[id] == nil { channel.close("Pairing changed") }
        }
    }

    private func apply(_ settings: TrackpadSettings) {
        trackpadSettings = settings
        inputSettingsChanged?(Self.effectiveSettings(settings, override: trackingOverride))
        for (id, channel) in channels where admitted[id] != nil { channel.send(.settings(Self.message(for: settings))) }
        logger.info("settings snapshot updated")
    }

    nonisolated static func effectiveSettings(_ settings: TrackpadSettings, override: Double) -> TrackpadSettings {
        var effective = settings
        let offset = override.isFinite ? min(1, max(-1, override)) : 0
        effective.trackingSpeed = min(3, max(0, settings.trackingSpeed + offset))
        return effective
    }

    nonisolated static func message(for settings: TrackpadSettings) -> SettingsMessage {
        let secondary: UInt8
        if settings.trackpadRightClick { secondary = 1 }
        else if settings.cornerSecondaryClick == 2 { secondary = 2 }
        else if settings.cornerSecondaryClick == 1 { secondary = 3 }
        else { secondary = 0 }
        return SettingsMessage(naturalScrolling: settings.naturalScrolling ? 1 : 0,
            tapToClick: settings.clicking ? 1 : 0,
            forceClickEnabled: settings.forceClickEnabled ? 1 : 0,
            hapticsSuggested: 1, trackingSpeed: Float(settings.trackingSpeed), secondaryClickMode: secondary,
            scrollEnabled: settings.scrollEnabled ? 1 : 0,
            horizontalScrollEnabled: settings.horizontalScrollEnabled ? 1 : 0,
            momentumScrollEnabled: settings.momentumScrollEnabled ? 1 : 0,
            pinchEnabled: settings.pinchEnabled ? 1 : 0,
            rotateEnabled: settings.rotateEnabled ? 1 : 0,
            smartZoomEnabled: settings.smartZoomEnabled ? 1 : 0,
            swipeNavigationEnabled: settings.swipeNavigationEnabled ? 1 : 0)
    }
}
