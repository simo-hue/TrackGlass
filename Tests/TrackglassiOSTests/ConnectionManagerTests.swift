import Network
import TrackglassKit
import XCTest
@testable import TrackglassiOS

/// Drives `ConnectionManager`'s reconnect loop with a scripted session and browser (L24). The loop's waits are
/// recorded, not slept, so the backoff is checked exactly.
final class ConnectionManagerTests: XCTestCase {
    private static let half = ConnectionManager.firstDelay
    private static let second: UInt64 = 1_000_000_000

    /// M1: WELCOME every time but the input path never comes up. The backoff grows across those sessions, and the
    /// third one stops the loop with "Touches couldn't reach…" and Reconnect instead of "Connected" every 5.5 s.
    @MainActor func testInputPathThatNeverComesUpBacksOffAndStopsAfterThreeSessions() async throws {
        let rig = try Rig(instances: ["Studio"])
        defer { rig.finish() }
        rig.session.answers = ["Studio": .welcome]
        await rig.manager.connect(to: rig.browser.macs[0], hello: rig.hello)
        XCTAssertTrue(rig.session.isConnected)
        for session in 1...3 {
            rig.session.endSession("Mac input service not found")
            if session < 3 { try await eventually { rig.session.attempts.count == session + 1 && rig.session.isConnected } }
        }
        try await eventually { rig.state.status == ConnectionManager.inputPathStatus && !rig.state.isReconnecting }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(rig.session.attempts.count, 3, "no fourth session")
        let waits = await rig.sleeps.requested
        XCTAssertEqual(waits, [Self.second, 2 * Self.second], "the backoff survives each session")
        XCTAssertEqual(ConnectionState.outcome(for: rig.state.status, macName: "Studio"),
                       "Touches couldn't reach Studio. Make sure both devices are on the same Wi-Fi network, then reconnect.")
        XCTAssertEqual(ConnectionState.panelAction(for: rig.state.status), .reconnect)

        await rig.manager.reconnectNow(hello: rig.hello)   // the panel's Reconnect starts over
        try await eventually { rig.session.attempts.count == 4 && rig.session.isConnected }
        let restarted = await rig.sleeps.requested
        XCTAssertEqual(restarted.last, Self.half)
        try await eventually { rig.state.isConnected }
        await rig.manager.disconnect()
    }

    /// M1: a session whose input path came up was healthy: the next loss starts over at 0.5 s, and earlier input
    /// failures no longer count towards the three.
    @MainActor func testHealthySessionResetsTheBackoffAndTheCount() async throws {
        let rig = try Rig(instances: ["Studio"])
        defer { rig.finish() }
        rig.session.answers = ["Studio": .welcome]
        await rig.manager.connect(to: rig.browser.macs[0], hello: rig.hello)
        rig.session.endSession("Mac input service not found")
        try await eventually { rig.session.attempts.count == 2 && rig.session.isConnected }
        rig.session.endSession("Connection lost", inputPathWasReady: true)
        try await eventually { rig.session.attempts.count == 3 && rig.session.isConnected }
        for attempts in 4...5 {
            rig.session.endSession("Input connection stalled")
            try await eventually { rig.session.attempts.count == attempts && rig.session.isConnected }
        }
        let waits = await rig.sleeps.requested
        XCTAssertEqual(waits, [Self.second, Self.half, Self.second, 2 * Self.second])
        await rig.manager.disconnect()
    }

    /// M1: a session that lasted the healthy duration counts as healthy even without news from the input path.
    @MainActor func testSessionThatLastedIsHealthy() async throws {
        let rig = try Rig(instances: ["Studio"], healthySession: .zero)
        defer { rig.finish() }
        rig.session.answers = ["Studio": .welcome]
        await rig.manager.connect(to: rig.browser.macs[0], hello: rig.hello)
        rig.session.endSession("Connection lost")
        try await eventually { rig.session.attempts.count == 2 && rig.session.isConnected }
        let waits = await rig.sleeps.requested
        XCTAssertEqual(waits, [Self.half])
        await rig.manager.disconnect()
    }

    /// M2: a record that sorts first and refuses the key does not keep the phone from the Mac's own record, and the
    /// instance that connected is tried first from then on.
    @MainActor func testEveryInstanceIsTriedAndTheOneThatWorkedComesFirst() async throws {
        let rig = try Rig(instances: [" Studio", "Studio"])
        defer { rig.finish() }
        rig.session.answers = [" Studio": .refuse, "Studio": .welcome]
        await rig.manager.connect(to: rig.browser.macs[0], hello: rig.hello)   // the record the list shows first
        XCTAssertEqual(rig.session.attempts, [" Studio", "Studio"])
        XCTAssertTrue(rig.session.isConnected)
        rig.session.endSession("Connection lost", inputPathWasReady: true)
        try await eventually { rig.session.attempts.count == 3 && rig.session.isConnected }
        XCTAssertEqual(rig.session.attempts.last, "Studio", "the instance that connected is tried first")
        await rig.manager.disconnect()
    }

