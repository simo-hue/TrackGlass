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
