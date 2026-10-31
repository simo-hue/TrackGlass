import Foundation
import Network
import TrackglassKit

/// The `SessionClient` surface `ConnectionManager` drives; tests script it with a fake (L24).
@MainActor
protocol ConnectionSession: AnyObject, Sendable {
    var isConnected: Bool { get }
    var status: String { get }
    var lastCloseWasFinal: Bool { get }
    var inputPathWasReady: Bool { get }
    func snapshot() -> SessionClient.Snapshot
    func setCallbacks(connectionChanged: (@MainActor @Sendable () -> Void)?,
                      sessionClosed: (@MainActor @Sendable () -> Void)?)
    func connect(endpoint: NWEndpoint, mac: PairedPeer, hello: HelloMessage) async -> Bool
    func clearFinalClose()
    func updateSurface(_ value: SurfaceMessage)
    func setTrackingOverride(_ value: Float)
    func disconnect(reason: UInt8)
    func disconnectAndWait(reason: UInt8, timeout: Duration) async
}

/// The `MacBrowser` surface `ConnectionManager` drives (L24).
@MainActor
protocol MacDiscovery: AnyObject, Sendable {
    var macs: [DiscoveredMac] { get }
    var status: String { get }
    var localNetworkDenied: Bool { get }
    func start()
    func pause()
    func resume()
    func setOnChange(_ handler: (@MainActor @Sendable () -> Void)?)
}

/// The paired-Mac records `ConnectionManager` reads (the Keychain `PairingStore`; L24).
protocol PairedMacStore: Sendable {
    func load(peerID: UUID) throws -> PairedPeer?
    func all() throws -> [PairedPeer]
    func delete(peerID: UUID) throws
}

extension SessionClient: ConnectionSession {}
extension MacBrowser: MacDiscovery {}
extension PairingStore: PairedMacStore {}

