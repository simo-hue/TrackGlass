import CryptoKit
import Foundation

public enum KeyDerivationError: Error, Equatable, Sendable {
    case invalidPIN
    case invalidPairID
    case invalidPublicKey
}

public enum KeyDerivation {
    public static func pinKey(pin: String, pairID: Data) throws -> SymmetricKey {
        guard pin.utf8.count == 6, pin.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw KeyDerivationError.invalidPIN
        }
        guard pairID.count == 8 else { throw KeyDerivationError.invalidPairID }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(pin.utf8)),
                                     salt: pairID, info: Data("trackglass-pair-v1".utf8), outputByteCount: 32)
    }

    /// §3.4 long-term key (owner-approved pairing hardening, 2026-10-28). Both sides compute it; it never crosses the wire.
    ///
    ///     LTK = HKDF-SHA256(ikm:  X25519(phone, Mac) ‖ pairing PSK,
    ///                       salt: pairID,
    ///                       info: "trackglass-ltk-v2" ‖ phonePeerID ‖ macPeerID ‖ phonePublicKey ‖ macPublicKey, 32 bytes)
    ///
    /// The ephemeral X25519 secret defeats a passive recording of the pairing exchange (the PIN path's PSK has only
    /// 10⁶ values and can be brute-forced offline from a capture); the pairing PSK (pairSecret or PIN key) in the IKM
    /// and the transcript in `info` bind the key to the authenticated pairing channel and to both identities.
    public static func pairingLTK(sharedSecret: SharedSecret, pairingKey: SymmetricKey, pairID: Data,
                                  phonePeerID: UUID, macPeerID: UUID,
                                  phonePublicKey: Data, macPublicKey: Data) throws -> SymmetricKey {
        try pairingLTK(sharedSecretBytes: sharedSecret.withUnsafeBytes { Data($0) }, pairingKey: pairingKey, pairID: pairID,
                       phonePeerID: phonePeerID, macPeerID: macPeerID, phonePublicKey: phonePublicKey, macPublicKey: macPublicKey)
    }

    /// The same derivation from raw shared-secret bytes (known-answer tests).
    public static func pairingLTK(sharedSecretBytes: Data, pairingKey: SymmetricKey, pairID: Data,
                                  phonePeerID: UUID, macPeerID: UUID,
                                  phonePublicKey: Data, macPublicKey: Data) throws -> SymmetricKey {
        guard pairID.count == 8 else { throw KeyDerivationError.invalidPairID }
        guard sharedSecretBytes.count == 32, phonePublicKey.count == 32, macPublicKey.count == 32 else {
            throw KeyDerivationError.invalidPublicKey
        }
        var ikm = sharedSecretBytes
        pairingKey.withUnsafeBytes { ikm.append(contentsOf: $0) }
        var info = Data("trackglass-ltk-v2".utf8)
        info.append(uuidBytes(phonePeerID))
        info.append(uuidBytes(macPeerID))
        info.append(phonePublicKey)
        info.append(macPublicKey)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: pairID, info: info, outputByteCount: 32)
    }

    /// One side of the exchange: parses the peer's raw X25519 public key and runs the agreement.
    public static func sharedSecret(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Data) throws -> SharedSecret {
        guard peerPublicKey.count == 32 else { throw KeyDerivationError.invalidPublicKey }
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        return try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
    }

    private static func uuidBytes(_ value: UUID) -> Data {
        withUnsafeBytes(of: value.uuid) { Data($0) }
    }
}
