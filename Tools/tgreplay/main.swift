import Foundation
import TrackglassEngine
import TrackglassKit

private struct ReplaySettings: Decodable {
    let settings: TrackpadSettings
    let geometry: EngineGeometry
    let acceleration: AccelerationSettings
    let ticks: [UInt64]?
    let geometryChanges: [GeometryChange]?
    let settingsChanges: [SettingsChange]?
    let forceLiftoffReleaseDragLock: Bool?
}

private struct AccelerationSettings: Decodable {
    let model: String
    let pointsPerMM: Double?
    /// `parametric` only: path (relative to the settings file) of a `tgaccel` registry archive such as
    /// `Mac/Resources/DefaultAccelCurves.json`, plus the tracking speed to select the curve with.
    let curvesFile: String?
    let trackingSpeed: Double?
}

private struct GeometryChange: Decodable {
    let atNs: UInt64
    let geometry: EngineGeometry
}

private struct ReplayResult {
    let header: TGRecHeader
    let events: [GestureEvent]
    let frames: [TouchFrame]
    let forcedFinalLiftoff: Bool
    let contactsRemain: Bool
    let eventsAfterReset: Int
    /// `invariants` only (pipeline emulation): how many events the engine had emitted *before* the final,
    /// BYE-style forced lift-off, whether a drag lock was deliberately engaged at that point, how many
    /// emulated 1.5 s lift-off timeouts fired, and whether the engine had settled (no contacts, no pending
    /// timer work) within the settle budget after the last frame.
    let eventsBeforeFinalLiftoff: Int
    let dragLockEngagedBeforeFinalLiftoff: Bool
    let timeoutLiftoffs: Int
    let settledBeforeFinalLiftoff: Bool
}

private enum ReplayError: Error, CustomStringConvertible {
    case usage(String)
    case unsupportedAcceleration(String)
    case mismatch(String)
    case invariant(String)

    var description: String {
        switch self {
        case .usage(let message), .unsupportedAcceleration(let message), .mismatch(let message), .invariant(let message): message
        }
    }
}

