import Foundation
import XCTest
@testable import TrackglassKit

final class ControlMessageTests: XCTestCase {
    private let peer = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
    private let settings = SettingsMessage(naturalScrolling: 1, tapToClick: 1, forceClickEnabled: 0,
                                           hapticsSuggested: 1, trackingSpeed: 1.25, secondaryClickMode: 2)

    private var messages: [ControlMessage] {
        [
            .hello(HelloMessage(protocolVersion: 1, peerID: peer, name: "Téléphone 📱", modelIdentifier: "iPhone16,2",
                                surfaceWidthMM: 65, surfaceHeightMM: 141, ppi: 460, maxContacts: 10,
                                displayHz: 120, caps: 3, trackingOverride: -0.5)),
            .welcome(WelcomeMessage(status: 0, macPeerID: peer, macName: "Mac", macOSVersion: "27.0.1",
                                    injectorMode: 1, settings: settings)),
            .settings(settings), .ping(PingMessage(nonce: .max)),
            .pong(PongMessage(nonce: 123, echoSentAt: .max)),
            .haptic(HapticMessage(kind: 6, intensity: 255)),
            .status(StatusMessage(lossPermille: 2, rttMicros: 300, framesPerSecond: 120,
                                  pipelineP50Micros: 400, pipelineP95Micros: 900, engineState: 4)),
            .surface(SurfaceMessage(surfaceWidthMM: 141, surfaceHeightMM: 65, ppi: 460, trackingOverride: 0.5)),
            .bye(ByeMessage(reason: 4)),
            .pairRequest(PairRequestMessage(peerID: peer, name: "iPad", modelIdentifier: "iPad8,1", protocolVersion: 1)),
            .pairResponse(PairResponseMessage(peerID: peer, name: "Mac", ltk: Data(0..<32))),
            .welcome(WelcomeMessage(status: 1, macPeerID: peer, macName: "Mac", macOSVersion: "27.0.1",
                                    injectorMode: 1, settings: settings, activePhoneName: "Téléphone 📱"))
        ]
    }

    func testEveryControlMessageRoundTrips() throws {
        for message in messages {
            let packet = try ControlMessage.decode(message.encode(sequence: 1234, sentAt: 5678))
            XCTAssertEqual(packet.message, message)
            XCTAssertEqual(packet.header, MessageHeader(type: message.type, sequence: 1234, sentAt: 5678))
        }
    }

    func testEveryTruncationIsTyped() throws {
        for message in messages {
            let data = try message.encode(sequence: 0, sentAt: 0)
            for count in 0..<data.count {
                XCTAssertThrowsError(try ControlMessage.decode(Data(data.prefix(count)))) {
                    XCTAssertEqual($0 as? ProtocolError, .truncated)
                }
            }
            XCTAssertThrowsError(try ControlMessage.decode(data + Data([0]))) {
                XCTAssertEqual($0 as? ControlCodecError, .trailingBytes)
            }
        }
    }

    func testWelcomeActivePhoneNameWireLayout() throws {
        let empty = try messages[1].encode(sequence: 0, sentAt: 0)
        XCTAssertEqual(Array(empty.suffix(2)), [0, 0])
        let busy = try XCTUnwrap(messages.last).encode(sequence: 0, sentAt: 0)
        let name = Array("Téléphone 📱".utf8)
        XCTAssertEqual(Array(busy.suffix(name.count + 2)), [UInt8(name.count), 0] + name)
        XCTAssertThrowsError(try ControlMessage.decode(Data(empty.dropLast(2)))) {
            XCTAssertEqual($0 as? ProtocolError, .truncated)
        }
    }

    func testUnknownType() throws {
        let data = try ControlMessage.unknown(type: 0xF0).encode(sequence: 0, sentAt: 0) + Data([1, 2, 3])
        XCTAssertEqual(try ControlMessage.decode(data).message, .unknown(type: 0xF0))
    }

    func testWireLayout() throws {
        let ping = try ControlMessage.ping(PingMessage(nonce: 0x12345678)).encode(sequence: 0, sentAt: 0)
        XCTAssertEqual(Array(ping.suffix(4)), [0x78, 0x56, 0x34, 0x12])
        let pair = try ControlMessage.pairRequest(PairRequestMessage(peerID: peer, name: "é", modelIdentifier: "", protocolVersion: 1)).encode(sequence: 0, sentAt: 0)
        XCTAssertEqual(Array(pair[16..<32]), [0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        XCTAssertEqual(Array(pair[32..<36]), [2, 0, 0xC3, 0xA9])
        let status = try messages[6].encode(sequence: 0, sentAt: 0)
        XCTAssertEqual(status.count, 33)
    }

    func testInvalidStringsAndKey() throws {
        var badUTF8 = try ControlMessage.pairRequest(PairRequestMessage(peerID: peer, name: "a", modelIdentifier: "", protocolVersion: 1)).encode(sequence: 0, sentAt: 0)
        badUTF8[34] = 0xFF
        XCTAssertThrowsError(try ControlMessage.decode(badUTF8)) {
            XCTAssertEqual($0 as? ControlCodecError, .invalidUTF8)
        }
        let long = ControlMessage.pairRequest(PairRequestMessage(peerID: peer, name: String(repeating: "x", count: 65536), modelIdentifier: "", protocolVersion: 1))
        XCTAssertThrowsError(try long.encode(sequence: 0, sentAt: 0)) {
            XCTAssertEqual($0 as? ControlCodecError, .stringTooLong)
        }
        XCTAssertThrowsError(try ControlMessage.pairResponse(PairResponseMessage(peerID: peer, name: "", ltk: Data(count: 31))).encode(sequence: 0, sentAt: 0)) {
            XCTAssertEqual($0 as? ControlCodecError, .invalidKeyLength)
        }
    }
}
