import Foundation
import XCTest
@testable import TrackglassKit

final class TouchFrameTests: XCTestCase {
    private func makeFrame(count: Int) -> TouchFrame {
        var frame = TouchFrame(sequence: 42, sentAt: 123456, frameTime: 123000,
                               surfaceIsLandscape: true, isSyntheticLiftoff: true)
        for index in 0..<count {
            frame.append(Contact(contactID: UInt8(index), phase: Contact.Phase(rawValue: UInt8(index % 5 + 1))!,
                                 kind: index % 2 == 0 ? .finger : .stylus,
                                 x: Float(index) + 0.5, y: -Float(index), majorRadius: 4.25))
        }
        return frame
    }

    func testRoundTrips() throws {
        for count in [0, 1, 5, 10] {
            let frame = makeFrame(count: count)
            var data = Data(count: TouchFrame.maximumByteCount)
            let length = try data.withUnsafeMutableBytes { try TouchFrameEncoder(frame: frame).encode(into: $0) }
            XCTAssertEqual(length, 28 + count * 16)
            let result = try data.prefix(length).withUnsafeBytes { try TouchFrameDecoder.decode($0) }
            XCTAssertEqual(result.header, frame.header)
            XCTAssertEqual(result.frameTime, frame.frameTime)
            XCTAssertEqual(result.contactCount, count)
            XCTAssertTrue(result.surfaceIsLandscape)
            XCTAssertTrue(result.isSyntheticLiftoff)
            for index in 0..<count { XCTAssertEqual(result[index], frame[index]) }
        }
    }

    func testFlagsAndWireLayout() throws {
        for flags in UInt8(0)...3 {
            var frame = makeFrame(count: 1)
            frame.surfaceIsLandscape = flags & 1 != 0
            frame.isSyntheticLiftoff = flags & 2 != 0
            var data = Data(count: 44)
            _ = try data.withUnsafeMutableBytes { try TouchFrameEncoder(frame: frame).encode(into: $0) }
            XCTAssertEqual(data[25], flags)
            XCTAssertEqual(Array(data[26..<32]), [0, 0, 0, 1, 1, 0])
            XCTAssertEqual(Array(data[32..<36]), [0, 0, 0, 0x3F])
            let decoded = try data.withUnsafeBytes { try TouchFrameDecoder.decode($0) }
            XCTAssertEqual(decoded.surfaceIsLandscape, frame.surfaceIsLandscape)
            XCTAssertEqual(decoded.isSyntheticLiftoff, frame.isSyntheticLiftoff)
        }
    }

    func testCapacityAndMalformedFrames() throws {
        var frame = makeFrame(count: 10)
        XCTAssertFalse(frame.append(Contact()))
        frame.removeAllContacts()
        XCTAssertEqual(frame.contactCount, 0)
        var valid = Data(count: 28)
        _ = try valid.withUnsafeMutableBytes { try TouchFrameEncoder(frame: frame).encode(into: $0) }
        for length in 0..<28 {
            XCTAssertThrowsError(try valid.prefix(length).withUnsafeBytes { try TouchFrameDecoder.decode($0) })
        }
        for (offset, value) in [(24, UInt8(11)), (25, 4), (26, 1), (27, 1), (3, 1)] {
            var bad = valid
            bad[offset] = value
            XCTAssertThrowsError(try bad.withUnsafeBytes { try TouchFrameDecoder.decode($0) })
        }
        XCTAssertThrowsError(try (valid + Data([0])).withUnsafeBytes { try TouchFrameDecoder.decode($0) })
    }

    func testFuzz10000Inputs() {
        var state: UInt64 = 0xA172F7
        func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1
            return state
        }
        for iteration in 0..<10_000 {
            let size = Int(next() % 220)
            var data = Data((0..<size).map { _ in UInt8(truncatingIfNeeded: next() >> 32) })
            if iteration % 2 == 0 && size >= 28 {
                data[0] = 0x54; data[1] = 0x47; data[2] = 1; data[3] = 0x10
                data[24] = UInt8((size - 28) / 16)
                data[25] &= 3; data[26] = 0; data[27] = 0
            }
            _ = try? data.withUnsafeBytes { try TouchFrameDecoder.decode($0) }
        }
    }

    func testEncodePerformance() throws {
        let encoder = TouchFrameEncoder(frame: makeFrame(count: 10))
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 188, alignment: 8)
        defer { buffer.deallocate() }
        let iterations = 100_000
        var elapsed: UInt64 = 0
        measure {
            let start = MonotonicClock.nanoseconds()
            for _ in 0..<iterations { _ = try! encoder.encode(into: buffer) }
            elapsed = MonotonicClock.nanoseconds() - start
        }
        #if !DEBUG
        XCTAssertLessThanOrEqual(Double(elapsed) / Double(iterations), 300)
        #endif
        XCTAssertEqual(buffer[24], 10)
    }
}
