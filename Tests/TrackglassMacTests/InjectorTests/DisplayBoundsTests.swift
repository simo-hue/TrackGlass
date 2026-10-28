import CoreGraphics
import XCTest
@testable import TrackglassMac

/// SPEC §6.7 multi-display clamp with edge sliding, driven with synthetic display rectangles.
final class DisplayBoundsTests: XCTestCase {
    // Main display 1512 × 982 at the origin; a second display to its right, vertically offset.
    private let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let side = CGRect(x: 1512, y: 200, width: 1920, height: 1080)
    private var screens: [CGRect] { [main, side] }

    func testPointInsideAnyDisplayIsAccepted() {
        XCTAssertEqual(DisplayBounds.resolve(CGPoint(x: 100, y: 100), from: CGPoint(x: 90, y: 100), screens: screens), CGPoint(x: 100, y: 100))
        XCTAssertEqual(DisplayBounds.resolve(CGPoint(x: 1600, y: 500), from: CGPoint(x: 1500, y: 500), screens: screens), CGPoint(x: 1600, y: 500))
    }

    func testCrossingBetweenDisplaysIsAccepted() {
        let crossed = DisplayBounds.resolve(CGPoint(x: 1515, y: 600), from: CGPoint(x: 1510, y: 600), screens: screens)
        XCTAssertEqual(crossed, CGPoint(x: 1515, y: 600))
    }

    func testSlidesAlongAnEdgeInsteadOfStopping() {
        // Moving up-and-right out of the main display's top edge keeps the horizontal component.
        let slid = DisplayBounds.resolve(CGPoint(x: 310, y: -5), from: CGPoint(x: 300, y: 2), screens: screens)
        XCTAssertEqual(slid, CGPoint(x: 310, y: 2))
        // Moving down-and-right into the gap below the side display keeps the vertical component.
        let vertical = DisplayBounds.resolve(CGPoint(x: 1520, y: 100), from: CGPoint(x: 1505, y: 90), screens: screens)
        XCTAssertEqual(vertical, CGPoint(x: 1505, y: 100))
    }

    func testClampsIntoTheCurrentDisplayWhenNoSlideFits() {
        let corner = DisplayBounds.resolve(CGPoint(x: -20, y: -20), from: CGPoint(x: 3, y: 3), screens: screens)
        XCTAssertEqual(corner, CGPoint(x: 0, y: 0))
        let far = DisplayBounds.resolve(CGPoint(x: 5000, y: 5000), from: CGPoint(x: 3000, y: 1000), screens: screens)
        XCTAssertEqual(far.x, side.maxX.nextDown)
        XCTAssertEqual(far.y, side.maxY.nextDown)
    }

    func testCurrentPointOutsideEveryDisplayClampsIntoTheNearestOne() {
        // §8.4: between an unplug and the reconfiguration callback the pointer may sit on a vanished display.
        let point = DisplayBounds.resolve(CGPoint(x: 1800, y: 100), from: CGPoint(x: 1800, y: 50), screens: screens)
        XCTAssertTrue(side.contains(point), "\(point)")
        XCTAssertEqual(point, CGPoint(x: 1800, y: 200))
        let left = DisplayBounds.resolve(CGPoint(x: -300, y: 400), from: CGPoint(x: -310, y: 400), screens: screens)
        XCTAssertEqual(left, CGPoint(x: 0, y: 400))
    }

    func testNoDisplaysLeavesThePointAlone() {
        XCTAssertEqual(DisplayBounds.resolve(CGPoint(x: 7, y: 9), from: .zero, screens: []), CGPoint(x: 7, y: 9))
    }
}
