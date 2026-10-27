import Foundation
import TrackglassKit
import XCTest
@testable import TrackglassEngine

final class GestureFixtureTests: XCTestCase {
    func testRequiredContactFixtures() throws {
        for name in ["palm_ignored", "resting_thumb_ignored", "settle_window_second_finger",
                     "tap", "two_finger_tap", "corner_tap_left", "corner_tap_right",
                     "double_tap", "triple_tap", "double_tap_dragging_on", "tap_drag", "tap_drag_lock",
                     "three_finger_drag", "three_finger_tap_lookup", "liftoff_timeout",
                     "liftoff_timeout_releases_drag_lock", "contact_vanishes", "contact_id_reused", "scroll_vertical", "scroll_horizontal_disabled", "momentum_decay", "momentum_cancelled_by_touch", "pinch_only", "rotate_only", "scroll_then_pinch", "smart_zoom", "two_finger_tap_pending_then_click", "three_finger_swipe_spaces", "four_finger_mission_control", "four_finger_app_expose", "four_finger_pinch_launchpad", "four_finger_spread_desktop", "three_finger_swipe_nav", "rotation_cancels_gesture", "edge_swipe_notification_center", "force_click", "settings_change_deferred"] {
            let fixture = try load(name)
            let expected = try JSONDecoder().decode([GestureEvent].self, from: Data(contentsOf: fixture.expectedURL))
            let settings = try JSONDecoder().decode(FixtureSettings.self, from: Data(contentsOf: fixture.settingsURL))
            var reader = try TGRecReader(contentsOf: fixture.recordingURL)
            XCTAssertEqual(reader.header.origin.rawValue, TGRecHeader.Origin.phone.rawValue, name)
            XCTAssertEqual(settings.acceleration.model, "unitGain", name)
            let engine = GestureEngine(settings: settings.settings, geometry: settings.geometry,
                                       acceleration: UnitGainAcceleration(), scrollAcceleration: UnitGainAcceleration())
            var actual: [GestureEvent] = []
            let ticks = (settings.ticks ?? []).sorted()
            let geometryChanges = (settings.geometryChanges ?? []).sorted { $0.atNs < $1.atNs }
            let settingsChanges = (settings.settingsChanges ?? []).sorted { $0.atNs < $1.atNs }
            var settingsIndex = 0
            var tickIndex = 0, geometryIndex = 0
            while let record = try reader.next() {
                let frame = try record.frameBytes.withUnsafeBytes { try TouchFrameDecoder.decode($0) }
                while true {
                    let nextTick = tickIndex < ticks.count ? ticks[tickIndex] : UInt64.max
                    let nextGeometry = geometryIndex < geometryChanges.count ? geometryChanges[geometryIndex].atNs : UInt64.max
                    let settingsTime = settingsIndex < settingsChanges.count ? settingsChanges[settingsIndex].atNs : UInt64.max
                    guard min(nextTick, nextGeometry, settingsTime) < frame.frameTime else { break }
                    var events = EventBuffer()
                    if settingsTime <= min(nextTick, nextGeometry) {
                        engine.setSettings(settingsChanges[settingsIndex].settings); settingsIndex += 1
                    } else if nextTick < nextGeometry {
                        engine.tick(now: nextTick, into: &events); tickIndex += 1
                    } else {
                        engine.setGeometry(geometryChanges[geometryIndex].geometry, into: &events); geometryIndex += 1
                    }
                    actual.append(contentsOf: events.events)
                }
                var events = EventBuffer(); engine.process(frame, into: &events); actual.append(contentsOf: events.events)
            }
            while tickIndex < ticks.count || geometryIndex < geometryChanges.count || settingsIndex < settingsChanges.count {
                let nextTick = tickIndex < ticks.count ? ticks[tickIndex] : UInt64.max
                let nextGeometry = geometryIndex < geometryChanges.count ? geometryChanges[geometryIndex].atNs : UInt64.max
                let settingsTime = settingsIndex < settingsChanges.count ? settingsChanges[settingsIndex].atNs : UInt64.max
                var events = EventBuffer()
                if settingsTime <= min(nextTick, nextGeometry) {
                    engine.setSettings(settingsChanges[settingsIndex].settings); settingsIndex += 1
                } else if nextTick < nextGeometry {
                    engine.tick(now: nextTick, into: &events); tickIndex += 1
                } else {
                    engine.setGeometry(geometryChanges[geometryIndex].geometry, into: &events); geometryIndex += 1
                }
                actual.append(contentsOf: events.events)
            }
            if let releaseDragLock = settings.forceLiftoffReleaseDragLock {
                var events = EventBuffer(); engine.forceLiftoff(releaseDragLock: releaseDragLock, into: &events)
                actual.append(contentsOf: events.events)
            }
            XCTAssertTrue(GestureEvent.approximatelyEqual(actual, expected),
                          "\(name)\nexpected: \(expected)\nactual:   \(actual)")
        }
    }

