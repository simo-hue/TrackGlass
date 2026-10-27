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
        catch { await state.updateDiscovery(macs: browser.macs, pairedMacs: []) }
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
            let connected = await session.connect(endpoint: mac.endpoint, mac: peer, hello: hello)
            if connected {
                await refreshState()
            } else {
                reconnectEnabled = false
            }
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
        reconnectEnabled = false
        reconnectTask?.cancel()
        reconnectTask = nil
        await session.disconnect()
        await refreshState()
    }

    func sceneDidEnterBackground() async {
        foreground = false
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
        // The session is known to be closed: always (re)start a loop; a finished loop's stale handle must not block it.
        if reconnectEnabled && foreground { startReconnectLoop() }
    }

    private func startReconnectLoop() {
        guard let peer = lastPeer, let hello = lastHello else { return }
        reconnectTask?.cancel()
        reconnectGeneration += 1
        let generation = reconnectGeneration
        reconnectTask = Task { [weak self] in
            var delay: UInt64 = 500_000_000
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard let self else { return }
                let connected = await self.reconnect(peer: peer, hello: hello)
                if connected { await self.reconnectSucceeded(generation); return }
                delay = min(delay * 2, 8_000_000_000)
            }
        }
    }

    private func reconnect(peer: PairedPeer, hello: HelloMessage) async -> Bool {
        if await session.isConnected { return true }
        guard foreground, reconnectEnabled,
              let mac = await browser.macs.first(where: { !$0.isPairing && $0.peerID == peer.peerID }) else { return false }
        return await session.connect(endpoint: mac.endpoint, mac: peer, hello: hello)
    }

    private func reconnectSucceeded(_ generation: Int) async {
        if generation == reconnectGeneration { reconnectTask = nil }
        await refreshState()
    }

    private func refreshState() async {
        let macs = await browser.macs
        let discoveryStatus = await browser.status
        let isConnected = await session.isConnected
        let status = await session.status
        let macName = await session.macName
        let rttMicros = await session.rttMicros
        let settings = await session.settings
        let diagnostics = await session.diagnostics
        let diagnosticsSequence = await session.diagnosticsSequence
        await state.updateDiscovery(macs: macs, pairedMacs: pairedMacs, status: discoveryStatus)
        await state.updateSession(isConnected: isConnected, status: status, macName: macName,
                                  rttMicros: rttMicros, settings: settings, diagnostics: diagnostics, diagnosticsSequence: diagnosticsSequence)
    }
}
