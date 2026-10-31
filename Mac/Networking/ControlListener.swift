import Foundation
import Network
import Observation
import OSLog
import TrackglassKit
import TrackglassEngine

@MainActor @Observable
final class ControlListener {
    private(set) var sessionActive = true
    /// Set once the app is quitting (`endAllSessionsForQuit`): no new session is admitted after that.
    private var quitting = false
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
    /// M3: channels that have not sent HELLO yet, oldest first. Anyone on the LAN can open them (TLS not even done),
    /// so they are bounded like the pairing listener's slot and the input listener's flows: at most
    /// `maximumAwaitingHello` at a time, each closed `helloTimeout` after it was accepted.
    private var awaitingHello: [UUID] = []
    static let maximumAwaitingHello = 16
    /// The phone sends HELLO as soon as its TLS handshake completes. Tests shorten it.
    var helloTimeout: Duration = .seconds(3)
    /// Connections waiting for HELLO (tests).
    var awaitingHelloCount: Int { awaitingHello.count }
    private var loggedConnectionLimit = false
    /// L8b / L9: what was already logged per channel, so a peer repeating it cannot flood the log.
    private var channelNotices: [UUID: Set<String>] = [:]
    /// The admitted phone, marked in the menu and the Devices tab (§6.1).
    var connectedPeerID: UUID? { admitted.values.first }
    /// Open control channels (the quit path waits for their BYEs to go out).
    var openChannelCount: Int { channels.count }
    private var generation = UUID()
    private let logger = Logger(subsystem: "app.trackglass.mac", category: "net")
    /// A session that has received nothing for this long (both sides PING every second) is a stale one the same
    /// phone may supersede; one that is still talking is live and is never ended by another HELLO.
    static let staleSessionSilenceNs: UInt64 = 1_500_000_000
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
        // §6.4 polling runs only while a phone is admitted (see `admit`); one read now fills Settings.
        if livePreferences { preferences.pollOnce() }
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
        // M3: full means a flood (a phone sends HELLO within one round trip of its TLS handshake). The newest pending
        // connection, this one, is refused, so a handshake already in progress survives; every slot frees itself
        // within `helloTimeout`.
        guard awaitingHello.count < Self.maximumAwaitingHello else {
            if !loggedConnectionLimit {
                loggedConnectionLimit = true
                logger.error("too many control connections without HELLO; refusing new ones until they time out")
            }
            connection.cancel()
            return
        }
        loggedConnectionLimit = false   // the next flood is logged again
        let id = UUID()
        let channel = ControlChannel(connection: connection)
        channels[id] = channel
        awaitingHello.append(id)
        channel.onMessage = { [weak self, weak channel] packet in
            guard let self, let channel, self.channels[id] === channel else { return }
            switch packet.message {
            case .hello(let hello):
                // A second HELLO on a channel is a known message this side does not expect: ignored (L8b).
                guard let pending = self.awaitingHello.firstIndex(of: id) else {
                    self.noteOnce("ignored a repeated HELLO", channel: id); return
                }
                self.awaitingHello.remove(at: pending)
                guard !self.quitting else { channel.end(reason: 0, message: "Trackglass for Mac quit"); return }
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
                    // engine's first snapshot never lag a change made inside the last 2 s poll interval. A change
                    // found here is applied like a polled one: the session already running (this HELLO may be
                    // turned away as busy) gets its SETTINGS and its engine the new snapshot.
                    if self.livePreferences {
                        let fresh = self.preferences.readNow()
                        if fresh != self.trackpadSettings { self.apply(fresh) }
                    }
                    // The same phone reconnecting (Wi-Fi blip, app relaunch) supersedes its stale session
                    // instead of waiting for the heartbeat timeout and being told it is busy with itself. A session
                    // that is still talking is not stale: a HELLO cannot prove which paired phone sent it (no
                    // public API exposes the negotiated PSK identity), so it never ends a live session (§3.5).
                    var supersededStale = false
                    if let stale = self.admitted.first(where: { $0.value == hello.peerID })?.key, stale != id,
                       let staleChannel = self.channels[stale],
                       MonotonicClock.nanoseconds() &- staleChannel.lastReceivedAt >= Self.staleSessionSilenceNs {
                        self.admitted.removeValue(forKey: stale)
                        self.admittedChanged()
                        supersededStale = true
                        await self.coordinator.release(id: stale)
                        staleChannel.end(reason: 0, message: "Superseded by a reconnect")
                    }
                    let busyName = await self.coordinator.admit(id: id, peer: hello)
                    // Busy with this very phone (its previous session has not gone silent long enough to be superseded):
                    // an empty `activePhoneName` tells it so, and it keeps retrying quietly (§4.5, 2026-10-29). Names
                    // cannot tell two phones apart (two "iPhone 15"s); peer IDs can.
                    var busyWithItself = false
                    if busyName != nil { busyWithItself = await self.coordinator.activeSession?.peer.peerID == hello.peerID }
                    guard self.channels[id] === channel, generation == self.generation, !self.quitting else {
                        await self.coordinator.release(id: id); channel.close("Pairing changed")
                        // The stale session's input side was left for this admission to replace; nothing will now.
                        if supersededStale, self.admitted.isEmpty { self.resetAdmittedState() }
                        return
                    }
                    let welcome = WelcomeMessage(status: busyName == nil ? 0 : 1,
                        macPeerID: self.identity.peerID, macName: self.identity.name,
                        macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                        injectorMode: 1, settings: Self.message(for: self.trackpadSettings),
                        activePhoneName: busyWithItself ? "" : busyName ?? "")
                    if busyName != nil { channel.send(.welcome(welcome)); channel.end(reason: 2); return }
                    self.admitted[id] = hello.peerID
                    self.admittedChanged()
                    // Input listener first, WELCOME second: the phone resolves `_trackglass._udp` as soon as it reads WELCOME.
                    self.inputIdentityChanged?(hello.peerID, EngineGeometry(widthMM: Double(hello.surfaceWidthMM), heightMM: Double(hello.surfaceHeightMM), isLandscape: hello.surfaceWidthMM > hello.surfaceHeightMM))
                    self.trackingOverride = Double(hello.trackingOverride)
                    self.inputSettingsChanged?(Self.effectiveSettings(self.trackpadSettings, override: self.trackingOverride))
                    self.status = "Connected to \(hello.name)"
                    channel.send(.welcome(welcome))
                    channel.startHeartbeat()
                } catch { channel.close("Cannot read paired devices") }
            case .surface(let surface):
                guard self.admitted[id] != nil else { self.noteOnce("ignored SURFACE before admission", channel: id); return }
                // L9 / C3: one bad layout pass on the phone must not end the session (BYE 1 is final for the phone).
                // The previous geometry stays.
                guard surface.surfaceWidthMM.isFinite, surface.surfaceHeightMM.isFinite,
                      surface.surfaceWidthMM > 0, surface.surfaceHeightMM > 0 else {
                    self.noteOnce("ignored SURFACE with an invalid size", channel: id); return
                }
                await self.coordinator.updateSurface(id: id, surface: surface)
                self.trackingOverride = Double(surface.trackingOverride)
                self.inputSettingsChanged?(Self.effectiveSettings(self.trackpadSettings, override: self.trackingOverride))
                self.inputGeometryChanged?(EngineGeometry(widthMM: Double(surface.surfaceWidthMM), heightMM: Double(surface.surfaceHeightMM), isLandscape: surface.surfaceWidthMM > surface.surfaceHeightMM))
                self.logger.info("SURFACE widthMM=\(surface.surfaceWidthMM) heightMM=\(surface.surfaceHeightMM) ppi=\(surface.ppi) override=\(surface.trackingOverride)")
            default:
                // L8b (§4.1): a known type this side does not expect here (a newer phone's message, a pairing message
                // on a session channel) is ignored like an unknown one, never answered with the final BYE 1.
                self.noteOnce("ignored unexpected control message type \(packet.header.type)", channel: id)
            }
        }
        channel.onRTT = { [weak self] rtt in self?.rttByChannel[id] = rtt }
        channel.onClose = { [weak self] _ in
            guard let self else { return }
            self.channels.removeValue(forKey: id)
            self.rttByChannel.removeValue(forKey: id)
            self.awaitingHello.removeAll { $0 == id }
            self.channelNotices.removeValue(forKey: id)
            if self.admitted.removeValue(forKey: id) != nil { self.resetAdmittedState() }
            Task { await self.coordinator.release(id: id) }
        }
        channel.start()
        let timeout = helloTimeout
        Task { @MainActor [weak self, weak channel] in
            try? await Task.sleep(for: timeout)
            guard let self, let channel, self.channels[id] === channel, self.awaitingHello.contains(id) else { return }
            channel.close("No HELLO in time")
        }
    }

    private func noteOnce(_ notice: String, channel id: UUID) {
        guard channelNotices[id, default: []].insert(notice).inserted else { return }
        logger.info("\(notice, privacy: .public)")
    }

    /// No phone is admitted any more: the input side, the status line and the preference poller follow.
    private func resetAdmittedState() {
        status = "No phone connected"
        trackingOverride = 0
        lastStatus = nil
        inputIdentityChanged?(nil, nil)
        admittedChanged()
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

    /// §6.4 polling runs only while a phone is admitted: every change to `admitted` goes through here.
    private func admittedChanged() {
        guard livePreferences else { return }
        if admitted.isEmpty { preferences.stop() } else { preferences.start() }
    }

    func prepareForSleep() { endAllSessions(reason: 4, message: "Mac sleeping") }

    /// The app is quitting (menu, logout, Sparkle relaunch): every phone gets a user BYE, and a phone whose HELLO
    /// arrives during the short wait before exit is turned away the same way instead of being admitted (§6.1).
    func endAllSessionsForQuit() {
        quitting = true
        endAllSessions(reason: 0, message: "Trackglass for Mac quit")
    }

    /// Menu / Devices "Disconnect" (§6.1): BYE reason 5, which the phone treats as final — it stops reconnecting by
    /// itself until its user taps Reconnect (§4.5).
    func disconnect(peerID: UUID) {
        for (id, admittedPeer) in admitted where admittedPeer == peerID {
            channels[id]?.end(reason: 5, message: ControlCloseMessage.disconnectedOnMac)
        }
    }

    /// The admitted phone's datagrams stopped while its control channel lives on (`InputListener`): end the session
    /// with BYE so the phone's reconnect loop rebuilds both channels (§8).
    func inputPathDied(peerID: UUID) {
        for (id, admittedPeer) in admitted where admittedPeer == peerID {
            channels[id]?.end(reason: 0, message: "Input path lost")
        }
    }

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
            // L3 (§3.5): a HELLO cannot prove which paired phone sent it, so a session admitted under another ID may be
            // the forgotten phone posing as it. It ends too, with a BYE that is not final: a phone that is still paired
            // reconnects by itself (the control listener restarts with the remaining keys), the forgotten one cannot.
            else if admitted[id] != nil { channel.end(reason: 0, message: "Pairing changed") }
            // A handshake-complete channel that has not sent HELLO yet cannot be attributed to a peer
            // (Network.framework hides the PSK identity); drop it so a forgotten phone cannot keep it.
            else { channel.close("Pairing changed") }
        }
    }

    /// L15: Settings shows the Mac's tracking speed; with no phone admitted nothing polls (§6.4), so the window asks
    /// for one read when it opens. The read runs on the preferences queue; a change arrives through `onChange`.
    func refreshPreferences() {
        guard livePreferences, admitted.isEmpty else { return }
        preferences.pollOnce()
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
