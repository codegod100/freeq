package com.freeq.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.freeq.model.SigningKeyInfo
import com.freeq.model.VerificationService
import com.freeq.model.VerifyResult
import com.freeq.ui.theme.FreeqColors
import kotlinx.coroutines.delay

/**
 * The differentiator, made tangible. Tap a verified seal and see the actual
 * proof: the DID that IS this person, the key they sign every message with,
 * and — for a specific message — the server's real ed25519 check of its
 * signature. Mirrors iOS VerifiedProofSheet against the same REST endpoints.
 * A missing/failed check reads "unavailable" — never a claim we didn't verify.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VerifiedProofSheet(
    did: String,
    handle: String? = null,
    displayName: String? = null,
    /** When set, prove this specific message was signed by this identity. */
    msgId: String? = null,
    onDismiss: () -> Unit,
) {
    var key by remember { mutableStateOf<SigningKeyInfo?>(null) }
    var keyLoading by remember { mutableStateOf(true) }
    var verify by remember { mutableStateOf<VerifyResult?>(null) }
    var verifying by remember { mutableStateOf(msgId != null) }

    LaunchedEffect(did) {
        keyLoading = true
        key = VerificationService.fetchSigningKey(did)
        keyLoading = false
    }
    LaunchedEffect(msgId) {
        val id = msgId ?: return@LaunchedEffect
        verifying = true
        verify = VerificationService.verifyMessage(id)
        verifying = false
    }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp)
                .padding(bottom = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Icon(
                Icons.Default.CheckCircle,
                contentDescription = null,
                tint = FreeqColors.success,
                modifier = Modifier.size(64.dp),
            )
            Spacer(Modifier.height(12.dp))
            Text(
                text = displayName ?: handle?.let { "@$it" } ?: "Verified identity",
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = "Verified via the AT Protocol",
                fontSize = 13.sp,
                color = FreeqColors.success,
            )
            Spacer(Modifier.height(16.dp))
            Text(
                text = "This is a real, self-owned identity. Its owner holds the key " +
                    "below and signs everything they send — so no one can impersonate " +
                    "them, on freeq or anywhere else on the network.",
                fontSize = 14.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(20.dp))

            ProofCard(
                label = "DECENTRALIZED IDENTIFIER",
                value = did,
                detail = handle?.let { "resolves to @$it" },
                copyable = true,
            )

            Spacer(Modifier.height(12.dp))

            if (key != null) {
                ProofCard(
                    label = "MESSAGE SIGNING KEY",
                    value = key!!.publicKey,
                    detail = "${key!!.algorithm.uppercase()} · ${key!!.sourceLabel}",
                    copyable = false,
                )
            } else if (keyLoading) {
                CircularProgressIndicator(
                    modifier = Modifier.size(20.dp),
                    strokeWidth = 2.dp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            if (msgId != null) {
                Spacer(Modifier.height(12.dp))
                MessageVerdict(verifying = verifying, verify = verify)
            }
        }
    }
}

@Composable
private fun ProofCard(
    label: String,
    value: String,
    detail: String?,
    copyable: Boolean,
) {
    val clipboard = LocalClipboardManager.current
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            delay(1400)
            copied = false
        }
    }

    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
        shape = RoundedCornerShape(14.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = label,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.weight(1f))
                if (copyable) {
                    Text(
                        text = if (copied) "Copied" else "Copy",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = if (copied) FreeqColors.success else FreeqColors.accent,
                        modifier = Modifier.clickable {
                            clipboard.setText(AnnotatedString(value))
                            copied = true
                        },
                    )
                }
            }
            Spacer(Modifier.height(8.dp))
            Text(
                text = value,
                fontSize = 13.sp,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (detail != null) {
                Spacer(Modifier.height(4.dp))
                Text(
                    text = detail,
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/** The honest, checked result for a specific message — not an assertion. */
@Composable
private fun MessageVerdict(verifying: Boolean, verify: VerifyResult?) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
        shape = RoundedCornerShape(14.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            when {
                verifying -> {
                    CircularProgressIndicator(
                        modifier = Modifier.size(16.dp),
                        strokeWidth = 2.dp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = "Checking this message's signature…",
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                verify != null -> {
                    Icon(
                        if (verify.valid) Icons.Default.CheckCircle else Icons.Default.Warning,
                        contentDescription = null,
                        tint = if (verify.valid) FreeqColors.success else FreeqColors.warning,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = verify.summary,
                        fontSize = 12.sp,
                        color = if (verify.valid) MaterialTheme.colorScheme.onSurface
                        else FreeqColors.warning,
                    )
                }
                else -> {
                    Icon(
                        Icons.Default.Info,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = "Signature status unavailable.",
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}