actor ConnectionManager {
    private let browser: any MacDiscovery
    private let session: any ConnectionSession
    private let state: ConnectionState
    private let pairStore: any PairedMacStore
    private let defaults: UserDefaults
    /// The reconnect loop's waits, in nanoseconds (tests record them instead of waiting).
    private let sleep: @Sendable (UInt64) async throws -> Void
    private static let lastMacKey = "lastMacPeerID"
    /// §3.5: retries back off from 0.5 s to 8 s.
    static let firstDelay: UInt64 = 500_000_000
    static let maxDelay: UInt64 = 8_000_000_000
    /// What the panel shows once the loop gave up on an input path that never came up: "Touches couldn't reach…"
    /// with Reconnect (`ConnectionState.outcome`), whatever closed the last session (M1).
    static let inputPathStatus = "Input path lost"
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
    /// Consecutive reconnect rounds in which every listed instance of the last Mac refused the key at the TLS
    /// handshake ("Pair again").
    private var pairAgainFailures = 0
    /// The loop's next wait. It lives on the actor, not in one loop (M1): a session that ends before its input path
    /// came up counts as a failed attempt, so the backoff keeps growing across such sessions.
    private var reconnectDelay = ConnectionManager.firstDelay
    /// Consecutive sessions whose input path never came up (M1); the third stops the loop.
    private var inputPathFailures = 0
    /// When the current session connected. One that lasts `healthySession` resets the backoff like an input path that
    /// reached `.ready` does.
    private var connectedAt: ContinuousClock.Instant?
    private let healthySession: Duration
    /// The loop stopped after `inputPathFailures` reached three; cleared by the next attempt or Reconnect.
    private var stoppedForInputPath = false
    /// M2: the Bonjour instance of each Mac that last connected; it is tried first.
    private var lastInstance: [UUID: String] = [:]
    /// M2: shown instead of "Pair again" while a round has not shown that every listed instance of the Mac refuses
    /// the key (another instance failed otherwise, or is still to be tried).
    private var refusalStandIn: String?

    init(state: ConnectionState, browser: any MacDiscovery, session: any ConnectionSession,
         defaults: UserDefaults = .standard, pairStore: any PairedMacStore = PairingStore(),
         healthySession: Duration = .seconds(10),
         sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.state = state
        self.browser = browser
        self.session = session
        self.defaults = defaults
        self.pairStore = pairStore
        self.healthySession = healthySession
        self.sleep = sleep
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
        if reconnectTask == nil {
            // A fresh loop starts from the first delay with clean counters (an earlier input-path stop or refusals
            // must not shorten or slow this one), like the panel's Reconnect.
            pairAgainFailures = 0
            inputPathFailures = 0
            reconnectDelay = Self.firstDelay
            stoppedForInputPath = false
            startReconnectLoop()
        }
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
        inputPathFailures = 0
        reconnectDelay = Self.firstDelay
        stoppedForInputPath = false
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
            inputPathFailures = 0
            reconnectDelay = Self.firstDelay
            defaults.set(peer.peerID.uuidString, forKey: Self.lastMacKey)
            await state.updateLastMac(name: peer.name, peerID: peer.peerID)
            // Armed before the connect so a drop right after WELCOME is never missed by `connectionClosed`.
            reconnectEnabled = true
            // M2: the user chose a Mac, not one of the Bonjour records claiming its ID: every one is tried.
            let listed = await browser.macs
            let result = await attemptRound(candidates(for: peer.peerID, in: listed, including: mac), peer: peer, hello: hello)
            // Only the newest attempt decides: one superseded by another connect, a disconnect or the app going to
            // the background must not switch automatic reconnection off behind the user's back.
            guard result != .superseded else { return }
            if result == .connected {
                reconnectEnabled = true
            } else if wasRetryingThisMac, result != .finalAnswer {
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
        await session.disconnect(reason: 0)
        await refreshState()
    }

    func sceneDidEnterBackground() async {
        foreground = false
        connectGeneration += 1   // the attempt the background BYE interrupts must not decide reconnection
        reconnectTask?.cancel()
        reconnectTask = nil
        if await session.status.hasPrefix("Connecting to ") { reconnectEnabled = true }
        // Returns once the BYE has left (or after 1 s), so the caller's background task ends right after it.
        await session.disconnectAndWait(reason: 0, timeout: .seconds(1))
        await refreshState()
    }

    func sceneDidBecomeActive() async {
        foreground = true
        let connected = await session.isConnected
        if reconnectEnabled, reconnectTask == nil, !connected {
            reconnectDelay = Self.firstDelay   // back in the foreground: a fresh start (§7: reconnect within 2 s)
            startReconnectLoop()
        }
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
        let wasFinal = await session.lastCloseWasFinal
        let healthy = await sessionWasHealthy()
        connectedAt = nil
        // A Mac that forgot this phone (BYE unpaired), or speaks another protocol version, cannot be reached by retrying.
        if wasFinal { reconnectEnabled = false }
        // The session is known to be closed: always (re)start a loop; a finished loop's stale handle must not block it.
        else if reconnectEnabled && foreground {
            if healthy {
                reconnectDelay = Self.firstDelay
                inputPathFailures = 0
            } else {
                // M1: WELCOME came but touches never had a path (UDP blocked, the Mac's input service missing): that
                // was a failed attempt, not a lost session, so the backoff grows instead of starting over.
                inputPathFailures += 1
                backOff()
            }
            if inputPathFailures >= 3 {
                // Retrying cannot fix the network by itself: stop, and the panel says why and offers Reconnect.
                reconnectEnabled = false
                reconnectTask?.cancel()
                reconnectTask = nil
                stoppedForInputPath = true
            } else {
                startReconnectLoop()
            }
        }
        await refreshState()
    }

    /// The session that just closed had a working input path, or lasted `healthySession` (M1).
    private func sessionWasHealthy() async -> Bool {
        if await session.inputPathWasReady { return true }
        guard let connectedAt else { return false }
        return ContinuousClock.now - connectedAt >= healthySession
    }

    private func backOff() { reconnectDelay = min(reconnectDelay * 2, Self.maxDelay) }

    /// Every `session.connect` goes through here; `current` is false when a newer attempt (or a disconnect or the
    /// background BYE) has taken over meanwhile, in which case the result says nothing about this Mac.
    private func attempt(endpoint: NWEndpoint, peer: PairedPeer, hello: HelloMessage) async -> (connected: Bool, current: Bool) {
        connectGeneration += 1
        let generation = connectGeneration
        stoppedForInputPath = false
        let connected = await session.connect(endpoint: endpoint, mac: peer, hello: hello)
        return (connected, generation == connectGeneration)
    }

    private enum RoundResult { case connected, superseded, finalAnswer, refused, failed }

    /// M2: one try of every listed instance claiming the Mac's ID, in `candidates` order. A LAN host can advertise any
    /// `id`; only the TLS key proves the Mac, so one record refusing it says nothing about the others. `refused`:
    /// every instance refused the key; `finalAnswer`: the Mac itself answered (after TLS) that retrying cannot help.
    private func attemptRound(_ candidates: [DiscoveredMac], peer: PairedPeer, hello: HelloMessage) async -> RoundResult {
        guard !candidates.isEmpty else { return .failed }
        var otherFailure: String?
        var refusals = 0
        var generation = connectGeneration
        for (index, mac) in candidates.enumerated() {
            // Between instances a disconnect, the background, another connect or a cancelled loop takes over.
            if index > 0, generation != connectGeneration || Task.isCancelled || lastPeer?.peerID != peer.peerID {
                return .superseded
            }
            // Until the round is over a refusal is not "Pair again": another instance may still answer.
            refusalStandIn = otherFailure ?? "Connecting to \(peer.name)…"
            let (connected, current) = await attempt(endpoint: mac.endpoint, peer: peer, hello: hello)
            generation = connectGeneration
            if connected {
                refusalStandIn = nil
                lastInstance[peer.peerID] = mac.instanceName
                connectedAt = ContinuousClock.now
            }
            guard current else { return .superseded }
            if connected { return .connected }
            if await session.lastCloseWasFinal { refusalStandIn = nil; return .finalAnswer }
            let status = await session.status
            if status == ControlCloseMessage.pairAgain { refusals += 1 } else if otherFailure == nil { otherFailure = status }
        }
        refusalStandIn = otherFailure
        // The round's outcome, which the last attempt's own update showed as the stand-in.
        if refusals > 0 { await refreshState() }
        return otherFailure == nil ? .refused : .failed
    }

    /// M2: every listed session instance claiming the Mac's ID, the one that last connected first. `chosen` (the record
    /// the user picked) is kept even if the list changed since.
    private func candidates(for peerID: UUID, in macs: [DiscoveredMac], including chosen: DiscoveredMac? = nil) -> [DiscoveredMac] {
        var list = macs.filter { !$0.isPairing && $0.peerID == peerID }
        if let chosen, !list.contains(where: { $0.instanceName == chosen.instanceName }) { list.append(chosen) }
        if let preferred = lastInstance[peerID], let index = list.firstIndex(where: { $0.instanceName == preferred }) {
            list.insert(list.remove(at: index), at: 0)
        }
        return list
    }

    private enum ReconnectOutcome { case connected, notListed, failed, permanent }

    private func startReconnectLoop() {
        guard lastPeer != nil, lastHello != nil else { return }
        reconnectTask?.cancel()
        reconnectGeneration += 1
        let generation = reconnectGeneration
        let sleep = self.sleep
        reconnectTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.nextDelay() else { return }
                do { try await sleep(delay) } catch { return }
                guard let self else { return }
                let outcome = await self.reconnect()
                switch outcome {
                case .connected: await self.reconnectSucceeded(generation); return
                case .permanent: await self.reconnectStopped(generation); return
                case .notListed, .failed: await self.reconnectRetrying(after: outcome, generation: generation)
                }
            }
        }
    }

    private func nextDelay() async -> UInt64 { reconnectDelay }

    /// Looking the Mac up costs nothing: while it is not listed the loop checks every 0.5 s so it is joined as soon as
    /// it reappears (§7: reconnect within 2 s); it backs off only after real connection attempts.
    private func reconnectRetrying(after outcome: ReconnectOutcome, generation: Int) async {
        // A loop superseded meanwhile (a "try now", the background BYE) must not touch the shared backoff.
        guard generation == reconnectGeneration, !Task.isCancelled else { return }
        if outcome == .notListed { reconnectDelay = Self.firstDelay } else { backOff() }
    }

    /// Reads the current peer and HELLO on every attempt: a re-pair (new LTK) or a tracking-override change made
    /// while disconnected must reach the Mac with the next connection, not the values the loop started with.
    private func reconnect() async -> ReconnectOutcome {
        if await session.isConnected { return .connected }
        guard foreground, reconnectEnabled, let stored = lastPeer, let hello = lastHello else { return .failed }
        let listed = await browser.macs
        let macs = candidates(for: stored.peerID, in: listed)
        guard !macs.isEmpty else {
            pairAgainFailures = 0   // "three in a row" counts refusals from a Mac that stayed in range
            return .notListed
        }
        // A connect the user started during that await cancelled this loop and chose the Mac: leave it alone.
        guard !Task.isCancelled, lastPeer?.peerID == stored.peerID else { return .failed }
        let peer = (try? pairStore.load(peerID: stored.peerID)) ?? stored
        lastPeer = peer
        switch await attemptRound(macs, peer: peer, hello: hello) {
        case .connected:
            pairAgainFailures = 0
            return .connected
        case .superseded: return .failed
        case .finalAnswer: return .permanent
        // §3.2 "TLS handshake fails → Pair again": one refusal can be a Mac listener restarting with a new key set,
        // but a listed Mac refusing the key three times in a row has forgotten this phone (Forget while it was
        // away, a reinstall). Stop, so the panel offers pairing instead of retrying every 8 s forever. A round
        // counts only when every listed instance refused (M2): a decoy record cannot stand in for the Mac.
        case .refused:
            pairAgainFailures += 1
            return pairAgainFailures >= 3 ? .permanent : .failed
        case .failed:
            pairAgainFailures = 0
            return .failed
        }
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
        var snapshot = await session.snapshot()
        await updateBrowserDemand(connected: snapshot.isConnected)
        let macs = await browser.macs
        let discoveryStatus = await browser.status
        let localNetworkDenied = await browser.localNetworkDenied
        // Reconnection is wanted and still possible: the panel stays passive ("Reconnecting to …") meanwhile.
        let reconnecting = reconnectEnabled && lastPeer != nil && !snapshot.isConnected && !snapshot.lastCloseWasFinal
        // The outcome of the loop or round, not of its last attempt (M1, M2). A final answer always shows as it is.
        if !snapshot.isConnected, !snapshot.lastCloseWasFinal {
            if stoppedForInputPath {
                snapshot.status = Self.inputPathStatus
            } else if snapshot.status == ControlCloseMessage.pairAgain, let refusalStandIn {
                snapshot.status = refusalStandIn
            }
        }
        await state.updateDiscovery(macs: macs, pairedMacs: pairedMacs, status: discoveryStatus,
                                    localNetworkDenied: localNetworkDenied)
        await state.apply(snapshot, isReconnecting: reconnecting)
    }
}
