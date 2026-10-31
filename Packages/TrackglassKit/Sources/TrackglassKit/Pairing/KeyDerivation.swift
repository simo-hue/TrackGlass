import CryptoKit
import Foundation

public enum KeyDerivationError: Error, Equatable, Sendable {
    case invalidPairID
    case invalidPublicKey
    case invalidNonce
}

public enum KeyDerivation {
    /// Length of the code-pairing nonces Np and Nm and of the PAIR_COMMIT commitment (§4.5).
    public static let nonceByteCount = 32

    /// §3.4 code-pairing channel key (2026-10-31):
    ///
    ///     HKDF-SHA256(ikm: "trackglass-code-channel-v1", salt: pairID, info: "trackglass-pair-v2", 32 bytes)
    ///
    /// Public on purpose (pairID is in the TXT record): anyone on the network can derive it, so TLS on this channel only
    /// frames the exchange and gives no confidentiality. The comparison code is what authenticates it, so there is no
    /// secret to brute-force offline; the long-term key itself comes from the X25519 exchange.
    public static func codeChannelKey(pairID: Data) throws -> SymmetricKey {
        guard pairID.count == 8 else { throw KeyDerivationError.invalidPairID }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data("trackglass-code-channel-v1".utf8)),
                                     salt: pairID, info: Data("trackglass-pair-v2".utf8), outputByteCount: 32)
    }

    /// A fresh 32-byte nonce from the system CSPRNG (Np on the phone, Nm on the Mac; one per code session).
    public static func randomNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// PAIR_COMMIT's commitment: `SHA-256("trackglass-commit-v1" ‖ Nm ‖ macPublicKey ‖ phonePublicKey)`.
    public static func commitment(macNonce: Data, macPublicKey: Data, phonePublicKey: Data) throws -> Data {
        guard macNonce.count == nonceByteCount else { throw KeyDerivationError.invalidNonce }
        guard macPublicKey.count == 32, phonePublicKey.count == 32 else { throw KeyDerivationError.invalidPublicKey }
        var hash = SHA256()
        hash.update(data: Data("trackglass-commit-v1".utf8))
        hash.update(data: macNonce)
        hash.update(data: macPublicKey)
        hash.update(data: phonePublicKey)
        return Data(hash.finalize())
    }

    /// The phone's check after PAIR_REVEAL: does Nm open PAIR_COMMIT's commitment? Compared in constant time.
    public static func commitmentMatches(_ commitment: Data, macNonce: Data, macPublicKey: Data, phonePublicKey: Data) -> Bool {
        guard commitment.count == 32,
              let expected = try? Self.commitment(macNonce: macNonce, macPublicKey: macPublicKey, phonePublicKey: phonePublicKey) else {
            return false
        }
        var difference: UInt8 = 0
        for (a, b) in zip(commitment, expected) { difference |= a ^ b }
        return difference == 0
    }

    /// §3.4 comparison code, shown on both screens: the first 4 bytes, big-endian, of
    ///
    ///     SHA-256("trackglass-sas-v1" ‖ pairID ‖ phonePeerID ‖ macPeerID ‖ phonePublicKey ‖ macPublicKey ‖ Np ‖ Nm)
    ///
    /// modulo 1 000 000, as six digits with leading zeros ("007293"). `PairingText.formattedCode` displays it.
    public static func comparisonCode(pairID: Data, phonePeerID: UUID, macPeerID: UUID, phonePublicKey: Data, macPublicKey: Data,
                                      phoneNonce: Data, macNonce: Data) throws -> String {
        guard pairID.count == 8 else { throw KeyDerivationError.invalidPairID }
        guard phonePublicKey.count == 32, macPublicKey.count == 32 else { throw KeyDerivationError.invalidPublicKey }
        guard phoneNonce.count == nonceByteCount, macNonce.count == nonceByteCount else { throw KeyDerivationError.invalidNonce }
        var hash = SHA256()
        hash.update(data: Data("trackglass-sas-v1".utf8))
        hash.update(data: pairID)
        hash.update(data: uuidBytes(phonePeerID))
        hash.update(data: uuidBytes(macPeerID))
        hash.update(data: phonePublicKey)
        hash.update(data: macPublicKey)
        hash.update(data: phoneNonce)
        hash.update(data: macNonce)
        let value = hash.finalize().prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let digits = String(value)
        return String(repeating: "0", count: 6 - digits.count) + digits
    }

    /// §3.4 long-term key of a code pairing (2026-10-31). Both sides compute it; it never crosses the wire.
    ///
    ///     LTK = HKDF-SHA256(ikm:  X25519(phone, Mac) ‖ Np ‖ Nm,
    ///                       salt: pairID,
    ///                       info: "trackglass-ltk-v3" ‖ phonePeerID ‖ macPeerID ‖ phonePublicKey ‖ macPublicKey, 32 bytes)
    ///
    /// The code channel's PSK is public, so unlike the QR derivation it is not mixed in; the matching comparison code
    /// is what proves both sides used these two public keys.
    public static func codePairingLTK(sharedSecret: SharedSecret, pairID: Data, phonePeerID: UUID, macPeerID: UUID,
                                      phonePublicKey: Data, macPublicKey: Data, phoneNonce: Data, macNonce: Data) throws -> SymmetricKey {
        try codePairingLTK(sharedSecretBytes: sharedSecret.withUnsafeBytes { Data($0) }, pairID: pairID,
                           phonePeerID: phonePeerID, macPeerID: macPeerID, phonePublicKey: phonePublicKey,
                           macPublicKey: macPublicKey, phoneNonce: phoneNonce, macNonce: macNonce)
    }

    /// The same derivation from raw shared-secret bytes (known-answer tests).
    public static func codePairingLTK(sharedSecretBytes: Data, pairID: Data, phonePeerID: UUID, macPeerID: UUID,
                                      phonePublicKey: Data, macPublicKey: Data, phoneNonce: Data, macNonce: Data) throws -> SymmetricKey {
        guard pairID.count == 8 else { throw KeyDerivationError.invalidPairID }
        guard sharedSecretBytes.count == 32, phonePublicKey.count == 32, macPublicKey.count == 32 else {
            throw KeyDerivationError.invalidPublicKey
        }
        guard phoneNonce.count == nonceByteCount, macNonce.count == nonceByteCount else { throw KeyDerivationError.invalidNonce }
        var ikm = sharedSecretBytes
        ikm.append(phoneNonce)
        ikm.append(macNonce)
        var info = Data("trackglass-ltk-v3".utf8)
        info.append(uuidBytes(phonePeerID))
        info.append(uuidBytes(macPeerID))
        info.append(phonePublicKey)
        info.append(macPublicKey)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: pairID, info: info, outputByteCount: 32)
    }

    /// §3.4 long-term key of a QR pairing (owner-approved pairing hardening, 2026-10-28). Both sides compute it; it
    /// never crosses the wire.
    ///
    ///     LTK = HKDF-SHA256(ikm:  X25519(phone, Mac) ‖ pairing PSK,
    ///                       salt: pairID,
    ///                       info: "trackglass-ltk-v2" ‖ phonePeerID ‖ macPeerID ‖ phonePublicKey ‖ macPublicKey, 32 bytes)
    ///
    /// The ephemeral X25519 secret defeats a passive recording of the pairing exchange; the pairing PSK (the QR's
    /// pairSecret) in the IKM and the transcript in `info` bind the key to the authenticated pairing channel and to
    /// both identities.
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
