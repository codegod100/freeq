import Foundation
import CryptoKit

/// Policy layer for passphrase channel E2EE: holds per-channel keys, decides
/// what to encrypt on send, and how to display incoming ciphertext. Pure
/// value type so the whole send/receive decision tree is unit-testable;
/// `AppState` owns an instance and handles keychain persistence around it.
struct ChannelE2eeState {
    static let echoCacheLimit = 64
    static let undecryptablePlaceholder = "[encrypted message]"

    private var keys: [String: SymmetricKey] = [:]
    /// Ciphertext → plaintext for our own in-flight messages, so the server
    /// echo renders instantly without a decrypt round (matches web client).
    private var echoCache: [String: String] = [:]
    private var echoOrder: [String] = []

    var echoCacheCount: Int { echoCache.count }

    // MARK: - Key management

    mutating func setKey(channel: String, passphrase: String) {
        keys[channel.lowercased()] = ChannelCrypto.deriveKey(passphrase: passphrase, channel: channel)
    }

    mutating func removeKey(channel: String) {
        keys[channel.lowercased()] = nil
    }

    func hasKey(channel: String) -> Bool {
        keys[channel.lowercased()] != nil
    }

    /// Base64 of the derived key, for keychain persistence.
    func exportKey(channel: String) -> String? {
        keys[channel.lowercased()]?.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    /// Restore a previously exported key. Ignores malformed input.
    mutating func importKey(channel: String, base64: String) {
        guard let data = Data(base64Encoded: base64), data.count == 32 else { return }
        keys[channel.lowercased()] = SymmetricKey(data: data)
    }

    // MARK: - Send path

    /// Returns the ENC1 wire text when this channel has a key, nil otherwise
    /// (caller sends plaintext). Successful encryption is echo-cached.
    mutating func outgoing(text: String, channel: String) -> String? {
        guard let key = keys[channel.lowercased()] else { return nil }
        guard let wire = try? ChannelCrypto.encrypt(key: key, plaintext: text) else { return nil }
        let cacheKey = Self.echoKey(channel: channel, wire: wire)
        echoCache[cacheKey] = text
        echoOrder.append(cacheKey)
        if echoOrder.count > Self.echoCacheLimit {
            echoCache[echoOrder.removeFirst()] = nil
        }
        return wire
    }

    // MARK: - Receive path

    /// Map an incoming channel message body to its display form.
    mutating func incoming(text: String, channel: String) -> (display: String, isEncrypted: Bool) {
        guard ChannelCrypto.isEncrypted(text) else { return (text, false) }

        let cacheKey = Self.echoKey(channel: channel, wire: text)
        if let cached = echoCache.removeValue(forKey: cacheKey) {
            echoOrder.removeAll { $0 == cacheKey }
            return (cached, true)
        }
        if let key = keys[channel.lowercased()],
           let plain = try? ChannelCrypto.decrypt(key: key, wire: text) {
            return (plain, true)
        }
        return (Self.undecryptablePlaceholder, true)
    }

    /// Echo-cache entries are per-channel so our ciphertext relayed into a
    /// different channel never renders as plaintext there.
    private static func echoKey(channel: String, wire: String) -> String {
        channel.lowercased() + "\u{0}" + wire
    }
}