    /// M2: while another record of the Mac fails otherwise (asleep, out of reach), a record refusing the key does not
    /// count towards "three refusals", and the panel never offers Pair again.
    @MainActor func testRefusalCountsOnlyWhenEveryInstanceRefuses() async throws {
        let rig = try Rig(instances: [" Studio", "Studio"], resume: true)
        defer { rig.finish() }
        rig.session.answers = [" Studio": .refuse, "Studio": .fail("Connection timed out")]
        let log = StatusLog(rig.state)
        let resumed = await rig.manager.resumeLastMac(hello: rig.hello)
        XCTAssertTrue(resumed)
        try await eventually { rig.session.attempts.count >= 8 }   // four rounds
        XCTAssertTrue(rig.state.isReconnecting, "the loop is still running")
        XCTAssertFalse(log.statuses.contains(ControlCloseMessage.pairAgain), "Pair again was never shown")
        await rig.manager.disconnect()
    }

    /// §3.5: a listed Mac refusing the key three rounds in a row has forgotten this phone: the loop stops and the panel
    /// offers Pair again. With two records claiming its ID, a round counts once both refused (M2).
    @MainActor func testThreeRefusalsInARowStopTheLoop() async throws {
        for instances in [["Studio"], [" Studio", "Studio"]] {
            let rig = try Rig(instances: instances, resume: true)
            defer { rig.finish() }
            rig.session.answers = Dictionary(uniqueKeysWithValues: instances.map { ($0, FakeSession.Answer.refuse) })
            let resumed = await rig.manager.resumeLastMac(hello: rig.hello)
            XCTAssertTrue(resumed)
            try await eventually { !rig.state.isReconnecting && rig.state.status == ControlCloseMessage.pairAgain }
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(rig.session.attempts.count, 3 * instances.count)
            let waits = await rig.sleeps.requested
            XCTAssertEqual(waits, [Self.half, Self.second, 2 * Self.second])
            XCTAssertEqual(ConnectionState.panelAction(for: rig.state.status), .pair)
        }
    }

    /// §3.5: while the Mac is not discovered the loop looks for it every 0.5 s without backing off, and joins it as soon
    /// as it shows up.
    @MainActor func testMacThatIsNotListedIsLookedForEveryHalfSecond() async throws {
        let rig = try Rig(instances: [], resume: true)
        defer { rig.finish() }
        rig.session.answers = ["Studio": .welcome]
        let resumed = await rig.manager.resumeLastMac(hello: rig.hello)
        XCTAssertTrue(resumed)
        try await eventually { await rig.sleeps.requested.count >= 5 }
        let waits = await rig.sleeps.requested
        XCTAssertEqual(Set(waits), [Self.half])
        XCTAssertTrue(rig.session.attempts.isEmpty, "nothing to connect to")
        XCTAssertTrue(rig.state.isReconnecting)
        let studio = try Rig.mac("Studio", peerID: rig.peerID)
        rig.browser.macs = [studio]
        try await eventually { rig.session.isConnected }
        XCTAssertEqual(rig.session.attempts, ["Studio"])
        await rig.manager.disconnect()
    }

    @MainActor private func eventually(file: StaticString = #filePath, line: UInt = #line,
                                       _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Condition not met within 5 s", file: file, line: line)
                throw TimedOut()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private struct TimedOut: Error {}
}

/// One manager with its fakes and a throwaway UserDefaults suite.
@MainActor
private final class Rig {
    let peerID: UUID
    let session: FakeSession
    let browser: FakeBrowser
    let state: ConnectionState
    let sleeps: SleepLog
    let manager: ConnectionManager
    let hello: HelloMessage
    private let suite: String
    private let defaults: UserDefaults

    /// `resume`: the Mac is the last used one, as `resumeLastMac` and `reconnectNow` expect.
    init(instances: [String], resume: Bool = false, healthySession: Duration = .seconds(3_600)) throws {
        let suite = "ConnectionManagerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let peerID = UUID()
        if resume { defaults.set(peerID.uuidString, forKey: "lastMacPeerID") }
        let session = FakeSession()
        let browser = FakeBrowser()
        browser.macs = try instances.map { try Rig.mac($0, peerID: peerID) }
        let state = ConnectionState()
        let sleeps = SleepLog()
        let peer = PairedPeer(peerID: peerID, ltk: Data(repeating: 7, count: 32), name: "Studio")
        self.suite = suite
        self.defaults = defaults
        self.peerID = peerID
        self.session = session
        self.browser = browser
        self.state = state
        self.sleeps = sleeps
        manager = ConnectionManager(state: state, browser: browser, session: session, defaults: Rig.freshDefaults(suite: suite),
                                    pairStore: FakePairStore(peers: [peer]), healthySession: healthySession,
                                    sleep: { nanoseconds in
                                        await sleeps.record(nanoseconds)
                                        try await Task.sleep(nanoseconds: 1_000_000)
                                    })
        hello = HelloMessage(protocolVersion: MessageHeader.protocolVersion, peerID: UUID(), name: "Phone",
                             modelIdentifier: "iPhone16,2", surfaceWidthMM: 70, surfaceHeightMM: 150, ppi: 460,
                             maxContacts: 10, displayHz: 120, caps: 0, trackingOverride: 0)
    }

