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
    /// Discovery has been asked for once (launch resume, the Macs sheet, a connect); from then on the browser runs
    /// whenever it is needed: no session, or a Macs list on screen.
    private var discoveryActive = false
    /// Macs lists currently on screen (the Macs sheet, Settings → Mac); each keeps the browser running.
    private var discoveryViewers: Set<UUID> = []
    /// Consecutive reconnect attempts the listed last Mac refused at the TLS handshake ("Pair again").
    private var pairAgainFailures = 0

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
        await startBrowser()
        // §5.1: Settings → Mac and the No-Mac overlay list every paired Mac from launch on, not only after the
        // Macs sheet has been opened once.
        await refreshPairedMacs()
        if lastPeer == nil, let stored = defaults.string(forKey: Self.lastMacKey), let id = UUID(uuidString: stored),
           let peer = try? pairStore.load(peerID: id) {
            lastPeer = peer
        }
        guard let peer = lastPeer else { return false }
        lastHello = hello
        await state.updateLastMac(name: peer.name, peerID: peer.peerID)
        if await session.isConnected { return true }
        reconnectEnabled = true
        if reconnectTask == nil { startReconnectLoop() }
        await refreshState()
        return true
    }

    func startDiscovery() async {
        await installCallbacks()
        await startBrowser()
        await refreshState()
    }

    /// perf: `_trackglass._tcp` browsing is multicast traffic; while a session is up it only runs for a Macs list
    /// on screen. `visible` is reported by each list's appear/disappear.
    func setDiscoveryVisible(_ visible: Bool, viewer: UUID) async {
        if visible { discoveryViewers.insert(viewer) } else { discoveryViewers.remove(viewer) }
        await updateBrowserDemand(connected: session.isConnected)
    }

    /// The No-Mac panel's Reconnect: re-arms automatic reconnection to the last Mac after it stopped (a failed
    /// manual connect, a user disconnect).
    func reconnectNow(hello: HelloMessage) async {
        await installCallbacks()
        await startBrowser()
        if lastPeer == nil, let stored = defaults.string(forKey: Self.lastMacKey), let id = UUID(uuidString: stored),
           let peer = try? pairStore.load(peerID: id) {
            lastPeer = peer
        }
        guard lastPeer != nil, !(await session.isConnected) else { return }
        lastHello = hello
        reconnectEnabled = true
        pairAgainFailures = 0
        // The user asked: the previous final answer (BYE unpaired / disconnected on the Mac) no longer stands.
        await session.clearFinalClose()
        startReconnectLoop()
        await refreshState()
    }

    private func startBrowser() async {
        discoveryActive = true
        await browser.start()
    }

    private func updateBrowserDemand(connected: Bool) async {
        guard discoveryActive else { return }
        // Not in the background (no multicast before suspension; `sceneDidBecomeActive` resumes it), not while a
        // session is up and nobody looks at the list. `resume`, not `start`: a failed browser restarts on its own
        // 1 s schedule instead of in a tight loop driven by its own status change.
        if !foreground || (connected && discoveryViewers.isEmpty) { await browser.pause() } else { await browser.resume() }
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
        await startBrowser()
        do {
            guard let peer = try pairStore.load(peerID: mac.peerID) else {
                await state.updateSession(isConnected: false, status: "Pair again", macName: mac.name,
                                          rttMicros: 0, settings: nil)
                return
            }
            // Connect on the Mac the loop is already retrying (busy elsewhere, waking up) is a "try now", not a new
            // choice: when it fails without a final answer the loop carries on (§3.5).
            let wasRetryingThisMac = reconnectEnabled && lastPeer?.peerID == peer.peerID
            reconnectTask?.cancel()
            reconnectTask = nil
            lastPeer = peer
            lastHello = hello
            pairAgainFailures = 0
            defaults.set(peer.peerID.uuidString, forKey: Self.lastMacKey)
            await state.updateLastMac(name: peer.name, peerID: peer.peerID)
            // Armed before the connect so a drop right after WELCOME is never missed by `connectionClosed`.
            reconnectEnabled = true
            let (connected, current) = await attempt(endpoint: mac.endpoint, peer: peer, hello: hello)
            // Only the newest attempt decides: one superseded by another connect, a disconnect or the app going to
            // the background must not switch automatic reconnection off behind the user's back.
            guard current else { return }
            if connected {
                reconnectEnabled = true
            } else if wasRetryingThisMac, !(await session.lastCloseWasFinal) {
                reconnectEnabled = true
                startReconnectLoop()
            } else {
                reconnectEnabled = false
            }
            await refreshState()   // also after a failure: the panel stops showing "Reconnecting" and offers Reconnect
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
            await state.updateLastMac(name: "", peerID: nil)
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
        // Returns once the BYE has left (or after 1 s), so the caller's background task ends right after it.
        await session.disconnectAndWait(reason: 0)
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
        // A Mac that forgot this phone (BYE unpaired), or speaks another protocol version, cannot be reached by retrying.
        if await session.lastCloseWasFinal { reconnectEnabled = false }
        // The session is known to be closed: always (re)start a loop; a finished loop's stale handle must not block it.
        else if reconnectEnabled && foreground { startReconnectLoop() }
        await refreshState()
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
        guard let mac = await browser.macs.first(where: { !$0.isPairing && $0.peerID == stored.peerID }) else {
            pairAgainFailures = 0   // "three in a row" counts refusals from a Mac that stayed in range
            return .notListed
        }
        // A connect the user started during that await cancelled this loop and chose the Mac: leave it alone.
        guard !Task.isCancelled, lastPeer?.peerID == stored.peerID else { return .failed }
        let peer = (try? pairStore.load(peerID: stored.peerID)) ?? stored
        lastPeer = peer
        let (connected, current) = await attempt(endpoint: mac.endpoint, peer: peer, hello: hello)
        if connected { pairAgainFailures = 0; return .connected }
        guard current else { return .failed }
        if await session.lastCloseWasFinal { return .permanent }
        // §3.2 "TLS handshake fails → Pair again": one refusal can be a Mac listener restarting with a new key set,
        // but a listed Mac refusing the key three times in a row has forgotten this phone (Forget while it was
        // away, a reinstall). Stop, so the panel offers pairing instead of retrying every 8 s forever.
        if await session.status == ControlCloseMessage.pairAgain {
            pairAgainFailures += 1
            if pairAgainFailures >= 3 { return .permanent }
        } else {
            pairAgainFailures = 0
        }
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
        // One hop for the whole session state; `apply` drops a snapshot overtaken by a newer one.
        let snapshot = await session.snapshot()
        await updateBrowserDemand(connected: snapshot.isConnected)
        let macs = await browser.macs
        let discoveryStatus = await browser.status
        let localNetworkDenied = await browser.localNetworkDenied
        // Reconnection is wanted and still possible: the panel stays passive ("Reconnecting to …") meanwhile.
        let reconnecting = reconnectEnabled && lastPeer != nil && !snapshot.isConnected && !snapshot.lastCloseWasFinal
        await state.updateDiscovery(macs: macs, pairedMacs: pairedMacs, status: discoveryStatus,
                                    localNetworkDenied: localNetworkDenied)
        await state.apply(snapshot, isReconnecting: reconnecting)
    }
}
