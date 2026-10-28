import CryptoKit
import Foundation
import XCTest
@testable import TrackglassKit

final class PairingTests: XCTestCase {
    func testURLRoundTrip() throws {
        let payload = try PairingPayload(pairID: Data(0..<8), pairSecret: Data(0..<32),
                                         macName: "Simone’s Mac & café + #? 📱", bonjourInstanceName: "Mac / 你好 (pairing)")
        XCTAssertEqual(try PairingPayload(url: payload.url), payload)
        XCTAssertEqual(payload.identity, "AAECAwQFBgc")
        // §3.4: the PIN path derives the same identity from the pairID alone (base64url, no padding,
        // `-`/`_` alphabet), so a pairID whose standard base64 would contain `+`, `/` and `=` must match.
        XCTAssertEqual(PairingPayload.identity(forPairID: payload.pairID), payload.identity)
        let awkward = try PairingPayload(pairID: Data([0xFB, 0xFF, 0xBF, 0xFE, 0xFF, 0xFF, 0xFF, 0xFF]),
                                         pairSecret: Data(0..<32), macName: "Mac", bonjourInstanceName: "Mac (pairing)")
        XCTAssertEqual(PairingPayload.identity(forPairID: awkward.pairID), awkward.identity)
        XCTAssertEqual(awkward.identity, "-_-__v____8")   // standard base64 would be "+/+//v////8="
        XCTAssertFalse(payload.url.absoluteString.contains(" "))
        XCTAssertThrowsError(try PairingPayload(url: URL(string: payload.url.absoluteString + "&v=1")!))
        XCTAssertThrowsError(try PairingPayload(url: URL(string: payload.url.absoluteString.replacingOccurrences(of: "v=1", with: "v=2"))!))
        XCTAssertThrowsError(try PairingPayload(pairID: Data(count: 7), pairSecret: Data(count: 32), macName: "", bonjourInstanceName: ""))
        XCTAssertThrowsError(try PairingPayload(pairID: Data(count: 8), pairSecret: Data(count: 31), macName: "", bonjourInstanceName: ""))
    }

    func testMalformedPairingURLsAreRejected() throws {
        let good = try PairingPayload(pairID: Data(0..<8), pairSecret: Data(0..<32), macName: "Mac", bonjourInstanceName: "Mac (pairing)").url.absoluteString
        let cases: [(String, String)] = [
            ("missing name", good.replacingOccurrences(of: "n=Mac", with: "n2=Mac")),
            ("missing host", good.replacingOccurrences(of: "h=", with: "x=")),
            ("wrong host", good.replacingOccurrences(of: "://pair", with: "://pairing")),
            ("non-canonical base64url id (trailing bits set)", good.replacingOccurrences(of: "id=AAECAwQFBgc", with: "id=AAECAwQFBgd")),
            ("standard base64 alphabet", good.replacingOccurrences(of: "id=AAECAwQFBgc", with: "id=AAECAwQFBg+")),
            ("id too short", good.replacingOccurrences(of: "id=AAECAwQFBgc", with: "id=AAECAwQF")),
            ("fragment", good + "#x"),
        ]
        for (label, text) in cases {
            guard let url = URL(string: text) else { continue }   // an unparsable string is rejected before us
            XCTAssertThrowsError(try PairingPayload(url: url), label)
        }
        XCTAssertNoThrow(try PairingPayload(url: URL(string: good)!))
    }

    func testPINKeyRejectsBadInputs() {
        XCTAssertThrowsError(try KeyDerivation.pinKey(pin: "001234", pairID: Data(count: 7)))
        XCTAssertThrowsError(try KeyDerivation.pinKey(pin: "001234", pairID: Data(count: 9)))
        XCTAssertThrowsError(try KeyDerivation.pinKey(pin: "12345", pairID: Data(count: 8)))
        XCTAssertThrowsError(try KeyDerivation.pinKey(pin: "1234567", pairID: Data(count: 8)))
        XCTAssertThrowsError(try KeyDerivation.pinKey(pin: "12345a", pairID: Data(count: 8)))
        XCTAssertThrowsError(try KeyDerivation.pinKey(pin: "１２３４５６", pairID: Data(count: 8)), "full-width digits are not ASCII digits")
        XCTAssertNoThrow(try KeyDerivation.pinKey(pin: "000000", pairID: Data(count: 8)))
    }

