import Foundation

// The data behind the verified-proof sheet: the message-signing key published
// at `/api/v1/signing-keys/{did}` and the checked verification result from
// `/api/v1/verify/{msgid}`. Pure parsing + presentation strings — the sheet
// does the fetching; these stay testable under `swift test`.

/// The checked outcome of verifying a specific message's signature.
struct VerifyResult: Equatable {
    let valid: Bool
    let verifiedBy: String  // "client-session-key" | "server-key" | "none"

    /// The honest, checked verdict — reports exactly what the server checked,
    /// never an assertion.
    var summary: String {
        switch (valid, verifiedBy) {
        case (true, "client-session-key"):
            return "Verified — this message was signed on the sender's own device."
        case (true, "server-key"):
            return "Verified — signed by the server on the sender's behalf."
        case (true, _):
            return "Verified — the signature checks out."
        default:
            return "This message's signature could not be verified."
        }
    }

    /// Parse the `/api/v1/verify/{msgid}` response body. The server returns a
    /// `verification` object (or null when the message is unsigned).
    static func from(json: [String: Any]) -> VerifyResult {
        let v = json["verification"] as? [String: Any]
        return VerifyResult(
            valid: v?["valid"] as? Bool ?? false,
            verifiedBy: v?["verified_by"] as? String ?? "none"
        )
    }
}

/// A sender's published message-signing key.
struct SigningKeyInfo: Equatable {
    let publicKey: String
    let algorithm: String
    let source: String

    /// Client-session keys mean the message was signed on the sender's own
    /// device — true non-repudiation, not the server vouching.
    var sourceLabel: String {
        source == "client-session" ? "signed on their device" : "server-attested"
    }

    /// Parse the `/api/v1/signing-keys/{did}` response body.
    static func from(json: [String: Any]) -> SigningKeyInfo? {
        guard let pk = json["public_key"] as? String else { return nil }
        return SigningKeyInfo(
            publicKey: pk,
            algorithm: json["algorithm"] as? String ?? "ed25519",
            source: json["source"] as? String ?? ""
        )
    }
}
