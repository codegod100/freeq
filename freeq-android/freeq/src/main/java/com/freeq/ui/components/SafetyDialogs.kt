package com.freeq.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.freeq.ui.theme.FreeqColors

/**
 * Reason picker shown when reporting a user (Google Play UGC policy:
 * in-app report + block). Selecting a reason invokes [onReport] with it;
 * the caller is expected to report + block + confirm via snackbar.
 */
@Composable
fun ReportReasonDialog(
    nick: String,
    onReport: (String) -> Unit,
    onDismiss: () -> Unit
) {
    val reasons = listOf(
        "Spam",
        "Harassment",
        "Sexual content",
        "Violence",
        "Impersonation",
        "Other"
    )

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Report $nick") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    "Why are you reporting this user? Reporting also blocks them on this device.",
                    fontSize = 13.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(modifier = Modifier.padding(top = 4.dp))
                reasons.forEach { reason ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onReport(reason) }
                            .padding(vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Icon(
                            Icons.Default.Flag,
                            contentDescription = null,
                            tint = FreeqColors.danger,
                            modifier = Modifier.size(16.dp)
                        )
                        Text(
                            reason,
                            fontSize = 15.sp,
                            color = MaterialTheme.colorScheme.onBackground
                        )
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        }
    )
}
