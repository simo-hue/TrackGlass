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
                                    forceFinalLiftoff: true)
            try checkInvariants(result)
            print("invariants passed (drop=\(fraction), seed=\(seed))")
        case "help", "--help", "-h": print(usage)
        default: throw ReplayError.usage(usage)
        }
    }

    private static let usage = """
    Usage:
      tgreplay run <name.tgrec> --settings <name.settings.json>
      tgreplay verify-dir <fixture-directory>
      tgreplay invariants <name.tgrec> --settings <name.settings.json> --drop <fraction> --seed <integer>
    """

    private static func replay(recording: URL, settingsURL: URL, dropFraction: Double = 0, seed: UInt64 = 1,
                               forceFinalLiftoff: Bool = false) throws -> ReplayResult {
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
        let engine = GestureEngine(settings: configuration.settings, geometry: configuration.geometry, acceleration: acceleration, scrollAcceleration: scrollAcceleration)
        var events: [GestureEvent] = []
        var frames: [TouchFrame] = []
        let ticks = (configuration.ticks ?? []).sorted()
        let changes = (configuration.geometryChanges ?? []).sorted { $0.atNs < $1.atNs }
        let settingsChanges = (configuration.settingsChanges ?? []).sorted { $0.atNs < $1.atNs }
        var settingsIndex = 0
        var tickIndex = 0, changeIndex = 0
        var random = seed
        while let record = try reader.next() {
            let frame = try record.frameBytes.withUnsafeBytes { try TouchFrameDecoder.decode($0) }
            while true {
                let tickTime = tickIndex < ticks.count ? ticks[tickIndex] : UInt64.max
                let changeTime = changeIndex < changes.count ? changes[changeIndex].atNs : UInt64.max
                let settingsTime = settingsIndex < settingsChanges.count ? settingsChanges[settingsIndex].atNs : UInt64.max
                // SPEC §6.10: scheduled against the frame's own clock, so Mac-recorded (origin 2) fixtures replay correctly.
                guard min(tickTime, changeTime, settingsTime) < frame.frameTime else { break }
                var buffer = EventBuffer()
                if settingsTime <= min(tickTime, changeTime) {
                    engine.setSettings(settingsChanges[settingsIndex].settings); settingsIndex += 1
                } else if tickTime < changeTime {
                    engine.tick(now: tickTime, into: &buffer); tickIndex += 1
                } else {
                    engine.setGeometry(changes[changeIndex].geometry, into: &buffer); changeIndex += 1
                }
                events.append(contentsOf: buffer.events)
            }
            if dropped(fraction: dropFraction, random: &random) { continue }
            frames.append(frame)
            var buffer = EventBuffer(); engine.process(frame, into: &buffer); events.append(contentsOf: buffer.events)
        }
        while tickIndex < ticks.count || changeIndex < changes.count || settingsIndex < settingsChanges.count {
            let tickTime = tickIndex < ticks.count ? ticks[tickIndex] : UInt64.max
            let changeTime = changeIndex < changes.count ? changes[changeIndex].atNs : UInt64.max
            let settingsTime = settingsIndex < settingsChanges.count ? settingsChanges[settingsIndex].atNs : UInt64.max
            var buffer = EventBuffer()
            if settingsTime <= min(tickTime, changeTime) {
                engine.setSettings(settingsChanges[settingsIndex].settings); settingsIndex += 1
            } else if tickTime < changeTime {
                engine.tick(now: tickTime, into: &buffer); tickIndex += 1
            } else {
                engine.setGeometry(changes[changeIndex].geometry, into: &buffer); changeIndex += 1
            }
            events.append(contentsOf: buffer.events)
        }
        if let releaseDragLock = configuration.forceLiftoffReleaseDragLock {
            var buffer = EventBuffer(); engine.forceLiftoff(releaseDragLock: releaseDragLock, into: &buffer)
            events.append(contentsOf: buffer.events)
        }
        let didForceFinalLiftoff = forceFinalLiftoff || dropFraction > 0
        if didForceFinalLiftoff {
            var buffer = EventBuffer(); engine.forceLiftoff(releaseDragLock: true, into: &buffer)
            events.append(contentsOf: buffer.events)
        }
        var afterReset = EventBuffer()
        if didForceFinalLiftoff {
            let latest = max(frames.last?.frameTime ?? 0, ticks.last ?? 0)
            engine.tick(now: latest > UInt64.max - 10_000_000_000 ? UInt64.max : latest + 10_000_000_000, into: &afterReset)
        }
        return ReplayResult(header: reader.header, events: events, frames: frames, forcedFinalLiftoff: didForceFinalLiftoff, contactsRemain: engine.hasActiveContacts, eventsAfterReset: afterReset.count)
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

    private static func checkInvariants(_ result: ReplayResult) throws {
        var heldButtons = Set<ButtonKind>()
        for event in result.events {
            if case let .button(kind, phase, _) = event {
                if phase == .down { heldButtons.insert(kind) }
                else { heldButtons.remove(kind) }
            }
        }
        if !heldButtons.isEmpty { throw ReplayError.invariant("a button remains down after replay: \(heldButtons)") }
        var gestures = Set<String>()
        func track(_ name: String, _ phase: GesturePhase) {
            switch phase {
            case .mayBegin, .began: gestures.insert(name)
            case .ended, .cancelled: gestures.remove(name)
            case .changed: break
            }
        }
        for event in result.events {
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
        guard gestures.isEmpty else { throw ReplayError.invariant("gestures remain active: \(gestures.sorted())") }
        guard result.forcedFinalLiftoff else { throw ReplayError.invariant("replay ended without a forced final lift-off") }
        guard !result.contactsRemain else { throw ReplayError.invariant("a contact remains active") }
        guard result.eventsAfterReset == 0 else { throw ReplayError.invariant("events emitted after forced final reset") }
        print("button, contact, gesture and reset invariants passed")
    }

}

do {
    try TGReplay.run(Array(CommandLine.arguments.dropFirst()))
} catch {
    fputs("tgreplay: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}

private struct SettingsChange: Decodable { let atNs: UInt64; let settings: TrackpadSettings }
