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
        // §3.4: code pairing derives the same identity from the pairID alone (base64url, no padding,
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

    func testCodeChannelKeyKnownAnswer() throws {
        // §3.4 (2026-10-31), computed with Python hashlib/hmac and cross-checked with `cryptography`'s HKDF:
        // HKDF-SHA256(ikm: "trackglass-code-channel-v1", salt: 00…07, info: "trackglass-pair-v2", 32 bytes).
        let key = try KeyDerivation.codeChannelKey(pairID: Data(0..<8))
        XCTAssertEqual(key.withUnsafeBytes { hex(Data($0)) }, "6ae0d35b0715376294df5fcd17cdf11f038bd5f1144d67fe77abedfcf5a30c89")
        XCTAssertNotEqual(try KeyDerivation.codeChannelKey(pairID: Data(1...8)).withUnsafeBytes { hex(Data($0)) },
                          key.withUnsafeBytes { hex(Data($0)) }, "each pairing window has its own channel key")
        XCTAssertThrowsError(try KeyDerivation.codeChannelKey(pairID: Data(count: 7)))
        XCTAssertThrowsError(try KeyDerivation.codeChannelKey(pairID: Data(count: 9)))
    }

    func testCommitmentKnownAnswerAndCheck() throws {
        // SHA-256("trackglass-commit-v1" ‖ Nm ‖ macPK ‖ phonePK) with Nm = 80…9f and the key pairs of the LTK vectors.
        let (phonePK, macPK) = try vectorPublicKeys()
        let macNonce = Data(0x80..<0xA0)
        let commitment = try KeyDerivation.commitment(macNonce: macNonce, macPublicKey: macPK, phonePublicKey: phonePK)
        XCTAssertEqual(hex(commitment), "20f999f27c3a7f8962cdc119374928043b8750a11fe4fa0a538a9ab11b482b00")
        XCTAssertTrue(KeyDerivation.commitmentMatches(commitment, macNonce: macNonce, macPublicKey: macPK, phonePublicKey: phonePK))
        // A different nonce, a swapped or substituted key, or a damaged commitment does not open it.
        XCTAssertFalse(KeyDerivation.commitmentMatches(commitment, macNonce: Data(0xC0..<0xE0), macPublicKey: macPK, phonePublicKey: phonePK))
        XCTAssertFalse(KeyDerivation.commitmentMatches(commitment, macNonce: macNonce, macPublicKey: phonePK, phonePublicKey: macPK))
        XCTAssertFalse(KeyDerivation.commitmentMatches(commitment, macNonce: macNonce, macPublicKey: Data(repeating: 9, count: 32), phonePublicKey: phonePK))
        var damaged = commitment
        damaged[31] ^= 1
        XCTAssertFalse(KeyDerivation.commitmentMatches(damaged, macNonce: macNonce, macPublicKey: macPK, phonePublicKey: phonePK))
        XCTAssertFalse(KeyDerivation.commitmentMatches(commitment.prefix(31), macNonce: macNonce, macPublicKey: macPK, phonePublicKey: phonePK))
        XCTAssertFalse(KeyDerivation.commitmentMatches(commitment, macNonce: macNonce.prefix(31), macPublicKey: macPK, phonePublicKey: phonePK))
        XCTAssertThrowsError(try KeyDerivation.commitment(macNonce: Data(count: 31), macPublicKey: macPK, phonePublicKey: phonePK))
        XCTAssertEqual(KeyDerivation.randomNonce().count, 32)
        XCTAssertNotEqual(KeyDerivation.randomNonce(), KeyDerivation.randomNonce())
    }

    func testComparisonCodeKnownAnswer() throws {
        // SHA-256("trackglass-sas-v1" ‖ pairID 00…07 ‖ phone/Mac peerIDs of the LTK vectors ‖ phonePK ‖ macPK ‖ Np ‖ Nm),
        // Np = c0…df, Nm = 80…9f: first four bytes b4 26 1d 5a = 3 022 396 762 → mod 10⁶ = 396762.
        let (phonePK, macPK) = try vectorPublicKeys()
        let (phoneID, macID) = try vectorPeerIDs()
        func code(_ phoneNonce: Data, _ macNonce: Data, swapIDs: Bool = false) throws -> String {
            try KeyDerivation.comparisonCode(pairID: Data(0..<8), phonePeerID: swapIDs ? macID : phoneID, macPeerID: swapIDs ? phoneID : macID,
                                             phonePublicKey: phonePK, macPublicKey: macPK, phoneNonce: phoneNonce, macNonce: macNonce)
        }
        let phoneNonce = Data(0xC0..<0xE0), macNonce = Data(0x80..<0xA0)
        XCTAssertEqual(try code(phoneNonce, macNonce), "396762")
        // Np[0] = b4: first four bytes f7 e5 6a 3d = 4 159 007 293 → 007293.
        var leadingZero = phoneNonce
        leadingZero[0] = 0xB4
        XCTAssertEqual(try code(leadingZero, macNonce), "007293", "leading zeros are kept")
        XCTAssertEqual(try code(macNonce, phoneNonce), "205269", "the nonces are not interchangeable")
        XCTAssertNotEqual(try code(phoneNonce, macNonce, swapIDs: true), "396762")
        XCTAssertThrowsError(try code(Data(count: 31), macNonce))
        XCTAssertThrowsError(try KeyDerivation.comparisonCode(pairID: Data(count: 7), phonePeerID: phoneID, macPeerID: macID, phonePublicKey: phonePK,
                                                              macPublicKey: macPK, phoneNonce: Data(count: 32), macNonce: Data(count: 32)))
        XCTAssertEqual(PairingText.formattedCode("007293"), "007 293")
        XCTAssertEqual(PairingText.spokenCode("007293"), "0 0 7 2 9 3")
    }

    func testCodePairingLTKKnownAnswer() throws {
        // HKDF-SHA256(ikm: X25519 ‖ Np ‖ Nm, salt: 00…07, info: "trackglass-ltk-v3" ‖ phoneID ‖ macID ‖ phonePK ‖ macPK),
        // computed with Python `cryptography` (X25519 + HKDF) and cross-checked with hashlib/hmac.
        let phone = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(1...32))
        let mac = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(33...64))
        let (phoneID, macID) = try vectorPeerIDs()
        func derive(_ secret: SharedSecret, phoneNonce: Data = Data(0xC0..<0xE0), macNonce: Data = Data(0x80..<0xA0)) throws -> String {
            try KeyDerivation.codePairingLTK(sharedSecret: secret, pairID: Data(0..<8), phonePeerID: phoneID, macPeerID: macID,
                                             phonePublicKey: phone.publicKey.rawRepresentation, macPublicKey: mac.publicKey.rawRepresentation,
                                             phoneNonce: phoneNonce, macNonce: macNonce).withUnsafeBytes { hex(Data($0)) }
        }
        let phoneSide = try KeyDerivation.sharedSecret(privateKey: phone, peerPublicKey: mac.publicKey.rawRepresentation)
        let macSide = try KeyDerivation.sharedSecret(privateKey: mac, peerPublicKey: phone.publicKey.rawRepresentation)
        XCTAssertEqual(try derive(phoneSide), "661814eba967509c456a638deb69ba38bc5335bd1ab28fe0aab75213a5617d9b")
        XCTAssertEqual(try derive(macSide), try derive(phoneSide), "both sides derive the same LTK")
        XCTAssertNotEqual(try derive(phoneSide, phoneNonce: Data(0x80..<0xA0), macNonce: Data(0xC0..<0xE0)), try derive(phoneSide))
        // The QR derivation (v2) of the same exchange is a different key.
        let qr = try KeyDerivation.pairingLTK(sharedSecret: phoneSide, pairingKey: SymmetricKey(data: Data(repeating: 0xA5, count: 32)),
                                              pairID: Data(0..<8), phonePeerID: phoneID, macPeerID: macID,
                                              phonePublicKey: phone.publicKey.rawRepresentation, macPublicKey: mac.publicKey.rawRepresentation)
        XCTAssertNotEqual(qr.withUnsafeBytes { hex(Data($0)) }, try derive(phoneSide))
        XCTAssertThrowsError(try KeyDerivation.codePairingLTK(sharedSecretBytes: Data(count: 32), pairID: Data(0..<8), phonePeerID: phoneID,
                                                              macPeerID: macID, phonePublicKey: Data(count: 32), macPublicKey: Data(count: 32),
                                                              phoneNonce: Data(count: 32), macNonce: Data(count: 16)))
    }

    func testPromptNamesAreSanitized() {
        // §3.4 (2026-10-31): control and format characters (Cc, Cf — bidi overrides included) go, whitespace collapses.
        XCTAssertEqual(PairingText.sanitizedName("Sam’s iPhone"), "Sam’s iPhone")
        XCTAssertEqual(PairingText.sanitizedName("  Sam’s\t\n  iPhone \u{00A0} "), "Sam’s iPhone")
        XCTAssertEqual(PairingText.sanitizedName("Sam\u{202E}enohPi\u{202C}"), "SamenohPi", "RIGHT-TO-LEFT OVERRIDE / POP removed")
        XCTAssertEqual(PairingText.sanitizedName("a\u{2066}b\u{2069}\u{200B}c\u{200F}\u{FEFF}"), "abc", "isolates, ZWSP, RLM, BOM removed")
        XCTAssertEqual(PairingText.sanitizedName("x\u{0000}\u{0007}\u{007F}\u{0085}y"), "x y", "C0/C1 controls removed, NEL is whitespace")
        XCTAssertEqual(PairingText.sanitizedName("\u{202E}\u{0001} \n"), "")
        XCTAssertEqual(PairingText.sanitizedName("Téléphone 📱 de Zoë"), "Téléphone 📱 de Zoë")
        let long = PairingText.sanitizedName(String(repeating: "W", count: 100))
        XCTAssertEqual(long.count, 40)
        XCTAssertEqual(long, String(repeating: "W", count: 39) + "…")
        XCTAssertEqual(PairingText.sanitizedName(String(repeating: "e\u{0301}", count: 41)).count, 40, "counts characters, not scalars")
        XCTAssertEqual(PairingText.sanitizedName(String(repeating: "a", count: 40)), String(repeating: "a", count: 40), "40 fits")
        XCTAssertEqual(PairingText.sanitizedName(String(repeating: "a", count: 38) + "  bcd"), String(repeating: "a", count: 38) + "…",
                       "no space before the ellipsis")
    }

    private func vectorPublicKeys() throws -> (phone: Data, mac: Data) {
        let phone = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(1...32))
        let mac = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(33...64))
        return (phone.publicKey.rawRepresentation, mac.publicKey.rawRepresentation)
    }

    private func vectorPeerIDs() throws -> (phone: UUID, mac: UUID) {
        let phone = try XCTUnwrap(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let mac = try XCTUnwrap(UUID(uuidString: "FFEEDDCC-BBAA-9988-7766-554433221100"))
        return (phone, mac)
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

    func testPeerIdentity() throws {
        let peer = PeerIdentity(name: "Mac")
        XCTAssertEqual(peer.tlsIdentity, peer.peerID.uuidString.lowercased())
        XCTAssertEqual(try JSONDecoder().decode(PeerIdentity.self, from: JSONEncoder().encode(peer)), peer)
    }
}
