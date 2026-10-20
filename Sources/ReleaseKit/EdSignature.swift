import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

/// Sparkle's EdDSA update signature: Ed25519 over the archive bytes, base64 in the appcast and in `SUPublicEDKey`.
public enum EdSignature {
    public enum Outcome: Equatable, Sendable {
        case valid
        case invalid(String)
        /// CryptoKit isn't available on this platform, so nothing was checked. Callers treat this as a failure.
        case unverifiable
    }

    public static func verify(archive: Data, signature: String, publicKey: String) -> Outcome {
        guard let keyData = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)),
            keyData.count == 32
        else { return .invalid("the public key isn't 32 bytes of base64") }
        guard let signatureData = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
            signatureData.count == 64
        else { return .invalid("the signature isn't 64 bytes of base64") }
        #if canImport(CryptoKit)
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            return .invalid("the public key isn't a valid Ed25519 key")
        }
        return key.isValidSignature(signatureData, for: archive)
            ? .valid : .invalid("the signature doesn't match the archive for this public key")
        #else
        return .unverifiable
        #endif
    }
}
