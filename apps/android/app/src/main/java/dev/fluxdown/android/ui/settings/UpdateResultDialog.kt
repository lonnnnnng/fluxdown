package dev.fluxdown.android.ui.settings
import dev.fluxdown.android.*
import dev.fluxdown.android.ui.*
import dev.fluxdown.android.ui.queue.*
import dev.fluxdown.android.ui.settings.*
import dev.fluxdown.android.ui.newtask.*

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.fluxdown.android.data.*
import dev.fluxdown.android.platform.AndroidUpdateReport
import dev.fluxdown.android.viewmodel.*
import dev.fluxdown.android.ui.i18n.*

@Composable
internal fun UpdateResultDialog(
    report: AndroidUpdateReport,
    onDismiss: () -> Unit,
    onDownload: (() -> Unit)?,
    onOpenRelease: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (report.hasUpdate) tr(Str.UpdateFound, report.latestVersion) else tr(Str.UpToDate), fontSize = 16.sp) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(tr(Str.CurrentVersionLabel, report.currentVersion), fontSize = 12.sp, color = FluxPalette.textSecondary)
                report.releaseNotes?.takeIf { it.isNotBlank() }?.let {
                    Text(tr(Str.UpdateNotes), fontSize = 12.sp, color = FluxPalette.textStrongAlt4)
                    Text(it, fontSize = 11.sp, color = FluxPalette.textSecondary, maxLines = 8, overflow = TextOverflow.Ellipsis)
                }
            }
        },
        confirmButton = {
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                if (report.hasUpdate && onDownload != null) TextButton(onClick = onDownload) { Text(tr(Str.DownloadUpdate)) }
                TextButton(onClick = onOpenRelease) { Text(tr(Str.OpenDownloadPage)) }
                TextButton(onClick = onDismiss) { Text(tr(Str.Confirm)) }
            }
        },
    )
}