    func testMonotonicClockAgreesWithDispatchUptime() {
        // InputPipeline mixes both clocks (frame stamps vs receive stamps); they must share a base.
        let dispatch = DispatchTime.now().uptimeNanoseconds
        let clock = MonotonicClock.nanoseconds()
        XCTAssertLessThan(abs(Int64(clock) - Int64(dispatch)), 50_000_000, "clocks differ by more than 50 ms")
    }

    func testPairingLTKKnownAnswer() throws {
        // Independent vector (Python `cryptography` X25519 + HKDF-SHA256, cross-checked with hashlib/hmac):
        // phone private key bytes 01…20, Mac private key bytes 21…40, pairing PSK = A5×32, pairID = 00…07,
        // phone peerID 00112233-…-eeff, Mac peerID ffeeddcc-…-1100.
        let phone = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(1...32))
        let mac = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(33...64))
        XCTAssertEqual(hex(phone.publicKey.rawRepresentation), "07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c")
        XCTAssertEqual(hex(mac.publicKey.rawRepresentation), "5869aff450549732cbaaed5e5df9b30a6da31cb0e5742bad5ad4a1a768f1a67b")
        let phoneSide = try KeyDerivation.sharedSecret(privateKey: phone, peerPublicKey: mac.publicKey.rawRepresentation)
        let macSide = try KeyDerivation.sharedSecret(privateKey: mac, peerPublicKey: phone.publicKey.rawRepresentation)
        XCTAssertEqual(phoneSide.withUnsafeBytes { hex(Data($0)) }, "a84dc7c3c8f058b1b2dc4cd1e9b5dc0a7987f88b6a9564cde3391fc421159e77")
        let phoneID = try XCTUnwrap(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let macID = try XCTUnwrap(UUID(uuidString: "FFEEDDCC-BBAA-9988-7766-554433221100"))
        func derive(_ secret: SharedSecret) throws -> String {
            let key = try KeyDerivation.pairingLTK(sharedSecret: secret, pairingKey: SymmetricKey(data: Data(repeating: 0xA5, count: 32)),
                                                   pairID: Data(0..<8), phonePeerID: phoneID, macPeerID: macID,
                                                   phonePublicKey: phone.publicKey.rawRepresentation,
                                                   macPublicKey: mac.publicKey.rawRepresentation)
            return key.withUnsafeBytes { hex(Data($0)) }
        }
        XCTAssertEqual(try derive(phoneSide), "ceb16f56124d5c2c8a75fe788031125ec63bf8f67db1c49fe434746ac665298f")
        XCTAssertEqual(try derive(macSide), try derive(phoneSide), "both sides derive the same LTK")
        // Any transcript change gives a different key.
        let swapped = try KeyDerivation.pairingLTK(sharedSecret: phoneSide, pairingKey: SymmetricKey(data: Data(repeating: 0xA5, count: 32)),
                                                   pairID: Data(0..<8), phonePeerID: macID, macPeerID: phoneID,
                                                   phonePublicKey: phone.publicKey.rawRepresentation,
                                                   macPublicKey: mac.publicKey.rawRepresentation)
        XCTAssertNotEqual(swapped.withUnsafeBytes { hex(Data($0)) }, try derive(phoneSide))
        XCTAssertThrowsError(try KeyDerivation.sharedSecret(privateKey: phone, peerPublicKey: Data(count: 31)))
        XCTAssertThrowsError(try KeyDerivation.pairingLTK(sharedSecretBytes: Data(count: 32), pairingKey: SymmetricKey(size: .bits256),
                                                          pairID: Data(count: 7), phonePeerID: phoneID, macPeerID: macID,
                                                          phonePublicKey: Data(count: 32), macPublicKey: Data(count: 32)))
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    func testHKDFKnownAnswer() throws {
        // Computed independently with Python hashlib/hmac: extract(salt=00..07, IKM="001234"),
        // then expand with info="trackglass-pair-v1" and counter=01, one SHA-256 block.
        let key = try KeyDerivation.pinKey(pin: "001234", pairID: Data(0..<8))
        let hex = key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex, "f8a816f2569f6826c8df004ac61b9dc0081b9b59eba5f2544ca3faae5560289b")
        for pin in ["12345", "1234567", "abcdef", "１２３４５６"] {
            XCTAssertThrowsError(try KeyDerivation.pinKey(pin: pin, pairID: Data(0..<8)))
        }
    }

    func testPeerIdentity() throws {
        let peer = PeerIdentity(name: "Mac")
        XCTAssertEqual(peer.tlsIdentity, peer.peerID.uuidString.lowercased())
        XCTAssertEqual(try JSONDecoder().decode(PeerIdentity.self, from: JSONEncoder().encode(peer)), peer)
    }
}
