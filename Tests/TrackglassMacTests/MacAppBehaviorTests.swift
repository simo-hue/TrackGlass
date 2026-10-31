import Foundation
import Network
import Security
import ServiceManagement
import TrackglassEngine
import TrackglassKit
import XCTest
@testable import TrackglassMac

final class MacAppBehaviorTests: XCTestCase {
    // MARK: Single instance (§6.1)

    func testOlderCopySurvivesAndExactlyOneOfTwoYields() {
        let now = Date()
        let older = SingleInstance.Instance(processIdentifier: 900, launchDate: now)
        let newer = SingleInstance.Instance(processIdentifier: 100, launchDate: now.addingTimeInterval(0.05))
        XCTAssertTrue(SingleInstance.shouldYield(newer, to: [older]))
        XCTAssertFalse(SingleInstance.shouldYield(older, to: [newer]))
        // Same launch date or a missing one: the lower process ID survives, from both points of view.
        let pairs: [(SingleInstance.Instance, SingleInstance.Instance)] = [
            (.init(processIdentifier: 10, launchDate: now), .init(processIdentifier: 11, launchDate: now)),
            (.init(processIdentifier: 10, launchDate: nil), .init(processIdentifier: 11, launchDate: now)),
            (.init(processIdentifier: 12, launchDate: nil), .init(processIdentifier: 11, launchDate: nil)),
        ]
        for (a, b) in pairs {
            XCTAssertNotEqual(SingleInstance.shouldYield(a, to: [b]), SingleInstance.shouldYield(b, to: [a]),
                              "exactly one of \(a.processIdentifier) and \(b.processIdentifier) must exit")
        }
        XCTAssertFalse(SingleInstance.shouldYield(older, to: [older]), "a copy never yields to itself")
    }

    // MARK: Start at login (§6.1, §6.2)

    @MainActor func testLoginItemOutcomes() {
        let fake = FakeLoginItems()
        let model = MacSettingsModel(loginItems: fake.service)
        XCTAssertEqual(model.loginState, .disabled)

        XCTAssertTrue(model.setLoginEnabled(true))
        XCTAssertEqual(model.loginState, .enabled)
        XCTAssertNil(model.loginError)
        XCTAssertTrue(model.setLoginEnabled(true), "already on: nothing to do")
        XCTAssertEqual(fake.registerCalls, 1)

        XCTAssertTrue(model.setLoginEnabled(false))
        XCTAssertEqual(model.loginState, .disabled)

        fake.statusAfterRegister = .requiresApproval
        XCTAssertFalse(model.setLoginEnabled(true), "waiting for approval is not on yet: Welcome stays open")
        XCTAssertEqual(model.loginState, .requiresApproval)
        XCTAssertTrue(model.loginEnabled)
        XCTAssertNil(model.loginError, "the approval row explains it; no raw error")

        // Approved in System Settings meanwhile: picked up when the app becomes active again.
        fake.status = .enabled
        model.refreshLoginState()
        XCTAssertEqual(model.loginState, .enabled)

        fake.status = .notRegistered
        fake.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        XCTAssertFalse(model.setLoginEnabled(true))
        XCTAssertEqual(model.loginState, .disabled)
        XCTAssertTrue(model.loginError?.contains("Operation not permitted") ?? false)
    }

    func testRunningFromTheDiskImageIsDetected() {
        XCTAssertTrue(MacSettingsModel.isRunningFromTemporaryLocation("/Volumes/Trackglass/Trackglass for Mac.app"))
        XCTAssertTrue(MacSettingsModel.isRunningFromTemporaryLocation(
            "/private/var/folders/xy/abc/T/AppTranslocation/1234-5678/d/Trackglass for Mac.app"))
        XCTAssertFalse(MacSettingsModel.isRunningFromTemporaryLocation("/Applications/Trackglass for Mac.app"))
        XCTAssertFalse(MacSettingsModel.isRunningFromTemporaryLocation("/Users/simone/Applications/Trackglass for Mac.app"))
    }

    // MARK: Local Network denial (§6.2)

    func testLocalNetworkDenialIsExplainedInPlainLanguage() {
        let denied = NWError.dns(DNSServiceErrorType(LocalNetworkPermission.policyDeniedCode))
        XCTAssertTrue(LocalNetworkPermission.isPolicyDenied(denied))
        XCTAssertTrue(LocalNetworkPermission.message(for: denied, failed: true).contains("Local Network"))
        XCTAssertFalse(LocalNetworkPermission.message(for: denied, failed: true).contains("-65570"))
        let other = NWError.dns(DNSServiceErrorType(-65563))   // kDNSServiceErr_ServiceNotRunning
        XCTAssertFalse(LocalNetworkPermission.isPolicyDenied(other))
        XCTAssertTrue(LocalNetworkPermission.message(for: other, failed: true).hasPrefix("Discovery failed"))
        XCTAssertFalse(LocalNetworkPermission.isPolicyDenied(.posix(.ECONNREFUSED)))
    }

    @MainActor func testLocalNetworkStateClearsOnceAServiceRegisters() {
        let permission = LocalNetworkPermission.shared
        permission.report(.posix(.ENETDOWN))
        permission.reportRegistered()
        XCTAssertFalse(permission.isDenied)
        permission.report(.dns(DNSServiceErrorType(LocalNetworkPermission.policyDeniedCode)))
        XCTAssertTrue(permission.isDenied)
        permission.reportRegistered()
        XCTAssertFalse(permission.isDenied)
    }

