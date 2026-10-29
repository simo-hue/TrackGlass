import Foundation
import TrackglassEngine
import TrackglassKit
import XCTest
@testable import TrackglassMac

final class InputPipelineTests: XCTestCase {
    func testDropsOutOfOrderAndBackwardsTimeFrames() throws {
        let queue = DispatchQueue(label: "pipeline-test")
        let pipeline = InputPipeline(queue: queue, geometry: EngineGeometry(widthMM: 100, heightMM: 60, isLandscape: true), injector: RecordingInjector())
        queue.sync {
            pipeline.consume(Self.data(sequence: 2, time: 20))
            pipeline.consume(Self.data(sequence: 1, time: 30))
            pipeline.consume(Self.data(sequence: 2, time: 25))
            pipeline.consume(Self.data(sequence: 3, time: 19))
            XCTAssertEqual(pipeline.outOfOrderFrames, 2)
            XCTAssertEqual(pipeline.backwardsTimeFrames, 1)
        }
    }

    func testEstimatedPhoneTimeAdvancesOnTicks() {
        let queue = DispatchQueue(label: "pipeline-tick-test")
        let pipeline = InputPipeline(queue: queue, geometry: EngineGeometry(widthMM: 100, heightMM: 60, isLandscape: true), injector: RecordingInjector())
        let advanced = expectation(description: "estimated phone time advances between frames")
        let lock = NSLock()
        var times: [UInt64] = []
        queue.sync {
            pipeline.onEstimatedTick = { value in
                lock.lock(); times.append(value); let enough = times.count >= 2; lock.unlock()
                if enough { advanced.fulfill() }
            }
            pipeline.consume(Self.data(sequence: 0, time: 10, phase: .began))
        }
        wait(for: [advanced], timeout: 1)
        queue.sync { pipeline.stop() }
        lock.lock(); let result = times; lock.unlock()
        XCTAssertGreaterThan(result[1], result[0])
    }

    func testHeartbeatWhileTrackingForcesLiftoffButReleasesNonLockedDrag() {
        let queue = DispatchQueue(label: "pipeline-heartbeat-test")
        let injector = RecordingInjector()
        let pipeline = InputPipeline(queue: queue,
            geometry: EngineGeometry(widthMM: 100, heightMM: 60, isLandscape: true),
            settings: TrackpadSettings(dragging: true), injector: injector)
        queue.sync {
            pipeline.consume(Self.data(sequence: 1, time: 1_000_000_000, phase: .began))
            pipeline.consume(Self.data(sequence: 2, time: 1_100_000_000, phase: .ended))
            pipeline.consume(Self.data(sequence: 3, time: 1_200_000_000, phase: .began))
            XCTAssertTrue(injector.events.contains(.button(kind: .left, phase: .down, clickCount: 2)))
            // Frames 4 (ended) and 5 (lift-off) are lost; the phone's heartbeats name frame 5. The first one is
            // taken for frames still in flight, the second one (0.5 s later) forces the lift-off — before `stop()`.
            pipeline.heartbeat(sequence: 5)
            XCTAssertFalse(injector.events.contains(.button(kind: .left, phase: .up, clickCount: 2)))
            pipeline.heartbeat(sequence: 5)
            XCTAssertTrue(injector.events.contains(.button(kind: .left, phase: .up, clickCount: 2)))
            pipeline.stop()
        }
    }

    func testHeartbeatForTheLastFrameActsAtOnceAndAStaleOneIsIgnored() {
        let queue = DispatchQueue(label: "pipeline-heartbeat-order-test")
        let injector = RecordingInjector()
        let pipeline = InputPipeline(queue: queue,
            geometry: EngineGeometry(widthMM: 100, heightMM: 60, isLandscape: true),
            settings: TrackpadSettings(dragging: true), injector: injector)
        queue.sync {
            pipeline.consume(Self.data(sequence: 1, time: 1_000_000_000, phase: .began))
            pipeline.consume(Self.data(sequence: 2, time: 1_100_000_000, phase: .ended))
            pipeline.consume(Self.data(sequence: 3, time: 1_200_000_000, phase: .began))
            pipeline.heartbeat(sequence: 2)   // sent before frame 3, delivered after it: stale
            XCTAssertFalse(injector.events.contains(.button(kind: .left, phase: .up, clickCount: 2)))
            pipeline.heartbeat(sequence: 3)   // names the last frame the Mac has: acted on at once
            XCTAssertTrue(injector.events.contains(.button(kind: .left, phase: .up, clickCount: 2)))
            pipeline.stop()
        }
    }

