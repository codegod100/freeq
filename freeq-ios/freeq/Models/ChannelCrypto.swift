import Foundation
import CryptoKit

/// Passphrase-based channel E2EE, wire-compatible with the Rust SDK
/// (`freeq-sdk/src/e2ee.rs`) and the web client (`lib/e2ee.ts`).
///
/// Wire format: `ENC1:<nonce-base64>:<ciphertext+tag-base64>`
/// Key: HKDF-SHA256(ikm: passphrase, salt: SHA256(lowercased channel),
/// info: "freeq-e2ee-v1") → AES-256-GCM.
enum ChannelCrypto {
    static let encPrefix = "ENC1:"
    private static let hkdfInfo = Data("freeq-e2ee-v1".utf8)

    enum CryptoError: Error, Equatable {
        case notEncrypted
        case malformed
        case decryptFailed
        case invalidUTF8
    }

    /// Derive the channel key. Salting with the lowercased channel name means
    /// the same passphrase yields different keys in different channels.
    static func deriveKey(passphrase: String, channel: String) -> SymmetricKey {
        let salt = SHA256.hash(data: Data(channel.lowercased().utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(passphrase.utf8)),
            salt: Data(salt),
            info: hkdfInfo,
            outputByteCount: 32
        )
    }

    /// Encrypt to wire format. `nonce` is injectable for deterministic tests
    /// only — production callers must leave it nil for a random nonce.
    static func encrypt(key: SymmetricKey, plaintext: String, nonce: Data? = nil) throws -> String {
        let gcmNonce: AES.GCM.Nonce
        if let nonce {
            gcmNonce = try AES.GCM.Nonce(data: nonce)
        } else {
            gcmNonce = AES.GCM.Nonce()
        }
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key, nonce: gcmNonce)
        // Rust's aes-gcm appends the 16-byte tag to the ciphertext.
        let ciphertextAndTag = sealed.ciphertext + sealed.tag
        let nonceB64 = Data(gcmNonce).base64EncodedString()
        return "\(encPrefix)\(nonceB64):\(ciphertextAndTag.base64EncodedString())"
    }

    /// Decrypt a wire-format message. Throws `.notEncrypted` when the text has
    /// no ENC1 prefix so callers can pass every incoming message through.
    static func decrypt(key: SymmetricKey, wire: String) throws -> String {
        guard wire.hasPrefix(encPrefix) else { throw CryptoError.notEncrypted }
        let body = wire.dropFirst(encPrefix.count)
        guard let colon = body.firstIndex(of: ":") else { throw CryptoError.malformed }

        guard
            let nonceData = Data(base64Encoded: String(body[..<colon])),
            let ctData = Data(base64Encoded: String(body[body.index(after: colon)...])),
            nonceData.count == 12,
            ctData.count >= 16
        else { throw CryptoError.malformed }

        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData),
                ciphertext: ctData.dropLast(16),
                tag: ctData.suffix(16)
            )
            let plain = try AES.GCM.open(box, using: key)
            guard let text = String(data: plain, encoding: .utf8) else {
                throw CryptoError.invalidUTF8
            }
            return text
        } catch let error as CryptoError {
            throw error
        } catch {
            throw CryptoError.decryptFailed
        }
    }

    static func isEncrypted(_ text: String) -> Bool {
        text.hasPrefix(encPrefix)
    }
}
