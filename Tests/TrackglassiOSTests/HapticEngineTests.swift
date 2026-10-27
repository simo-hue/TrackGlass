import XCTest
@testable import TrackglassiOS

final class HapticEngineTests: XCTestCase {
    func testPatternsMatchGestureKinds() {
        XCTAssertEqual(HapticEngine.pulses(for: 1), [.init(time: 0, intensity: 0.85, sharpness: 0.9)])
        XCTAssertEqual(HapticEngine.pulses(for: 2), [.init(time: 0, intensity: 0.7, sharpness: 0.6)])
        XCTAssertEqual(HapticEngine.pulses(for: 3), [.init(time: 0, intensity: 0.6, sharpness: 0.9), .init(time: 0.06, intensity: 1, sharpness: 1)])
        XCTAssertEqual(HapticEngine.pulses(for: 4).first?.intensity, 0.5)
        XCTAssertEqual(HapticEngine.pulses(for: 5).first?.intensity, 0.35)
        XCTAssertEqual(HapticEngine.pulses(for: 6).first?.sharpness, 0.8)
        XCTAssertTrue(HapticEngine.pulses(for: 0).isEmpty)
    }
    @MainActor func testPreferencesPersistAndClampStrength() throws {
        let suite = "HapticEngineTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = HapticEngine(defaults: defaults)
        XCTAssertTrue(engine.enabled); XCTAssertEqual(engine.strength, 1)
        engine.enabled = false; engine.strength = 0
        let restored = HapticEngine(defaults: defaults)
        XCTAssertFalse(restored.enabled); XCTAssertEqual(restored.strength, 0.5)
        restored.strength = 2; XCTAssertEqual(restored.strength, 1)
        restored.strength = .nan; XCTAssertEqual(restored.strength, 1)
    }
}