    func testSilentInputPathIsReportedDeadAfterTheGracePeriods() {
        // §8: the phone sends a datagram at least every 0.5 s. Nothing within 6 s of admission (the phone's own
        // watchdog gives up at 5 s), or 3 s of silence after the last datagram, means the input path is gone.
        let queue = DispatchQueue(label: "pipeline-dead-path-test")
        let created: UInt64 = 1_000_000_000_000
        let pipeline = InputPipeline(queue: queue, geometry: EngineGeometry(widthMM: 100, heightMM: 60, isLandscape: true),
                                     injector: RecordingInjector(), createdUptime: created)
        queue.sync {
            XCTAssertFalse(pipeline.inputPathIsDead(now: created + 5_900_000_000))
            XCTAssertTrue(pipeline.inputPathIsDead(now: created + 6_000_000_000))
            pipeline.heartbeat(sequence: 0)
            let now = DispatchTime.now().uptimeNanoseconds
            XCTAssertFalse(pipeline.inputPathIsDead(now: now + 2_900_000_000))
            XCTAssertTrue(pipeline.inputPathIsDead(now: now + 3_100_000_000))
            pipeline.stop()
        }
    }

    func testStopPostsWhatTheInjectorStillHadScheduled() {
        let queue = DispatchQueue(label: "pipeline-flush-test")
        let injector = RecordingInjector()
        let pipeline = InputPipeline(queue: queue, geometry: EngineGeometry(widthMM: 100, heightMM: 60, isLandscape: true),
                                     settings: TrackpadSettings(naturalScrolling: false), injector: injector)
        XCTAssertEqual(injector.settings?.naturalScrolling, false, "the injector learns the settings with the pipeline")
        queue.sync { pipeline.stop() }
        XCTAssertEqual(injector.flushCount, 1)
    }

    func testContactSilenceReleasesHeldButtonAfterLiftoffTimeout() {
        let queue = DispatchQueue(label: "pipeline-liftoff-timeout-test")
        let injector = RecordingInjector()
        let released = expectation(description: "held mouse button is released")
        injector.onEvent = { event in
            if event == .button(kind: .left, phase: .up, clickCount: 2) { released.fulfill() }
        }
        let pipeline = InputPipeline(queue: queue,
            geometry: EngineGeometry(widthMM: 100, heightMM: 60, isLandscape: true),
            settings: TrackpadSettings(dragging: true), injector: injector)
        queue.sync {
            pipeline.consume(Self.data(sequence: 1, time: 1_000_000_000, phase: .began))
            pipeline.consume(Self.data(sequence: 2, time: 1_100_000_000, phase: .ended))
            pipeline.consume(Self.data(sequence: 3, time: 1_200_000_000, phase: .began))
        }
        wait(for: [released], timeout: 2)
        queue.sync { pipeline.stop() }
    }

    func testThreeSecondsWithoutDatagramsResetsTheEngineEvenWithADragLock() {
        // §6.3: no frame or heartbeat for 3 s while connected → the engine is reset and STATUS reports idle.
        // A deliberately engaged drag lock (§6.5.10) is the state the 1.5 s contact timeout cannot clear,
        // because no contact is tracked; the idle check must release it.
        let queue = DispatchQueue(label: "pipeline-idle-test")
        let injector = RecordingInjector()
        let pipeline = InputPipeline(queue: queue,
            geometry: EngineGeometry(widthMM: 100, heightMM: 60, isLandscape: true),
            settings: TrackpadSettings(dragging: true, dragLock: true), injector: injector)
        queue.sync {
            pipeline.consume(Self.data(sequence: 1, time: 1_000_000_000, phase: .began))
            pipeline.consume(Self.data(sequence: 2, time: 1_050_000_000, phase: .ended))
            pipeline.consume(Self.data(sequence: 3, time: 1_200_000_000, phase: .began))     // tap-and-a-half: button down
            pipeline.consume(Self.data(sequence: 4, time: 1_300_000_000, phase: .moved, x: 30))
            pipeline.consume(Self.data(sequence: 5, time: 1_400_000_000, phase: .ended, x: 30)) // lift → drag lock engages
            XCTAssertEqual(pipeline.diagnosticEngineState, 4, "drag held by the lock")
            XCTAssertTrue(injector.events.contains(.button(kind: .left, phase: .down, clickCount: 2)))
            XCTAssertFalse(injector.events.contains(.button(kind: .left, phase: .up, clickCount: 2)))
            let now = DispatchTime.now().uptimeNanoseconds
            pipeline.idleCheck(now: now &+ 2_900_000_000)
            XCTAssertEqual(pipeline.diagnosticEngineState, 4, "2.9 s of silence is not idle yet")
            pipeline.idleCheck(now: now &+ 3_000_000_000)
            XCTAssertEqual(pipeline.diagnosticEngineState, 0)
            XCTAssertTrue(injector.events.contains(.button(kind: .left, phase: .up, clickCount: 2)))
            pipeline.stop()
        }
    }

    func testTheInjectorLearnsSettingsWhenTheEngineAppliesThem() {
        // F11: a change made while a finger is down waits for the end of the gesture in the engine (§6.4); the
        // injector follows the engine's applied snapshot, not the request.
        let queue = DispatchQueue(label: "pipeline-settings-test")
        let injector = RecordingInjector()
        let pipeline = InputPipeline(queue: queue, geometry: EngineGeometry(widthMM: 100, heightMM: 60, isLandscape: true),
                                     injector: injector)
        queue.sync {
            pipeline.consume(Self.data(sequence: 1, time: 1_000_000_000, phase: .began))
            pipeline.setSettings(TrackpadSettings(naturalScrolling: false))
            XCTAssertEqual(injector.settings?.naturalScrolling, true, "deferred while the finger is down")
            pipeline.consume(Self.data(sequence: 2, time: 1_400_000_000, phase: .ended))
            XCTAssertEqual(injector.settings?.naturalScrolling, false)
            pipeline.setSettings(TrackpadSettings(naturalScrolling: true))
            XCTAssertEqual(injector.settings?.naturalScrolling, true, "applied at once when idle")
            pipeline.stop()
        }
    }

