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
            .pairRequest(PairRequestMessage(peerID: peer, name: "iPad", modelIdentifier: "iPad8,1", protocolVersion: 1,
                                            ephemeralPublicKey: Data(32..<64))),
            .pairResponse(PairResponseMessage(peerID: peer, name: "Mac", ephemeralPublicKey: Data(0..<32))),
            .pairCommit(PairCommitMessage(peerID: peer, name: "Simone’s Mac", ephemeralPublicKey: Data(64..<96),
                                          commitment: Data(96..<128))),
            .pairNonce(PairNonceMessage(nonce: Data(128..<160))),
            .pairReveal(PairNonceMessage(nonce: Data(160..<192))),
            .pairConfirm,
            // Keep last: testWelcomeActivePhoneNameWireLayout uses it.
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

    func testNonFiniteOrNonPositiveGeometryIsRejected() throws {
        let bad: [ControlMessage] = [
            .hello(HelloMessage(protocolVersion: 1, peerID: peer, name: "P", modelIdentifier: "m", surfaceWidthMM: .nan,
                                surfaceHeightMM: 141, ppi: 460, maxContacts: 10, displayHz: 120, caps: 0, trackingOverride: 0)),
            .hello(HelloMessage(protocolVersion: 1, peerID: peer, name: "P", modelIdentifier: "m", surfaceWidthMM: 65,
                                surfaceHeightMM: 0, ppi: 460, maxContacts: 10, displayHz: 120, caps: 0, trackingOverride: 0)),
            .surface(SurfaceMessage(surfaceWidthMM: 141, surfaceHeightMM: 65, ppi: .infinity, trackingOverride: 0)),
            .surface(SurfaceMessage(surfaceWidthMM: 141, surfaceHeightMM: 65, ppi: 460, trackingOverride: .nan)),
            .surface(SurfaceMessage(surfaceWidthMM: .nan, surfaceHeightMM: 65, ppi: 460, trackingOverride: 0)),
            .surface(SurfaceMessage(surfaceWidthMM: 141, surfaceHeightMM: -.infinity, ppi: 460, trackingOverride: 0)),
            .surface(SurfaceMessage(surfaceWidthMM: 141, surfaceHeightMM: 65, ppi: 0, trackingOverride: 0))
        ]
        for message in bad {
            XCTAssertThrowsError(try ControlMessage.decode(message.encode(sequence: 0, sentAt: 0))) { error in
                XCTAssertEqual(error as? ControlCodecError, .invalidValue)
            }
        }
        let good = ControlMessage.surface(SurfaceMessage(surfaceWidthMM: 141, surfaceHeightMM: 65, ppi: 460, trackingOverride: -1))
        XCTAssertEqual(try ControlMessage.decode(good.encode(sequence: 0, sentAt: 0)).message, good)
        // L9 (contract C3, 2026-10-31): a zero or negative SURFACE size decodes; the Mac ignores it instead of
        // answering BYE{incompatible}, which would end the phone's session for good.
        let degenerateSizes: [(Float, Float)] = [(0, 65), (141, 0), (-1, 65), (141, -0.5)]
        for (width, height) in degenerateSizes {
            let degenerate = ControlMessage.surface(SurfaceMessage(surfaceWidthMM: width, surfaceHeightMM: height, ppi: 460, trackingOverride: 0))
            XCTAssertEqual(try ControlMessage.decode(degenerate.encode(sequence: 0, sentAt: 0)).message, degenerate)
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
            // §4.1: fields a newer peer appends are ignored.
            XCTAssertEqual(try ControlMessage.decode(data + Data([0, 1, 2])).message, message)
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
        // The first type after the code-pairing messages (0x22…0x25) is still unknown.
        let next = try ControlMessage.unknown(type: 0x26).encode(sequence: 0, sentAt: 0)
        XCTAssertEqual(try ControlMessage.decode(next).message, .unknown(type: 0x26))
        XCTAssertEqual(Set(MessageType.allCases.map(\.rawValue)).count, MessageType.allCases.count, "no two types share a value")
    }

    func testCodePairingWireLayout() throws {
        // §4.5 (2026-10-31): PAIR_COMMIT = macPeerID 16, macName str, macEphemeralPublicKey 32, commitment 32.
        let commit = try ControlMessage.pairCommit(PairCommitMessage(peerID: peer, name: "é", ephemeralPublicKey: Data(repeating: 0xAA, count: 32),
                                                                     commitment: Data(repeating: 0xCC, count: 32))).encode(sequence: 7, sentAt: 9)
        XCTAssertEqual(commit[3], 0x22)
        XCTAssertEqual(Array(commit[16..<32]), [0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        XCTAssertEqual(Array(commit[32..<36]), [2, 0, 0xC3, 0xA9])
        XCTAssertEqual(Array(commit[36..<68]), [UInt8](repeating: 0xAA, count: 32))
        XCTAssertEqual(Array(commit[68..<100]), [UInt8](repeating: 0xCC, count: 32))
        XCTAssertEqual(commit.count, 100)
        // PAIR_NONCE / PAIR_REVEAL = nonce 32; PAIR_CONFIRM = header only.
        let nonce = try ControlMessage.pairNonce(PairNonceMessage(nonce: Data(repeating: 0x11, count: 32))).encode(sequence: 0, sentAt: 0)
        XCTAssertEqual(nonce[3], 0x23)
        XCTAssertEqual(nonce.count, 48)
        let reveal = try ControlMessage.pairReveal(PairNonceMessage(nonce: Data(repeating: 0x22, count: 32))).encode(sequence: 0, sentAt: 0)
        XCTAssertEqual(reveal[3], 0x24)
        XCTAssertEqual(Array(reveal.suffix(32)), [UInt8](repeating: 0x22, count: 32))
        let confirm = try ControlMessage.pairConfirm.encode(sequence: 0, sentAt: 0)
        XCTAssertEqual(confirm[3], 0x25)
        XCTAssertEqual(confirm.count, 16)
        // Wrong lengths cannot be sent.
        for bad in [ControlMessage.pairNonce(PairNonceMessage(nonce: Data(count: 31))), .pairReveal(PairNonceMessage(nonce: Data(count: 33))),
                    .pairCommit(PairCommitMessage(peerID: peer, name: "", ephemeralPublicKey: Data(count: 32), commitment: Data(count: 31))),
                    .pairCommit(PairCommitMessage(peerID: peer, name: "", ephemeralPublicKey: Data(count: 31), commitment: Data(count: 32)))] {
            XCTAssertThrowsError(try bad.encode(sequence: 0, sentAt: 0)) {
                XCTAssertEqual($0 as? ControlCodecError, .invalidKeyLength)
            }
        }
    }

    func testScrollPreferenceWireLayoutInSettingsAndWelcome() throws {
        for mask in UInt8(0)..<128 {
            let bits = (0..<7).map { (mask >> $0) & 1 }
            var value = settings
            value.scrollEnabled = bits[0]
            value.horizontalScrollEnabled = bits[1]
            value.momentumScrollEnabled = bits[2]
            value.pinchEnabled = bits[3]
            value.rotateEnabled = bits[4]
            value.smartZoomEnabled = bits[5]
            value.swipeNavigationEnabled = bits[6]
            let standalone = ControlMessage.settings(value)
            let bytes = try standalone.encode(sequence: 0, sentAt: 0)
            XCTAssertEqual(bytes.count, 32)
            XCTAssertEqual(Array(bytes[25..<32]), bits)
            XCTAssertEqual(try ControlMessage.decode(bytes).message, standalone)
            let welcome = ControlMessage.welcome(WelcomeMessage(status: 1, macPeerID: peer,
                macName: "Mac", macOSVersion: "27", injectorMode: 1, settings: value, activePhoneName: "Phone"))
            XCTAssertEqual(try ControlMessage.decode(welcome.encode(sequence: 0, sentAt: 0)).message, welcome)
            // An older nine-byte SETTINGS payload must be rejected, not defaulted.
            XCTAssertThrowsError(try ControlMessage.decode(Data(bytes.prefix(25)))) {
                XCTAssertEqual($0 as? ProtocolError, .truncated)
            }
        }
    }

    func testWireLayout() throws {
        let ping = try ControlMessage.ping(PingMessage(nonce: 0x12345678)).encode(sequence: 0, sentAt: 0)
        XCTAssertEqual(Array(ping.suffix(4)), [0x78, 0x56, 0x34, 0x12])
        let pair = try ControlMessage.pairRequest(PairRequestMessage(peerID: peer, name: "é", modelIdentifier: "", protocolVersion: 1,
                                                                     ephemeralPublicKey: Data(repeating: 0xEE, count: 32))).encode(sequence: 0, sentAt: 0)
        XCTAssertEqual(Array(pair[16..<32]), [0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        XCTAssertEqual(Array(pair[32..<36]), [2, 0, 0xC3, 0xA9])
        // peerID 16 + name 2+2 + model 2+0 + protocolVersion 1, then the 32-byte X25519 key (§4.5, 2026-10-28).
        XCTAssertEqual(pair.count, 16 + 16 + 4 + 2 + 1 + 32)
        XCTAssertEqual(pair[38], 1)
        XCTAssertEqual(Array(pair.suffix(32)), [UInt8](repeating: 0xEE, count: 32))
        let status = try messages[6].encode(sequence: 0, sentAt: 0)
        XCTAssertEqual(status.count, 33)
    }

    func testInvalidStringsAndKey() throws {
        var badUTF8 = try ControlMessage.pairRequest(PairRequestMessage(peerID: peer, name: "a", modelIdentifier: "", protocolVersion: 1,
                                                                        ephemeralPublicKey: Data(count: 32))).encode(sequence: 0, sentAt: 0)
        badUTF8[34] = 0xFF
        XCTAssertThrowsError(try ControlMessage.decode(badUTF8)) {
            XCTAssertEqual($0 as? ControlCodecError, .invalidUTF8)
        }
        let long = ControlMessage.pairRequest(PairRequestMessage(peerID: peer, name: String(repeating: "x", count: 65536), modelIdentifier: "", protocolVersion: 1))
        XCTAssertThrowsError(try long.encode(sequence: 0, sentAt: 0)) {
            XCTAssertEqual($0 as? ControlCodecError, .stringTooLong)
        }
        XCTAssertThrowsError(try ControlMessage.pairResponse(PairResponseMessage(peerID: peer, name: "", ephemeralPublicKey: Data(count: 31))).encode(sequence: 0, sentAt: 0)) {
            XCTAssertEqual($0 as? ControlCodecError, .invalidKeyLength)
        }
        // A request without its ephemeral key cannot be sent (PairingClient always fills it).
        XCTAssertThrowsError(try ControlMessage.pairRequest(PairRequestMessage(peerID: peer, name: "a", modelIdentifier: "", protocolVersion: 1)).encode(sequence: 0, sentAt: 0)) {
            XCTAssertEqual($0 as? ControlCodecError, .invalidKeyLength)
        }
        // A truncated key on the wire is a truncated message.
        let full = try ControlMessage.pairResponse(PairResponseMessage(peerID: peer, name: "Mac", ephemeralPublicKey: Data(count: 32))).encode(sequence: 0, sentAt: 0)
        XCTAssertThrowsError(try ControlMessage.decode(full.dropLast()))
    }
}