    func testApproximateComparisonToleratesFloatingPointNoiseOnly() {
        let base = GestureEvent.scroll(dxPoints: 0, dyPoints: 0.2, phase: .changed, naturalInverted: true)
        XCTAssertTrue(base.approximatelyEquals(.scroll(dxPoints: 0, dyPoints: 0.19999999999999996, phase: .changed, naturalInverted: true)))
        XCTAssertFalse(base.approximatelyEquals(.scroll(dxPoints: 0, dyPoints: 0.2001, phase: .changed, naturalInverted: true)))
        XCTAssertFalse(base.approximatelyEquals(.scroll(dxPoints: 0, dyPoints: 0.2, phase: .ended, naturalInverted: true)))
        XCTAssertFalse(base.approximatelyEquals(.scroll(dxPoints: 0, dyPoints: 0.2, phase: .changed, naturalInverted: false)))
        XCTAssertFalse(GestureEvent.approximatelyEqual([base], [base, base]))
    }

    func testGestureEventUsesSpecifiedJSONShape() throws {
        let event = GestureEvent.scroll(dxPoints: 0, dyPoints: -12, phase: .changed, naturalInverted: true)
        let data = try JSONEncoder().encode(event)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["t"] as? String, "scroll")
        XCTAssertEqual(object["phase"] as? String, "changed")
        XCTAssertEqual(object["naturalInverted"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(GestureEvent.self, from: data), event)
    }

    func testFixtureBuilderWritesReadableRecording() throws {
        var frame = TouchFrame(sequence: 0, frameTime: 10)
        frame.append(Contact(contactID: 1, phase: .began, x: 1, y: 2))
        let data = try FixtureBuilder.recording(widthMM: 65, heightMM: 141, frames: [(10, frame)])
        var reader = try TGRecReader(data: data)
        XCTAssertEqual(reader.header.surfaceWidthMM, 65)
        XCTAssertEqual(try reader.next()?.captureTimeNs, 10)
        XCTAssertNil(try reader.next())
    }

    private func load(_ name: String) throws -> (recordingURL: URL, settingsURL: URL, expectedURL: URL) {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let directory = root.appendingPathComponent("Tests/Fixtures", isDirectory: true)
        return (directory.appendingPathComponent("\(name).tgrec"),
                directory.appendingPathComponent("\(name).settings.json"),
                directory.appendingPathComponent("\(name).expected.json"))
    }
}

private struct FixtureSettings: Decodable {
    let settings: TrackpadSettings
    let geometry: EngineGeometry
    let ticks: [UInt64]?
    let acceleration: FixtureAcceleration
    let geometryChanges: [FixtureGeometryChange]?
    let settingsChanges: [FixtureSettingsChange]?
    let forceLiftoffReleaseDragLock: Bool?
}

private struct FixtureAcceleration: Decodable { let model: String }
private struct FixtureGeometryChange: Decodable { let atNs: UInt64; let geometry: EngineGeometry }

private enum FixtureBuilder {
    static func recording(widthMM: Double, heightMM: Double, frames: [(UInt64, TouchFrame)]) throws -> Data {
        var writer = TGRecWriter(header: try TGRecHeader(origin: .phone, surfaceWidthMM: widthMM, surfaceHeightMM: heightMM))
        for (time, frame) in frames {
            var bytes = [UInt8](repeating: 0, count: TouchFrame.maximumByteCount)
            let count = try bytes.withUnsafeMutableBytes { try TouchFrameEncoder(frame: frame).encode(into: $0) }
            try writer.append(captureTimeNs: time, frameBytes: Data(bytes.prefix(count)))
        }
        return writer.data
    }
}

private struct FixtureSettingsChange: Decodable { let atNs: UInt64; let settings: TrackpadSettings }
