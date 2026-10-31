import XCTest
import UIKit
import TrackglassKit
@testable import TrackglassiOS

final class TouchCaptureTests: XCTestCase {
    func testPoolExhaustionAndRelease() {
        var pool = ContactIDPool()
        var ids = Set<UInt8>()
        for _ in 0..<256 { ids.insert(pool.acquire()!) }
        XCTAssertEqual(ids.count, 256)
        XCTAssertNil(pool.acquire())
        pool.release(42)
        pool.release(42)
        XCTAssertEqual(pool.acquire(), 42)
        XCTAssertNil(pool.acquire(), "Duplicate release must not make a live ID available")
    }

    func testReleasedIDsAreReusedLeastRecentlyReleasedFirst() {
        // M5 (§4.4, §5.2): a FIFO ring, so a lifted finger's ID is not the next finger's (lost datagrams would make
        // the Mac continue the old contact as a pointer jump).
        var pool = ContactIDPool()
        XCTAssertEqual(pool.acquire(), 0)
        pool.release(0)
        XCTAssertEqual(pool.acquire(), 1, "the ID just released goes to the back of the queue")
        var order: [UInt8] = []
        while let id = pool.acquire() { order.append(id) }
        XCTAssertEqual(order, (2...255).map(UInt8.init) + [0])
        pool.release(7); pool.release(3); pool.release(200); pool.release(3)
        XCTAssertEqual(pool.acquire(), 7)
        XCTAssertEqual(pool.acquire(), 3)
        XCTAssertEqual(pool.acquire(), 200)
        XCTAssertNil(pool.acquire(), "a duplicate release is not queued twice")
    }

    func testOneFingerTappingRepeatedlyGetsAFreshIDEachTime() {
        let table = LiveContactTable<NSObject>()
        var ids: [UInt8] = []
        for _ in 0..<300 {
            let touch = NSObject()
            ids.append(table.insert(touch)!)
            table.remove(touch)
        }
        XCTAssertEqual(Array(ids.prefix(256)), (0...255).map(UInt8.init), "every ID is used once before any comes back")
        XCTAssertEqual(Array(ids.suffix(44)), (0..<44).map(UInt8.init))
    }

    func testTenSlotsRetainTouchesAndRejectOverflow() {
        let table = LiveContactTable<NSObject>()
        let touches = (0..<10).map { _ in NSObject() }
        let ids = touches.map { table.insert($0)! }
        XCTAssertEqual(Set(ids).count, 10)
        XCTAssertEqual(table.count, 10)
        XCTAssertEqual(table.insert(touches[0]), ids[0])
        XCTAssertEqual(table.count, 10)
        XCTAssertNil(table.insert(NSObject()))
        table.remove(touches[4])
        table.remove(touches[4])
        let replacement = NSObject()
        // The freed slot is reused; the freed ID waits behind the never-used ones (FIFO reuse, M5).
        XCTAssertEqual(table.insert(replacement), 10)
        XCTAssertTrue(table[4]?.touch === replacement)
        XCTAssertEqual(table.count, 10)
        for index in 0..<10 where index != 4 {
            XCTAssertTrue(table[index]?.touch === touches[index])
            XCTAssertEqual(table[index]?.contactID, ids[index])
        }
    }

    func testContactIsRetainedUntilRemoval() {
        let table = LiveContactTable<NSObject>()
        weak var retained: NSObject?
        do {
            let touch = NSObject()
            retained = touch
            table.insert(touch)
        }
        XCTAssertNotNil(retained)
        table.remove(retained!)
        XCTAssertNil(retained)
        XCTAssertEqual(table.count, 0)
    }

    func testRepeatedLifetimesDoNotReuseLiveIDs() {
        let table = LiveContactTable<NSObject>()
        let held = NSObject()
        let heldID = table.insert(held)
        for _ in 0..<600 {
            let transient = NSObject()
            let id = table.insert(transient)
            XCTAssertNotNil(id)
            XCTAssertNotEqual(id, heldID)
            table.remove(transient)
        }
        XCTAssertEqual(table.count, 1)
        XCTAssertEqual(table.insert(held), heldID)
    }

    func testPhaseAndKindMappingExcludeHoverAndIndirectInput() {
        XCTAssertEqual(TouchSample.phase(.began), .began)
        XCTAssertEqual(TouchSample.phase(.moved), .moved)
        XCTAssertEqual(TouchSample.phase(.stationary), .stationary)
        XCTAssertEqual(TouchSample.phase(.ended)?.rawValue, 4)
        XCTAssertEqual(TouchSample.phase(.cancelled)?.rawValue, 5)
        XCTAssertNil(TouchSample.phase(.regionEntered))
        XCTAssertNil(TouchSample.phase(.regionMoved))
        XCTAssertNil(TouchSample.phase(.regionExited))
        XCTAssertEqual(TouchSample.kind(.direct), .finger)
        XCTAssertEqual(TouchSample.kind(.pencil)?.rawValue, 2)
        XCTAssertNil(TouchSample.kind(.indirect))
        XCTAssertNil(TouchSample.kind(.indirectPointer))
    }

    func testPhysicalCoordinatesRadiusAndEventTime() {
        let geometry = SurfaceGeometry(ppi: 460, nativeScale: 3,
                                       boundsInPoints: SurfaceSize(width: 393, height: 852))
        let contact = TouchSample.contact(id: 17, phase: .ended, kind: .finger,
                                          location: CGPoint(x: 50 / geometry.mmPerPoint, y: 10 / geometry.mmPerPoint),
                                          majorRadius: 12, geometry: geometry)
        XCTAssertEqual(contact.contactID, 17)
        XCTAssertEqual(contact.phase, .ended)
        XCTAssertEqual(contact.x, 50, accuracy: 0.0001)
        XCTAssertEqual(contact.y, 10, accuracy: 0.0001)
        XCTAssertEqual(contact.majorRadius, Float(12 * geometry.mmPerPoint), accuracy: 0.0001)
        XCTAssertEqual(TouchSample.timestampNanoseconds(123.25), 123_250_000_000)
    }
}