    // MARK: Keychain errors (§3.4)

    func testPairingStoreErrorsReadAsSentences() {
        let missing = PairingStoreError.keychain(errSecMissingEntitlement).localizedDescription
        XCTAssertTrue(missing.contains("\(errSecMissingEntitlement)"))
        XCTAssertTrue(missing.contains("reinstall"))
        XCTAssertFalse(missing.contains("couldn’t be completed"))
        XCTAssertTrue(PairingStoreError.invalidRecord.localizedDescription.contains("pair it again"))
        XCTAssertFalse(PairingStoreError.keychain(errSecItemNotFound).localizedDescription.isEmpty)
    }

    // MARK: STATUS loss accounting (§4.5)

    func testLateFrameFillsTheGapItWasCountedIn() {
        var counter = FrameLossCounter()
        for sequence: UInt32 in [1, 2, 3] { counter.record(sequence) }
        XCTAssertEqual(counter.missing, 0)
        XCTAssertEqual(counter.received, 3)

        counter.record(6)                       // 4 and 5 look lost
        XCTAssertEqual(counter.missing, 2)
        XCTAssertEqual(counter.lastSequence, 6)
        counter.record(4)                       // reordered, not lost
        XCTAssertEqual(counter.missing, 1)
        XCTAssertEqual(counter.lastSequence, 6, "an older frame must not move the newest sequence back")
        counter.record(7)
        XCTAssertEqual(counter.missing, 1, "no gap is counted twice after a late frame")
        counter.record(5)
        XCTAssertEqual(counter.missing, 0)
        counter.record(5)                       // a duplicate never makes the count negative
        XCTAssertEqual(counter.missing, 0)

        counter.resetCounts()
        counter.record(9)                       // the window restarts, the position is kept: 8 is missing
        XCTAssertEqual(counter.missing, 1)
        XCTAssertEqual(counter.lossPermille, 500)
        counter.record(6)                       // late, but its gap was counted in the previous window
        XCTAssertEqual(counter.missing, 1)
        counter.record(8)                       // late and counted in this window
        XCTAssertEqual(counter.missing, 0)

        counter.reset()
        counter.record(UInt32.max)
        counter.record(0)                       // wraps without a gap
        XCTAssertEqual(counter.missing, 0)
    }

    // MARK: Quit (§6.1)

    func testShutdownStopsInputAndRefusesNewFlows() {
        let listener = InputListener()
        listener.setAdmittedPeer(UUID(), geometry: EngineGeometry(widthMM: 100, heightMM: 60, isLandscape: true))
        let first = NWConnection(host: "127.0.0.1", port: 40_101, using: .udp)
        listener.accept(first)
        XCTAssertEqual(listener.flowCount, 1)
        listener.shutdown()
        XCTAssertEqual(listener.flowCount, 0)
        let late = NWConnection(host: "127.0.0.1", port: 40_102, using: .udp)
        listener.accept(late)
        XCTAssertEqual(listener.flowCount, 0)
        first.cancel(); late.cancel()
    }

    // MARK: Sleep (§8.1)

    func testSleepStopsTheInputSideBeforeReturningAndAdmissionWorksAfterWake() {
        // L14: `stopForSleep` runs the session's teardown (held buttons released) on the input queue before it returns.
        let listener = InputListener()
        let geometry = EngineGeometry(widthMM: 100, heightMM: 60, isLandscape: true)
        listener.setAdmittedPeer(UUID(), geometry: geometry)
        let flow = NWConnection(host: "127.0.0.1", port: 40_201, using: .udp)
        listener.accept(flow)
        XCTAssertEqual(listener.flowCount, 1)
        listener.stopForSleep()
        XCTAssertEqual(listener.flowCount, 0)
        let asleep = NWConnection(host: "127.0.0.1", port: 40_202, using: .udp)
        listener.accept(asleep)
        XCTAssertEqual(listener.flowCount, 0, "no phone is admitted while asleep")
        listener.setAdmittedPeer(UUID(), geometry: geometry)   // after wake, a phone is admitted again
        let awake = NWConnection(host: "127.0.0.1", port: 40_203, using: .udp)
        listener.accept(awake)
        XCTAssertEqual(listener.flowCount, 1)
        listener.setAdmittedPeer(nil)
        [flow, asleep, awake].forEach { $0.cancel() }
    }

    // MARK: Acknowledgements (M19)

    func testAboutCarriesTheNoticesOfTheBundledSparkleCode() {
        let text = Acknowledgements.text
        for notice in ["Andy Matuschak", "Permission is hereby granted, free of charge", "Colin Percival",
                       "Redistributions in binary form must reproduce", "Yuta Mori", "Orson Peters", "Mark Hamlin"] {
            XCTAssertTrue(text.contains(notice), notice)
        }
    }
}

@MainActor
private final class FakeLoginItems {
    var status: SMAppService.Status = .notRegistered
    var statusAfterRegister: SMAppService.Status = .enabled
    var registerError: Error?
    var registerCalls = 0

    var service: LoginItemService {
        LoginItemService(status: { [unowned self] in self.status },
                         register: { [unowned self] in
                             self.registerCalls += 1
                             if let error = self.registerError { throw error }
                             self.status = self.statusAfterRegister
                         },
                         unregister: { [unowned self] in self.status = .notRegistered })
    }
}
