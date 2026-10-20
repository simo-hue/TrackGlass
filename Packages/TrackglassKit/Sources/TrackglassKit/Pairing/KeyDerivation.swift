import CryptoKit
import Foundation

public enum KeyDerivationError: Error, Equatable, Sendable {
    case invalidPIN
    case invalidPairID
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
}
