package com.freeq.model

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.URL
import java.net.URLEncoder

/**
 * The signing key a DID uses to sign its messages, as returned by
 * `GET /api/v1/signing-keys/{did}`.
 */
data class SigningKeyInfo(
    val publicKey: String,
    val algorithm: String,
    val source: String,
) {
    /** Client-session keys mean the message was signed on the sender's own
     *  device — true non-repudiation, not the server vouching. */
    val sourceLabel: String
        get() = if (source == "client-session") "signed on their device" else "server-attested"
}

/**
 * The checked outcome of verifying a specific message's signature, from
 * `GET /api/v1/verify/{msgid}`. This is an actual ed25519 check the server
 * performed over the canonical bytes — not an assertion from a tag's presence.
 */
data class VerifyResult(
    val valid: Boolean,
    val verifiedBy: String, // "client-session-key" | "server-key" | "none"
) {
    val summary: String
        get() = when {
            valid && verifiedBy == "client-session-key" ->
                "Verified — this message was signed on the sender's own device."
            valid && verifiedBy == "server-key" ->
                "Verified — signed by the server on the sender's behalf."
            valid -> "Verified — the signature checks out."
            else -> "This message's signature could not be verified."
        }
}

/**
 * Honest signature verification: asks the server to actually verify a message's
 * signature and to surface the sender's real signing key. Mirrors the iOS
 * VerifiedProofSheet / web MessageList flow against the same REST endpoints.
 * A null result means "unavailable" — we never claim a verdict we didn't get.
 */
object VerificationService {

    /** Verify one message's ed25519 signature. null on any error → "unavailable". */
    suspend fun verifyMessage(msgId: String): VerifyResult? = withContext(Dispatchers.IO) {
        try {
            val enc = URLEncoder.encode(msgId, "UTF-8")
            val url = URL("${ServerConfig.apiBaseUrl}/api/v1/verify/$enc")
            val conn = url.openConnection().apply {
                connectTimeout = 5000
                readTimeout = 5000
            }
            val text = conn.getInputStream().bufferedReader().readText()
            val json = JSONObject(text)
            // `verification` is null for an unsigned message; a present object
            // carries the real check. Mirror iOS: a successful fetch always
            // yields a verdict (valid=false/none when there's nothing to check),
            // and only a transport/HTTP failure leaves it "unavailable" (null).
            val v = json.optJSONObject("verification")
            VerifyResult(
                valid = v?.optBoolean("valid") ?: false,
                verifiedBy = v?.optString("verified_by")?.takeIf { it.isNotEmpty() } ?: "none",
            )
        } catch (_: Exception) {
            null
        }
    }

    /** Fetch the signing key a DID publishes. null on any error. */
    suspend fun fetchSigningKey(did: String): SigningKeyInfo? = withContext(Dispatchers.IO) {
        try {
            val enc = URLEncoder.encode(did, "UTF-8")
            val url = URL("${ServerConfig.apiBaseUrl}/api/v1/signing-keys/$enc")
            val conn = url.openConnection().apply {
                connectTimeout = 5000
                readTimeout = 5000
            }
            val text = conn.getInputStream().bufferedReader().readText()
            val json = JSONObject(text)
            val pk = json.optString("public_key").takeIf { it.isNotEmpty() }
                ?: return@withContext null
            SigningKeyInfo(
                publicKey = pk,
                algorithm = json.optString("algorithm").takeIf { it.isNotEmpty() } ?: "ed25519",
                source = json.optString("source"),
            )
        } catch (_: Exception) {
            null
        }
    }
}