    func testScrollUsesTheFallbackModelUnlessAppleCurvesAreOptedIn() throws {
        // F2: the Apple parametric scroll path is opt-in until its units are verified (G-SCR).
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "trackglass-scroll-model-test"))
        defer { defaults.removePersistentDomain(forName: "trackglass-scroll-model-test") }
        XCTAssertTrue(InputPipeline.makeScrollAcceleration(settings: TrackpadSettings(), defaults: defaults) is ScrollFallbackAcceleration)
        defaults.set(true, forKey: InputPipeline.appleScrollCurvesKey)
        // Opted in, the Apple curves are used when this Mac's registry or the bundled archive provides them.
        let optedIn = InputPipeline.makeScrollAcceleration(settings: TrackpadSettings(), defaults: defaults)
        guard Bundle.main.url(forResource: "DefaultAccelCurves", withExtension: "json") != nil else {
            throw XCTSkip("no bundled curves in this host")
        }
        XCTAssertTrue(optedIn is ScrollAccelerator)
    }

    func testRecordingWritesASettingsSidecarTgreplayCanRead() throws {
        // §6.10: `tgreplay run x.tgrec --settings x.settings.json` replays a Mac recording with its settings changes.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchQueue(label: "pipeline-recording-test")
        let geometry = EngineGeometry(widthMM: 100, heightMM: 60, isLandscape: true)
        let pipeline = InputPipeline(queue: queue, geometry: geometry, settings: TrackpadSettings(clicking: false),
                                     injector: RecordingInjector())
        pipeline.recordingsDirectory = directory
        queue.sync {
            pipeline.startRecording()
            pipeline.consume(Self.data(sequence: 1, time: 1_000_000_000, phase: .began))
            pipeline.consume(Self.data(sequence: 2, time: 1_100_000_000, phase: .ended))
            pipeline.setSettings(TrackpadSettings(naturalScrolling: false))
            pipeline.setGeometry(EngineGeometry(widthMM: 60, heightMM: 100, isLandscape: false))
            pipeline.stop()
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(files.count, 2)
        let recording = try XCTUnwrap(files.first { $0.hasSuffix(".tgrec") })
        let sidecarName = try XCTUnwrap(files.first { $0.hasSuffix(".settings.json") })
        XCTAssertEqual(sidecarName, recording.replacingOccurrences(of: ".tgrec", with: ".settings.json"))
        let sidecar = try JSONDecoder().decode(ReplaySidecar.self, from: Data(contentsOf: directory.appendingPathComponent(sidecarName)))
        XCTAssertEqual(sidecar.settings, TrackpadSettings(clicking: false))
        XCTAssertEqual(sidecar.geometry, geometry)
        XCTAssertEqual(sidecar.acceleration.model, "unitGain")
        XCTAssertEqual(sidecar.settingsChanges, [.init(atNs: 1_100_000_000, settings: TrackpadSettings(naturalScrolling: false))])
        XCTAssertEqual(sidecar.geometryChanges, [.init(atNs: 1_100_000_000, geometry: EngineGeometry(widthMM: 60, heightMM: 100, isLandscape: false))])
        // The keys tgreplay's settings file reads (Tools/tgreplay/main.swift `ReplaySettings`).
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(sidecarName))) as? [String: Any])
        XCTAssertTrue(Set(["settings", "geometry", "acceleration", "settingsChanges", "geometryChanges"]).isSubset(of: Set(json.keys)))
    }

    private static func data(sequence: UInt32, time: UInt64, phase: Contact.Phase = .moved, x: Float = 10) -> Data {
        var frame = TouchFrame(sequence: sequence, frameTime: time)
        frame.append(Contact(contactID: 1, phase: phase, x: x, y: 10))
        var storage = [UInt8](repeating: 0, count: TouchFrame.maximumByteCount)
        let written = try! storage.withUnsafeMutableBytes { try TouchFrameEncoder(frame: frame).encode(into: $0) }
        return Data(storage.prefix(written))
    }
}

private final class RecordingInjector: InputInjector {
    private let lock = NSLock()
    private var storedEvents: [GestureEvent] = []
    var onEvent: ((GestureEvent) -> Void)?
    var events: [GestureEvent] { lock.lock(); defer { lock.unlock() }; return storedEvents }
    private(set) var settings: TrackpadSettings?
    private(set) var flushCount = 0
    func inject(_ event: GestureEvent) {
        lock.lock(); storedEvents.append(event); let callback = onEvent; lock.unlock()
        callback?(event)
    }
    func tick() {}
    func settingsDidChange(_ settings: TrackpadSettings) { self.settings = settings }
    func flush() { flushCount += 1 }
}
