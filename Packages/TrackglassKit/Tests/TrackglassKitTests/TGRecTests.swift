import Foundation
import XCTest
@testable import TrackglassKit

final class TGRecTests: XCTestCase {
    private func frameBytes(_ index: Int) throws -> Data {
        var frame = TouchFrame(sequence: UInt32(index), sentAt: UInt64(index * 8000), frameTime: UInt64(index * 8000 - min(index, 1)))
        for contact in 0..<(index % 11) {
            frame.append(Contact(contactID: UInt8(contact), phase: .moved, x: Float(index), y: Float(contact)))
        }
        var bytes = Data(count: 28 + 16 * frame.contactCount)
        _ = try bytes.withUnsafeMutableBytes { try TouchFrameEncoder(frame: frame).encode(into: $0) }
        return bytes
    }

    func test500RecordsForBothOrigins() throws {
        for origin in [TGRecHeader.Origin.phone, .mac] {
            let header = try TGRecHeader(origin: origin, surfaceWidthMM: 65.1, surfaceHeightMM: 141.1)
            var writer = TGRecWriter(header: header)
            for index in 0..<500 {
                try writer.append(captureTimeNs: UInt64(index * 8000 + 1000), frameBytes: frameBytes(index))
            }
            XCTAssertEqual(Array(writer.data.prefix(7)), [0x54, 0x47, 0x52, 0x45, 0x43, 1, origin.rawValue])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("tgrec")
            defer { try? FileManager.default.removeItem(at: url) }
            try writer.write(to: url)
            var reader = try TGRecReader(contentsOf: url)
            XCTAssertEqual(reader.header, header)
            for index in 0..<500 {
                let record = try XCTUnwrap(reader.next())
                XCTAssertEqual(record.captureTimeNs, UInt64(index * 8000 + 1000))
                XCTAssertEqual(record.frameBytes, try frameBytes(index))
            }
            XCTAssertNil(try reader.next())
        }
    }

    func testFileWriterStreamsRecordsAndMatchesTheInMemoryWriter() throws {
        let header = try TGRecHeader(origin: .phone, surfaceWidthMM: 65.1, surfaceHeightMM: 141.1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("tgrec")
        defer { try? FileManager.default.removeItem(at: url) }
        var reference = TGRecWriter(header: header)
        let writer = try TGRecFileWriter(header: header, url: url)
        // Enough records to cross the writer's flush threshold several times.
        for index in 0..<2_000 {
            let bytes = try frameBytes(index)
            try reference.append(captureTimeNs: UInt64(index), frameBytes: bytes)
            try bytes.withUnsafeBytes { try writer.append(captureTimeNs: UInt64(index), frameBytes: $0) }
        }
        XCTAssertEqual(writer.recordCount, 2_000)
        // The header is on disk before the first flush, so a crash mid-session leaves a readable prefix.
        XCTAssertNoThrow(try TGRecReader(contentsOf: url))
        try writer.finish()
        try writer.finish()   // idempotent
        XCTAssertEqual(try Data(contentsOf: url), reference.data)
        XCTAssertThrowsError(try writer.append(captureTimeNs: 0, frameBytes: try frameBytes(1)))
        XCTAssertThrowsError(try TGRecFileWriter(header: header, url: url).append(captureTimeNs: 0, frameBytes: Data(count: 5)))
    }

    func testBadHeaders() throws {
        let data = TGRecWriter(header: try TGRecHeader(origin: .mac, surfaceWidthMM: 10, surfaceHeightMM: 20)).data
        for length in 0..<15 { XCTAssertThrowsError(try TGRecReader(data: Data(data.prefix(length)))) }
        for offset in 0..<7 {
            var bad = data
            bad[offset] = 0xFF
            XCTAssertThrowsError(try TGRecReader(data: bad))
        }
        XCTAssertThrowsError(try TGRecHeader(origin: .mac, surfaceWidthMM: .nan, surfaceHeightMM: 20))
    }

    func testTruncatedRecordAndInvalidLength() throws {
        var writer = TGRecWriter(header: try TGRecHeader(origin: .phone, surfaceWidthMM: 10, surfaceHeightMM: 20))
        try writer.append(captureTimeNs: .max, frameBytes: frameBytes(1))
        for length in 16..<writer.data.count {
            var reader = try TGRecReader(data: Data(writer.data.prefix(length)))
            XCTAssertThrowsError(try reader.next())
        }
        var bad = writer.data
        bad[23] = 0xFF; bad[24] = 0xFF
        var reader = try TGRecReader(data: bad)
        XCTAssertThrowsError(try reader.next()) { XCTAssertEqual($0 as? TGRecError, .invalidFrameLength) }
    }
}
