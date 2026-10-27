import CoreGraphics
import XCTest
import TrackglassEngine
@testable import TrackglassMac

final class ScrollInjectorTests: XCTestCase {
    func testMomentumHasNoGestureCompanionAndPreservesNaturalFlag() {
        var captured: [CGEvent] = []
        let injector = QuartzInjector(postScrollEvent: { captured.append($0) })
        injector.inject(.scroll(dxPoints: 0, dyPoints: -10, phase: .began, naturalInverted: false))
        captured.removeAll()
        for phase in [MomentumPhase.begin, .continued, .end] {
            injector.inject(.scrollMomentum(phase: phase, dxPoints: 0, dyPoints: phase == .end ? 0 : -8))
        }
        XCTAssertEqual(captured.count, 3)
        for (index, event) in captured.enumerated() {
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventScrollPhase), 0)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventMomentumPhase), Int64(index + 1))
            XCTAssertEqual(event.getIntegerValueField(TGFieldDirectionInvertedFromDevice), 0)
        }
    }
    func testInjectorPostsWheelThenGestureWithAllSpecifiedFields() throws {
        for natural in [true, false] {
            var captured: [CGEvent] = []
            let injector = QuartzInjector(postScrollEvent: { captured.append($0) })
            let sign = natural ? 1.0 : -1.0
            injector.inject(.scroll(dxPoints: 20 * sign, dyPoints: 30 * sign, phase: .began, naturalInverted: natural))
            XCTAssertEqual(captured.count, 2)
            let wheel = try XCTUnwrap(captured.first)
            let companion = try XCTUnwrap(captured.last)
            XCTAssertEqual(wheel.type, .scrollWheel)
            XCTAssertEqual(wheel.getIntegerValueField(TGFieldEventType), Int64(CGEventType.scrollWheel.rawValue))
            XCTAssertEqual(wheel.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
            XCTAssertEqual(wheel.getIntegerValueField(TGFieldDirectionInvertedFromDevice), natural ? 1 : 0)
            XCTAssertEqual(wheel.getIntegerValueField(.scrollWheelEventDeltaAxis1), Int64(3 * sign))
            XCTAssertEqual(wheel.getIntegerValueField(.scrollWheelEventDeltaAxis2), Int64(2 * sign))
            XCTAssertEqual(wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), Int64(30 * sign))
            XCTAssertEqual(wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), Int64(20 * sign))
            XCTAssertEqual(wheel.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1), Int64(3 * sign * 65_536))
            XCTAssertEqual(wheel.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2), Int64(2 * sign * 65_536))
            XCTAssertEqual(wheel.getIntegerValueField(.scrollWheelEventScrollPhase), Int64(TGPhaseBegan))
            XCTAssertEqual(wheel.getIntegerValueField(.scrollWheelEventMomentumPhase), Int64(TGMomentumNone))
            XCTAssertEqual(companion.type, TGEventTypeGesture)
            XCTAssertEqual(companion.getIntegerValueField(TGFieldEventType), Int64(TGEventTypeGesture.rawValue))
            XCTAssertEqual(companion.getIntegerValueField(TGFieldHIDEventType), Int64(TGHIDScroll))
            XCTAssertEqual(companion.getIntegerValueField(TGFieldGesturePhase), Int64(TGPhaseBegan))
            XCTAssertEqual(companion.getDoubleValueField(TGFieldGestureDeltaX), 20 * sign * 1.67, accuracy: 0.00001)
            XCTAssertEqual(companion.getDoubleValueField(TGFieldGestureDeltaY), 30 * sign * 1.67, accuracy: 0.00001)
            XCTAssertEqual(companion.location, wheel.location)
            XCTAssertEqual(companion.timestamp, wheel.timestamp)
        }
    }

    func testSubpointAndSublineMotionAccumulatesAndResetsBetweenGestures() throws {
        let factory = ScrollEventFactory()
        var points: Int64 = 0, lines: Int64 = 0
        for index in 0..<40 {
            let pair = try XCTUnwrap(factory.make(dx: 0, dy: 0.25, phase: index == 0 ? .began : .changed,
                natural: true, source: nil, location: .zero))
            points += pair.wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            lines += pair.wheel.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        }
        XCTAssertEqual(points, 10)
        XCTAssertEqual(lines, 1)
        for (phase, expected) in [(GesturePhase.ended, TGPhaseEnded), (.cancelled, TGPhaseCancelled), (.mayBegin, TGPhaseMayBegin)] {
            let pair = try XCTUnwrap(factory.make(dx: 99, dy: 99, phase: phase,
                natural: true, source: nil, location: .zero))
            XCTAssertEqual(pair.wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 0)
            XCTAssertEqual(pair.wheel.getIntegerValueField(.scrollWheelEventScrollPhase), Int64(expected))
            XCTAssertEqual(pair.companion.getIntegerValueField(TGFieldGesturePhase), Int64(expected))
            XCTAssertEqual(pair.companion.getDoubleValueField(TGFieldGestureDeltaY), 0)
        }
    }
}