private enum TGReplay {
    static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else { throw ReplayError.usage(usage) }
        switch command {
        case "run":
            guard arguments.count == 4, arguments[2] == "--settings" else { throw ReplayError.usage(usage) }
            let result = try replay(recording: URL(fileURLWithPath: arguments[1]), settingsURL: URL(fileURLWithPath: arguments[3]))
            // A JSON array with sorted keys: diff-stable and usable directly as `<name>.expected.json`.
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(result.events), as: UTF8.self))
        case "verify-dir":
            guard arguments.count == 2 else { throw ReplayError.usage(usage) }
            try verifyDirectory(URL(fileURLWithPath: arguments[1]))
        case "invariants":
            guard arguments.count == 8, arguments[2] == "--settings", arguments[4] == "--drop", arguments[6] == "--seed" else {
                throw ReplayError.usage(usage)
            }
            guard let fraction = Double(arguments[5]), (0...1).contains(fraction), let seed = UInt64(arguments[7]) else {
                throw ReplayError.usage(usage)
            }
            let result = try replay(recording: URL(fileURLWithPath: arguments[1]),
                                    settingsURL: URL(fileURLWithPath: arguments[3]), dropFraction: fraction, seed: seed,
                                    emulatePipeline: true)
            try checkInvariants(result)
            print("invariants passed (drop=\(fraction), seed=\(seed), timeoutLiftoffs=\(result.timeoutLiftoffs))")
        case "velocity-stats":
            guard arguments.count >= 2 else { throw ReplayError.usage(usage) }
            for path in arguments.dropFirst() {
                let stats = try velocityStatistics(recording: URL(fileURLWithPath: path))
                print("\(path): frames=\(stats.frames) meanDtMs=\(format(stats.meanDtMs)) meanSpeedMMs=\(format(stats.meanSpeed)) "
                      + "stdDevSpeedMMs=\(format(stats.standardDeviation)) coefficientOfVariation=\(format(stats.coefficientOfVariation)) "
                      + "meanAbsAcceleration=\(format(stats.meanAbsoluteAcceleration))")
            }
        case "help", "--help", "-h": print(usage)
        default: throw ReplayError.usage(usage)
        }
    }

    private static func format(_ value: Double) -> String { String(format: "%.4f", value) }

    /// M10.3: frame-to-frame speed of the first contact, so two recordings of the same motion (coalesced samples
    /// on vs off) can be compared for smoothness — a lower coefficient of variation and mean |acceleration|
    /// mean the engine sees a smoother velocity.
    private struct VelocityStatistics {
        var frames = 0
        var meanDtMs = 0.0
        var meanSpeed = 0.0
        var standardDeviation = 0.0
        var coefficientOfVariation = 0.0
        var meanAbsoluteAcceleration = 0.0
    }

    private static func velocityStatistics(recording: URL) throws -> VelocityStatistics {
        var reader = try TGRecReader(contentsOf: recording)
        var speeds: [Double] = []
        var intervals: [Double] = []
        var previous: (x: Double, y: Double, time: UInt64, id: UInt8)?
        var stats = VelocityStatistics()
        while let record = try reader.next() {
            stats.frames += 1
            let frame = try record.frameBytes.withUnsafeBytes { try TouchFrameDecoder.decode($0) }
            guard frame.contactCount > 0 else { previous = nil; continue }
            let contact = frame[0]
            guard contact.kind == .finger else { continue }
            if let last = previous, last.id == contact.contactID, frame.frameTime > last.time, contact.phase != .began {
                let dt = Double(frame.frameTime - last.time) / 1_000_000   // ms
                let distance = ((Double(contact.x) - last.x) * (Double(contact.x) - last.x)
                                + (Double(contact.y) - last.y) * (Double(contact.y) - last.y)).squareRoot()
                speeds.append(distance / dt * 1_000)   // mm/s
                intervals.append(dt)
            }
            previous = (Double(contact.x), Double(contact.y), frame.frameTime, contact.contactID)
        }
        guard speeds.count > 1 else { return stats }
        stats.meanDtMs = intervals.reduce(0, +) / Double(intervals.count)
        stats.meanSpeed = speeds.reduce(0, +) / Double(speeds.count)
        let variance = speeds.reduce(0) { $0 + ($1 - stats.meanSpeed) * ($1 - stats.meanSpeed) } / Double(speeds.count - 1)
        stats.standardDeviation = variance.squareRoot()
        stats.coefficientOfVariation = stats.meanSpeed > 0 ? stats.standardDeviation / stats.meanSpeed : 0
        var accelerations = 0.0
        for index in 1..<speeds.count { accelerations += abs(speeds[index] - speeds[index - 1]) / max(intervals[index], 0.001) }
        stats.meanAbsoluteAcceleration = accelerations / Double(speeds.count - 1)
        return stats
    }

    private static let usage = """
    Usage:
      tgreplay run <name.tgrec> --settings <name.settings.json>
      tgreplay verify-dir <fixture-directory>
      tgreplay invariants <name.tgrec> --settings <name.settings.json> --drop <fraction> --seed <integer>
      tgreplay velocity-stats <a.tgrec> [<b.tgrec> ...]   (M10.3: compare velocity smoothness of recordings)
    """

    /// ENGINE_TICK (§2.4), LIFTOFF_TIMEOUT (§4.7) and the budget after the last frame within which every
    /// timer-driven state (release grace, pending secondary click, momentum) must have run out.
    private static let engineTickNs: UInt64 = 8_000_000
    private static let liftoffTimeoutNs: UInt64 = 1_500_000_000
    private static let settleBudgetNs: UInt64 = 10_000_000_000

    /// `emulatePipeline` (the `invariants` command) adds what `InputPipeline` contributes on the Mac and a
    /// recording cannot carry: the 8 ms tick from the first frame until the engine no longer asks for ticks,
    /// and the 1.5 s no-frame lift-off timeout (§4.7). Only then does a dropped `ended`/lift-off datagram
    /// exercise the engine's own recovery instead of being papered over by the tool's final forced lift-off,
    /// which stays as the BYE-style safety net and must find nothing left to release.
    private static func replay(recording: URL, settingsURL: URL, dropFraction: Double = 0, seed: UInt64 = 1,
                               emulatePipeline: Bool = false) throws -> ReplayResult {
        let configuration = try JSONDecoder().decode(ReplaySettings.self, from: Data(contentsOf: settingsURL))
        let acceleration: any AccelerationModel
        var scrollAcceleration: any AccelerationModel
        switch configuration.acceleration.model {
        case "unitGain": acceleration = UnitGainAcceleration(); scrollAcceleration = acceleration
        case "constant":
            acceleration = ConstantGainAcceleration(pointsPerMM: configuration.acceleration.pointsPerMM ?? 4)
            scrollAcceleration = acceleration
        case "parametric":
            // SPEC §6.10: the real Apple curves, for tests of the models themselves (fixtures stay unitGain).
            guard let file = configuration.acceleration.curvesFile else {
                throw ReplayError.usage("parametric acceleration needs \"curvesFile\" in the settings file")
            }
            let archiveURL = URL(fileURLWithPath: file, relativeTo: settingsURL.deletingLastPathComponent())
            let archive = try Data(contentsOf: archiveURL)
            guard let root = try JSONSerialization.jsonObject(with: archive) as? [String: Any],
                  let rawResolution = (root["HIDPointerResolution"] as? NSNumber)?.doubleValue,
                  let reportRate = (root["HIDPointerReportRate"] as? NSNumber)?.doubleValue else {
                throw ReplayError.usage("\(file) lacks HIDPointerResolution / HIDPointerReportRate")
            }
            let trackingSpeed = configuration.acceleration.trackingSpeed ?? configuration.settings.trackingSpeed
            acceleration = try PointerAccelerator(registryJSON: archive, resolution: rawResolution / 65_536,
                                                  reportRate: reportRate, trackingSpeed: trackingSpeed)
            if let scrollCurves = try? ParametricAccelerationCurve.decodeScrollCurves(from: archive),
               let scroll = try? ScrollAccelerator(curves: scrollCurves, resolution: rawResolution / 65_536,
                                                   reportRate: reportRate, trackingSpeed: trackingSpeed) {
                scrollAcceleration = scroll
            } else { scrollAcceleration = acceleration }
        default: throw ReplayError.unsupportedAcceleration(configuration.acceleration.model)
        }
        var reader = try TGRecReader(contentsOf: recording)
        var recorded: [TouchFrame] = []
        while let record = try reader.next() {
            recorded.append(try record.frameBytes.withUnsafeBytes { try TouchFrameDecoder.decode($0) })
        }
        let engine = GestureEngine(settings: configuration.settings, geometry: configuration.geometry, acceleration: acceleration, scrollAcceleration: scrollAcceleration)
        var events: [GestureEvent] = []
        var frames: [TouchFrame] = []
        var ticks = (configuration.ticks ?? []).sorted()
        if emulatePipeline, let first = recorded.first?.frameTime, let last = recorded.last?.frameTime {
            // §2.4: the pipeline's 8 ms timer runs while contacts are tracked; merge it with the fixture's own ticks.
            var grid = Set(ticks)
            var time = first &+ engineTickNs
            while time < last { grid.insert(time); time &+= engineTickNs }
            ticks = grid.sorted()
        }
        let changes = (configuration.geometryChanges ?? []).sorted { $0.atNs < $1.atNs }
        let settingsChanges = (configuration.settingsChanges ?? []).sorted { $0.atNs < $1.atNs }
        var settingsIndex = 0
        var tickIndex = 0, changeIndex = 0
        var random = seed
        var lastAcceptedFrameTime: UInt64?
        var timeoutLiftoffs = 0

        /// The pipeline's lift-off timeout (§4.7): no frame for 1.5 s while contacts are tracked releases everything.
        func emulateLiftoffTimeout(now: UInt64, into buffer: inout EventBuffer) {
            guard emulatePipeline, engine.hasActiveContacts, let last = lastAcceptedFrameTime,
                  now >= last &+ liftoffTimeoutNs else { return }
            engine.forceLiftoff(releaseDragLock: true, into: &buffer)
            timeoutLiftoffs += 1
        }

        /// Applies every scheduled tick, geometry change and settings change dated before `limit`, in time order.
        /// SPEC §6.10: scheduled against the frames' own clock, so Mac-recorded (origin 2) fixtures replay correctly.
        func runScheduled(before limit: UInt64) {
            while true {
                let tickTime = tickIndex < ticks.count ? ticks[tickIndex] : UInt64.max
                let changeTime = changeIndex < changes.count ? changes[changeIndex].atNs : UInt64.max
                let settingsTime = settingsIndex < settingsChanges.count ? settingsChanges[settingsIndex].atNs : UInt64.max
                guard min(tickTime, changeTime, settingsTime) < limit else { break }
                var buffer = EventBuffer()
                if settingsTime <= min(tickTime, changeTime) {
                    engine.setSettings(settingsChanges[settingsIndex].settings); settingsIndex += 1
                } else if tickTime < changeTime {
                    engine.tick(now: tickTime, into: &buffer); tickIndex += 1
                    emulateLiftoffTimeout(now: tickTime, into: &buffer)
                } else {
                    engine.setGeometry(changes[changeIndex].geometry, into: &buffer); changeIndex += 1
                }
                events.append(contentsOf: buffer.events)
            }
        }

        for frame in recorded {
            runScheduled(before: frame.frameTime)
            if dropped(fraction: dropFraction, random: &random) { continue }
            frames.append(frame)
            lastAcceptedFrameTime = frame.frameTime
            var buffer = EventBuffer(); engine.process(frame, into: &buffer); events.append(contentsOf: buffer.events)
        }
        runScheduled(before: UInt64.max)
        if let releaseDragLock = configuration.forceLiftoffReleaseDragLock {
            var buffer = EventBuffer(); engine.forceLiftoff(releaseDragLock: releaseDragLock, into: &buffer)
            events.append(contentsOf: buffer.events)
        }
        var settled = true
        if emulatePipeline, let last = lastAcceptedFrameTime ?? recorded.last?.frameTime {
            // Keep the timer running after the last frame exactly as the pipeline does while `needsTick`
            // (release grace, pending secondary click, momentum) or contacts remain (lift-off timeout).
            var time = max(last, ticks.last ?? 0) &+ engineTickNs
            let deadline = time &+ settleBudgetNs
            while engine.needsTick || engine.hasActiveContacts, time < deadline {
                var buffer = EventBuffer()
                engine.tick(now: time, into: &buffer)
                emulateLiftoffTimeout(now: time, into: &buffer)
                events.append(contentsOf: buffer.events)
                time &+= engineTickNs
            }
            settled = !engine.needsTick && !engine.hasActiveContacts
        }
        let eventsBeforeFinalLiftoff = events.count
        let dragLockEngaged = engine.isDragLockEngaged
        let didForceFinalLiftoff = emulatePipeline || dropFraction > 0
        if didForceFinalLiftoff {
            var buffer = EventBuffer(); engine.forceLiftoff(releaseDragLock: true, into: &buffer)
            events.append(contentsOf: buffer.events)
        }
        var afterReset = EventBuffer()
        if didForceFinalLiftoff {
            let latest = max(frames.last?.frameTime ?? 0, ticks.last ?? 0)
            engine.tick(now: latest > UInt64.max - 20_000_000_000 ? UInt64.max : latest + 20_000_000_000, into: &afterReset)
        }
        return ReplayResult(header: reader.header, events: events, frames: frames, forcedFinalLiftoff: didForceFinalLiftoff,
                            contactsRemain: engine.hasActiveContacts, eventsAfterReset: afterReset.count,
                            eventsBeforeFinalLiftoff: eventsBeforeFinalLiftoff, dragLockEngagedBeforeFinalLiftoff: dragLockEngaged,
                            timeoutLiftoffs: timeoutLiftoffs, settledBeforeFinalLiftoff: settled)
    }

    private static func dropped(fraction: Double, random: inout UInt64) -> Bool {
        guard fraction > 0 else { return false }
        random = random &* 6_364_136_223_846_793_005 &+ 1
        return Double(random >> 11) / Double(UInt64.max >> 11) < fraction
    }

    private static func verifyDirectory(_ directory: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "tgrec" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw ReplayError.mismatch("no .tgrec fixtures found in \(directory.path)") }
        for recording in files {
            let stem = recording.deletingPathExtension()
            let settingsURL = stem.appendingPathExtension("settings.json")
            let expectedURL = stem.appendingPathExtension("expected.json")
            guard FileManager.default.fileExists(atPath: settingsURL.path),
                  FileManager.default.fileExists(atPath: expectedURL.path) else {
                throw ReplayError.mismatch("incomplete fixture triplet: \(recording.lastPathComponent)")
            }
            let result = try replay(recording: recording, settingsURL: settingsURL)
            let expected = try JSONDecoder().decode([GestureEvent].self, from: Data(contentsOf: expectedURL))
            guard GestureEvent.approximatelyEqual(expected, result.events) else {
                throw ReplayError.mismatch("fixture mismatch: \(recording.lastPathComponent)\nexpected: \(expected)\nactual:   \(result.events)")
            }
            print("verified \(recording.lastPathComponent)")
        }
        print("verified \(files.count) fixtures")
    }

    private static func heldButtons(in events: ArraySlice<GestureEvent>) -> Set<ButtonKind> {
        var held = Set<ButtonKind>()
        for event in events {
            if case let .button(kind, phase, _) = event {
                if phase == .down { held.insert(kind) } else { held.remove(kind) }
            }
        }
        return held
    }

    private static func activeGestures(in events: ArraySlice<GestureEvent>) -> Set<String> {
        var gestures = Set<String>()
        func track(_ name: String, _ phase: GesturePhase) {
            switch phase {
            case .mayBegin, .began: gestures.insert(name)
            case .ended, .cancelled: gestures.remove(name)
            case .changed: break
            }
        }
        for event in events {
            switch event {
            case let .scroll(_, _, phase, _): track("scroll", phase)
            case let .magnify(_, phase): track("magnify", phase)
            case let .rotate(_, phase): track("rotate", phase)
            case let .dockSwipe(kind, _, phase, _): track("dock-" + kind.rawValue, phase)
            case let .scrollMomentum(phase, _, _):
                if phase == .begin { gestures.insert("momentum") }
                else if phase == .end { gestures.remove("momentum") }
            case .gestureBegin: gestures.insert("bracket")
            case .gestureEnd: gestures.remove("bracket")
            default: break
            }
        }
        return gestures
    }

    /// §6.10 safety invariants under loss. The engine (plus the emulated pipeline timer and 1.5 s timeout) must
    /// have released every button and ended every gesture on its own; the tool's final forced lift-off is only
    /// allowed to release a deliberately engaged drag lock (§6.5.10: drag lock survives until a tap or BYE).
    private static func checkInvariants(_ result: ReplayResult) throws {
        guard result.forcedFinalLiftoff else { throw ReplayError.invariant("replay ended without a forced final lift-off") }
        let beforeFinal = result.events[..<result.eventsBeforeFinalLiftoff]
        guard result.settledBeforeFinalLiftoff else {
            throw ReplayError.invariant("engine still tracked contacts or asked for ticks 10 s after the last frame")
        }
        let heldBefore = heldButtons(in: beforeFinal)
        if result.dragLockEngagedBeforeFinalLiftoff {
            guard heldBefore == [.left] else {
                throw ReplayError.invariant("drag lock engaged but held buttons are \(heldBefore) before the final lift-off")
            }
        } else if !heldBefore.isEmpty {
            throw ReplayError.invariant("a button remained down until the final forced lift-off: \(heldBefore)")
        }
        let gesturesBefore = activeGestures(in: beforeFinal)
        guard gesturesBefore.isEmpty else {
            throw ReplayError.invariant("gestures remained active until the final forced lift-off: \(gesturesBefore.sorted())")
        }
        let heldAfter = heldButtons(in: result.events[...])
        if !heldAfter.isEmpty { throw ReplayError.invariant("a button remains down after replay: \(heldAfter)") }
        let gesturesAfter = activeGestures(in: result.events[...])
        guard gesturesAfter.isEmpty else { throw ReplayError.invariant("gestures remain active: \(gesturesAfter.sorted())") }
        guard !result.contactsRemain else { throw ReplayError.invariant("a contact remains active") }
        guard result.eventsAfterReset == 0 else { throw ReplayError.invariant("events emitted after forced final reset") }
        print("button, contact, gesture and reset invariants passed"
              + (result.dragLockEngagedBeforeFinalLiftoff ? " (drag lock released by the final lift-off)" : ""))
    }

}

do {
    try TGReplay.run(Array(CommandLine.arguments.dropFirst()))
} catch {
    fputs("tgreplay: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}

private struct SettingsChange: Decodable { let atNs: UInt64; let settings: TrackpadSettings }
