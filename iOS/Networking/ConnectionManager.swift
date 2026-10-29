import Foundation
import Network
import TrackglassKit

actor ConnectionManager {
    private let browser: MacBrowser
    private let session: SessionClient
    private let state: ConnectionState
    private let pairStore = PairingStore()
    private let defaults: UserDefaults
    private static let lastMacKey = "lastMacPeerID"
    private var pairedMacs: [PairedPeer] = []
    private var lastPeer: PairedPeer?
    private var lastHello: HelloMessage?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectGeneration = 0
    /// Bumped by every connect attempt, disconnect and background transition (see `attempt`).
    private var connectGeneration = 0
    private var reconnectEnabled = false
    private var foreground = true
    private var callbacksInstalled = false

    init(state: ConnectionState, browser: MacBrowser, session: SessionClient, defaults: UserDefaults = .standard) {
        self.state = state
        self.browser = browser
        self.session = session
        self.defaults = defaults
    }

    /// §3.5 / §5.9: the phone connects to the last used Mac by itself. Returns `false` when there is none
    /// (fresh install, or the last Mac was forgotten), in which case the caller offers discovery.
    func resumeLastMac(hello: HelloMessage) async -> Bool {
        await installCallbacks()
        await browser.start()
        // §5.1: Settings → Mac and the No-Mac overlay list every paired Mac from launch on, not only after the
        // Macs sheet has been opened once.
        await refreshPairedMacs()
        if lastPeer == nil, let stored = defaults.string(forKey: Self.lastMacKey), let id = UUID(uuidString: stored),
           let peer = try? pairStore.load(peerID: id) {
            lastPeer = peer
        }
        guard let peer = lastPeer else { return false }
        lastHello = hello
        await state.updateLastMac(name: peer.name)
        if await session.isConnected { return true }
        reconnectEnabled = true
        if reconnectTask == nil { startReconnectLoop() }
        await refreshState()
        return true
    }

    func startDiscovery() async {
        await installCallbacks()
        await browser.start()
        await refreshState()
    }

    func refreshPairedMacs() async {
        do { pairedMacs = try pairStore.all() }
        catch {
            pairedMacs = []
            await state.showNotice("Cannot read paired Macs: \(error.localizedDescription)")
        }
        await refreshState()
    }

    func connect(to mac: DiscoveredMac, hello: HelloMessage) async {
        await installCallbacks()
        await browser.start()
        do {
            guard let peer = try pairStore.load(peerID: mac.peerID) else {
                await state.updateSession(isConnected: false, status: "Pair again", macName: mac.name,
                                          rttMicros: 0, settings: nil)
                return
            }
            reconnectTask?.cancel()
            reconnectTask = nil
            lastPeer = peer
            lastHello = hello
            defaults.set(peer.peerID.uuidString, forKey: Self.lastMacKey)
            await state.updateLastMac(name: peer.name)
            // Armed before the connect so a drop right after WELCOME is never missed by `connectionClosed`.
            reconnectEnabled = true
            let (connected, current) = await attempt(endpoint: mac.endpoint, peer: peer, hello: hello)
            // Only the newest attempt decides: one superseded by another connect, a disconnect or the app going to
            // the background must not switch automatic reconnection off behind the user's back.
            guard current else { return }
            reconnectEnabled = connected
            if connected { await refreshState() }
        } catch {
            await state.updateSession(isConnected: false, status: "Cannot read paired Macs: \(error.localizedDescription)",
                                      macName: mac.name, rttMicros: 0, settings: nil)
        }
    }

    func updateSurface(_ surface: SurfaceMessage, hello: HelloMessage) async {
        lastHello = hello
        await session.updateSurface(surface)
        await refreshState()
    }

    func setTrackingOverride(_ value: Float) async {
        lastHello?.trackingOverride = value
        await session.setTrackingOverride(value)
    }

    func forget(_ peerID: UUID) async throws {
        try pairStore.delete(peerID: peerID)
        if lastPeer?.peerID == peerID {
            await disconnect()
            lastPeer = nil; lastHello = nil
            defaults.removeObject(forKey: Self.lastMacKey)
            await state.updateLastMac(name: "")
        }
        await refreshPairedMacs()
    }

    func disconnect() async {
        connectGeneration += 1
        reconnectEnabled = false
        reconnectTask?.cancel()
        reconnectTask = nil
        await session.disconnect()
        await refreshState()
    }

    func sceneDidEnterBackground() async {
        foreground = false
        connectGeneration += 1   // the attempt the background BYE interrupts must not decide reconnection
        reconnectTask?.cancel()
        reconnectTask = nil
        if await session.status.hasPrefix("Connecting to ") { reconnectEnabled = true }
        await session.disconnect(reason: 0)
        await refreshState()
    }

    func sceneDidBecomeActive() async {
        foreground = true
        let connected = await session.isConnected
        if reconnectEnabled, reconnectTask == nil, !connected { startReconnectLoop() }
        await refreshState()
    }

    private func installCallbacks() async {
        guard !callbacksInstalled else { return }
        callbacksInstalled = true
        await browser.setOnChange { [weak self] in
            Task { await self?.refreshState() }
        }
        await session.setCallbacks(connectionChanged: { [weak self] in
            Task { await self?.refreshState() }
        }, sessionClosed: { [weak self] in
            Task { await self?.connectionClosed() }
        })
    }

    private func connectionClosed() async {
        await refreshState()
        // A Mac that forgot this phone (BYE unpaired), or speaks another protocol version, cannot be reached by retrying.
        if await session.lastCloseWasFinal { reconnectEnabled = false; return }
        // The session is known to be closed: always (re)start a loop; a finished loop's stale handle must not block it.
        if reconnectEnabled && foreground { startReconnectLoop() }
    }

    /// Every `session.connect` goes through here; `current` is false when a newer attempt (or a disconnect or the
    /// background BYE) has taken over meanwhile, in which case the result says nothing about this Mac.
    private func attempt(endpoint: NWEndpoint, peer: PairedPeer, hello: HelloMessage) async -> (connected: Bool, current: Bool) {
        connectGeneration += 1
        let generation = connectGeneration
        let connected = await session.connect(endpoint: endpoint, mac: peer, hello: hello)
        return (connected, generation == connectGeneration)
    }

    private enum ReconnectOutcome { case connected, notListed, failed, permanent }

    private func startReconnectLoop() {
        guard lastPeer != nil, lastHello != nil else { return }
        reconnectTask?.cancel()
        reconnectGeneration += 1
        let generation = reconnectGeneration
        reconnectTask = Task { [weak self] in
            var delay: UInt64 = 500_000_000
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard let self else { return }
                switch await self.reconnect() {
                case .connected: await self.reconnectSucceeded(generation); return
                case .permanent: await self.reconnectStopped(generation); return
                // Looking the Mac up costs nothing: keep checking every 0.5 s so it is joined as soon as it
                // reappears (§7: reconnect within 2 s), and back off only after real connection attempts.
                case .notListed: delay = 500_000_000
                case .failed: delay = min(delay * 2, 8_000_000_000)
                }
            }
        }
    }

    /// Reads the current peer and HELLO on every attempt: a re-pair (new LTK) or a tracking-override change made
    /// while disconnected must reach the Mac with the next connection, not the values the loop started with.
    private func reconnect() async -> ReconnectOutcome {
        if await session.isConnected { return .connected }
        guard foreground, reconnectEnabled, let stored = lastPeer, let hello = lastHello else { return .failed }
        guard let mac = await browser.macs.first(where: { !$0.isPairing && $0.peerID == stored.peerID }) else { return .notListed }
        // A connect the user started during that await cancelled this loop and chose the Mac: leave it alone.
        guard !Task.isCancelled, lastPeer?.peerID == stored.peerID else { return .failed }
        let peer = (try? pairStore.load(peerID: stored.peerID)) ?? stored
        lastPeer = peer
        let (connected, current) = await attempt(endpoint: mac.endpoint, peer: peer, hello: hello)
        if connected { return .connected }
        if current, await session.lastCloseWasFinal { return .permanent }
        return .failed
    }

    private func reconnectSucceeded(_ generation: Int) async {
        if generation == reconnectGeneration { reconnectTask = nil }
        await refreshState()
    }

    private func reconnectStopped(_ generation: Int) async {
        reconnectEnabled = false
        if generation == reconnectGeneration { reconnectTask = nil }
        await refreshState()
    }

    private func refreshState() async {
        let macs = await browser.macs
        let discoveryStatus = await browser.status
        // One hop for the whole session state; `apply` drops a snapshot overtaken by a newer one.
        let snapshot = await session.snapshot()
        await state.updateDiscovery(macs: macs, pairedMacs: pairedMacs, status: discoveryStatus)
        await state.apply(snapshot)
    }
}