    func finish() { defaults.removePersistentDomain(forName: suite) }

    /// The manager (an actor) gets its own instance of the same suite: `UserDefaults` is not Sendable, so the rig's
    /// instance cannot be shared with it, and a value made on the main actor would be main-actor isolated. A
    /// nonisolated `sending` result is a fresh, disconnected value; both instances use the same persistent domain.
    nonisolated static func freshDefaults(suite: String) -> sending UserDefaults {
        UserDefaults(suiteName: suite) ?? UserDefaults()
    }

    static func mac(_ instance: String, peerID: UUID) throws -> DiscoveredMac {
        var txt = NWTXTRecord()
        txt["v"] = "1"; txt["id"] = peerID.uuidString.lowercased(); txt["nm"] = "Studio"; txt["pr"] = "0"
        return try XCTUnwrap(DiscoveredMac(endpoint: .service(name: instance, type: "_trackglass._tcp", domain: "local.",
                                                               interface: nil), txt: txt))
    }
}

/// `SessionClient` as `ConnectionManager` sees it: each Bonjour instance answers as scripted.
@MainActor
private final class FakeSession: ConnectionSession {
    enum Answer { case welcome, refuse, fail(String), finalAnswer(String) }

    var answers: [String: Answer] = [:]
    /// Instance names in the order they were tried.
    private(set) var attempts: [String] = []
    private(set) var isConnected = false
    private(set) var status = "No Mac connected"
    private(set) var lastCloseWasFinal = false
    private(set) var inputPathWasReady = false
    private var sequence: UInt64 = 0
    private var connectionChanged: (@MainActor @Sendable () -> Void)?
    private var sessionClosed: (@MainActor @Sendable () -> Void)?

    func snapshot() -> SessionClient.Snapshot {
        sequence += 1
        return SessionClient.Snapshot(isConnected: isConnected, status: status, macName: "Studio", rttMicros: 0,
                                      settings: nil, diagnostics: nil, diagnosticsSequence: 0, sequence: sequence,
                                      lastCloseWasFinal: lastCloseWasFinal, inputPathWasReady: inputPathWasReady)
    }

    func setCallbacks(connectionChanged: (@MainActor @Sendable () -> Void)?,
                      sessionClosed: (@MainActor @Sendable () -> Void)?) {
        self.connectionChanged = connectionChanged
        self.sessionClosed = sessionClosed
    }

    func connect(endpoint: NWEndpoint, mac: PairedPeer, hello: HelloMessage) async -> Bool {
        let instance = SessionClient.instanceName(of: endpoint) ?? ""
        attempts.append(instance)
        isConnected = false; lastCloseWasFinal = false; inputPathWasReady = false
        status = "Connecting to \(mac.name)…"
        connectionChanged?()
        await Task.yield()
        switch answers[instance] ?? .fail("Connection timed out") {
        case .welcome: isConnected = true; status = "Connected to \(mac.name)"
        case .refuse: status = ControlCloseMessage.pairAgain
        case .fail(let message): status = message
        case .finalAnswer(let message): status = message; lastCloseWasFinal = true
        }
        connectionChanged?()
        return isConnected
    }

    /// The connected session ends (the input deadline, a BYE, a lost link) as `SessionClient`'s `onClose` reports it.
    func endSession(_ message: String, inputPathWasReady: Bool = false) {
        self.inputPathWasReady = inputPathWasReady
        isConnected = false
        status = message
        sessionClosed?()
        connectionChanged?()
    }

    func clearFinalClose() { lastCloseWasFinal = false }
    func updateSurface(_ value: SurfaceMessage) {}
    func setTrackingOverride(_ value: Float) {}

    func disconnect(reason: UInt8) {
        guard isConnected else { return }
        endSession("Disconnected", inputPathWasReady: inputPathWasReady)
    }

    func disconnectAndWait(reason: UInt8, timeout: Duration) async { disconnect(reason: reason) }
}

@MainActor
private final class FakeBrowser: MacDiscovery {
    var macs: [DiscoveredMac] = []
    let status = "Looking for Macs…"
    let localNetworkDenied = false
    func start() {}
    func pause() {}
    func resume() {}
    func setOnChange(_ handler: (@MainActor @Sendable () -> Void)?) {}
}

private struct FakePairStore: PairedMacStore {
    let peers: [PairedPeer]
    func load(peerID: UUID) throws -> PairedPeer? { peers.first { $0.peerID == peerID } }
    func all() throws -> [PairedPeer] { peers }
    func delete(peerID: UUID) throws {}
}

private actor SleepLog {
    private(set) var requested: [UInt64] = []
    func record(_ nanoseconds: UInt64) { requested.append(nanoseconds) }
}

/// Every status the panel was given, in order.
@MainActor
private final class StatusLog {
    private(set) var statuses: [String] = []

    init(_ state: ConnectionState) {
        state.onSessionChange = { [weak self, weak state] in
            guard let self, let state else { return }
            self.statuses.append(state.status)
        }
    }
}
