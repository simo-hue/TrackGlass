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
            pipeline.heartbeat()
            pipeline.stop()
        }
        XCTAssertTrue(injector.events.contains(.button(kind: .left, phase: .down, clickCount: 2)))
        XCTAssertTrue(injector.events.contains(.button(kind: .left, phase: .up, clickCount: 2)))
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
    func inject(_ event: GestureEvent) {
        lock.lock(); storedEvents.append(event); let callback = onEvent; lock.unlock()
        callback?(event)
    }
    func tick() {}
}
