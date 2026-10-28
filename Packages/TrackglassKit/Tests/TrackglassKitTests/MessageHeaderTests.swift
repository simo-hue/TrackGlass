import Foundation
import XCTest
@testable import TrackglassKit

final class MessageHeaderTests: XCTestCase {
    func testRoundTripEveryType() throws {
        for type in MessageType.allCases {
            let header = MessageHeader(type: type, sequence: .max, sentAt: .max)
            var bytes = Data(count: 16)
            XCTAssertEqual(try bytes.withUnsafeMutableBytes { try header.encode(into: $0) }, 16)
            XCTAssertEqual(try bytes.withUnsafeBytes { try MessageHeader.decode($0) }, header)
        }
    }

    func testWireBytesAndUnalignedDecode() throws {
        let header = MessageHeader(type: .touchFrame, sequence: 0x12345678, sentAt: 0x0102030405060708)
        var bytes = Data(count: 16)
        _ = try bytes.withUnsafeMutableBytes { try header.encode(into: $0) }
        XCTAssertEqual(Array(bytes), [0x54, 0x47, 1, 0x10, 0x78, 0x56, 0x34, 0x12, 8, 7, 6, 5, 4, 3, 2, 1])
        let unaligned = Data([0]) + bytes
        XCTAssertEqual(try unaligned.withUnsafeBytes {
            try MessageHeader.decode(UnsafeRawBufferPointer(rebasing: $0[1...]))
        }, header)
    }

    func testMalformedHeaders() throws {
        var bytes = Data(count: 16)
        _ = try bytes.withUnsafeMutableBytes { try MessageHeader(type: .ping, sequence: 0, sentAt: 0).encode(into: $0) }
        for length in 0..<16 {
            XCTAssertThrowsError(try bytes.prefix(length).withUnsafeBytes { try MessageHeader.decode($0) }) {
                XCTAssertEqual($0 as? ProtocolError, .truncated)
            }
        }
        bytes[0] = 0x47
        bytes[1] = 0x54
        XCTAssertThrowsError(try bytes.withUnsafeBytes { try MessageHeader.decode($0) }) {
            XCTAssertEqual($0 as? ProtocolError, .badMagic)
        }
        bytes[0] = 0x54
        bytes[1] = 0x47
        bytes[2] = 2
        XCTAssertThrowsError(try bytes.withUnsafeBytes { try MessageHeader.decode($0) }) {
            XCTAssertEqual($0 as? ProtocolError, .incompatibleVersion(2))
        }
    }

    func testUnknownTypeIsPreservedAndSmallOutputRejected() throws {
        let header = MessageHeader(type: UInt8(0xFF), sequence: 0, sentAt: 0)
        var bytes = Data(count: 16)
        _ = try bytes.withUnsafeMutableBytes { try header.encode(into: $0) }
        XCTAssertEqual(try bytes.withUnsafeBytes { try MessageHeader.decode($0) }.type, 0xFF)
        var short = Data(count: 15)
        XCTAssertThrowsError(try short.withUnsafeMutableBytes { try header.encode(into: $0) }) {
            XCTAssertEqual($0 as? ProtocolError, .bufferTooSmall)
        }
    }

    func testMonotonicClock() {
        let start = MonotonicClock.nanoseconds()
        Thread.sleep(forTimeInterval: 0.002)
        let end = MonotonicClock.nanoseconds()
        XCTAssertGreaterThan(end, start)
        XCTAssertGreaterThanOrEqual(end - start, 2_000_000)
    }

    func testSequenceOrderingAndGapsAcrossWrap() {
        XCTAssertTrue(MessageHeader.sequence(1, isNewerThan: 0))
        XCTAssertTrue(MessageHeader.sequence(0, isNewerThan: 0xFFFF_FFFF))
        XCTAssertFalse(MessageHeader.sequence(5, isNewerThan: 5))
        XCTAssertFalse(MessageHeader.sequence(4, isNewerThan: 5))
        XCTAssertFalse(MessageHeader.sequence(0xFFFF_FFFF, isNewerThan: 0))
        XCTAssertEqual(MessageHeader.gap(from: 10, to: 11), 0)
        XCTAssertEqual(MessageHeader.gap(from: 10, to: 14), 3)
        XCTAssertEqual(MessageHeader.gap(from: 0xFFFF_FFFE, to: 1), 2)
        XCTAssertNil(MessageHeader.gap(from: 7, to: 7))
        XCTAssertNil(MessageHeader.gap(from: 7, to: 3))
    }
}
