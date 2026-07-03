import Foundation
import LocalAuthentication
import Security

/// Simple Keychain wrapper for storing sensitive strings.
///
/// Storage strategy: prefer the modern data-protection keychain (no repeated
/// ACL prompts for rebuilt dev-signed apps). Under App Sandbox with an
/// ad-hoc signature, that keychain is unavailable — SecItem* returns
/// errSecMissingEntitlement (-34018) because there is no application
/// identifier — so every operation falls back to the legacy file-based
/// keychain, which works sandboxed without a team identity. Properly signed
/// builds (Developer ID / MAS) never hit the fallback.
enum KeychainHelper {
    static let service = "at.freeq.macos"

    static func baseQuery(key: String, dataProtection: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if dataProtection {
            // Use the modern data-protection keychain instead of the
            // legacy macOS keychain ACL path. The legacy path prompts
            // repeatedly for rebuilt/dev-signed apps.
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// Legacy fallback query — no data-protection flag, and interaction is
    /// allowed (the legacy path may show a one-time ACL prompt).
    static func legacyQuery(key: String) -> [String: Any] {
        baseQuery(key: key, dataProtection: false)
    }

    static func noninteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    static func loadQuery(key: String, dataProtection: Bool = true) -> [String: Any] {
        var query = baseQuery(key: key, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if dataProtection {
            query[kSecUseAuthenticationContext as String] = noninteractiveContext()
        }
        return query
    }

    /// Persist `value` for `key`. Returns true on success. Callers
    /// MUST check the return — silent failure leaves the user with an
    /// unauthed restart loop (e.g. locked keychain, quota, sandbox
    /// permission denial), which the prior implementation hid.
    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        if save(key: key, data: data, dataProtection: true) { return true }
        Log.auth.warning("KeychainHelper: data-protection save failed (status=\(lastStatus, privacy: .public)) — trying legacy keychain for key=\(key, privacy: .public)")
        return save(key: key, data: data, dataProtection: false)
    }

    /// Status of the most recent low-level operation (for fallback routing).
    private nonisolated(unsafe) static var lastStatus: OSStatus = errSecSuccess

    private static func save(key: String, data: Data, dataProtection: Bool) -> Bool {
        let query = baseQuery(key: key, dataProtection: dataProtection)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        lastStatus = updateStatus
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            if updateStatus != errSecMissingEntitlement {
                Log.auth.error("KeychainHelper.update failed key=\(key, privacy: .public) status=\(updateStatus, privacy: .public)")
            }
            return false
        }

        var add = query
        for (attributeKey, value) in attributes {
            add[attributeKey] = value
        }
        let status = SecItemAdd(add as CFDictionary, nil)
        lastStatus = status
        if status != errSecSuccess {
            if status != errSecMissingEntitlement {
                Log.auth.error("KeychainHelper.save failed key=\(key, privacy: .public) status=\(status, privacy: .public)")
            }
            return false
        }
        return true
    }

    static func load(key: String) -> String? {
        // Try both stores: the item may live in either depending on the
        // signing/sandbox mode that wrote it, and SecItemCopyMatching does
        // not reliably surface errSecMissingEntitlement (an unavailable
        // data-protection store can read as item-not-found). A miss in the
        // legacy store is harmless — our own items carry our ACL, so no
        // prompt fires for them.
        if let value = load(key: key, dataProtection: true) { return value }
        return load(key: key, dataProtection: false)
    }

    private static func load(key: String, dataProtection: Bool) -> String? {
        let query = loadQuery(key: key, dataProtection: dataProtection)
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        lastStatus = status
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        // Best-effort in both stores — an item may exist in either after a
        // signing-mode change.
        SecItemDelete(baseQuery(key: key, dataProtection: true) as CFDictionary)
        SecItemDelete(legacyQuery(key: key) as CFDictionary)
    }
}
