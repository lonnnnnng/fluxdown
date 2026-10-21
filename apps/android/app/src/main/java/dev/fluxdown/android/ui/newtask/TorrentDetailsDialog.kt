package dev.fluxdown.android.ui.newtask
import dev.fluxdown.android.*
import dev.fluxdown.android.ui.*
import dev.fluxdown.android.ui.queue.*
import dev.fluxdown.android.ui.settings.*
import dev.fluxdown.android.ui.newtask.*

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.fluxdown.android.data.*
import dev.fluxdown.android.viewmodel.*
import dev.fluxdown.android.ui.i18n.*

@Composable
internal fun TorrentDetailsDialog(
    selection: TorrentSelection,
    onDismiss: () -> Unit,
    onOpenFile: ((TorrentFileSelection) -> Unit)?,
    onShareFile: ((TorrentFileSelection) -> Unit)?,
) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(
            modifier = Modifier.fillMaxWidth().fillMaxSize(0.88f).padding(12.dp),
            shape = RoundedCornerShape(18.dp),
            color = FluxPalette.surfaceCard,
        ) {
            Column(Modifier.fillMaxSize().padding(18.dp)) {
                Text(tr(Str.ResourceDetails), fontSize = 19.sp, fontWeight = FontWeight.Medium)
                Spacer(Modifier.height(4.dp))
                Text(
                    selection.directoryName,
                    fontSize = 14.sp,
                    color = FluxPalette.textStrongAlt4,
                )
                selection.infoHash?.let { hash ->
                    Text("Info hash：$hash", fontSize = 10.sp, color = FluxPalette.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Spacer(Modifier.height(12.dp))
                Text(tr(Str.ConfirmedFiles, selection.files.size), fontSize = 12.sp, color = FluxPalette.textSecondary)
                Spacer(Modifier.height(6.dp))
                LazyColumn(
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    items(selection.files, key = { it.index }) { file ->
                        Column(Modifier.fillMaxWidth().padding(vertical = 7.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    file.path,
                                    modifier = Modifier.weight(1f).then(
                                        if (onOpenFile != null) Modifier.clickable { onOpenFile(file) } else Modifier,
                                    ),
                                    fontSize = 13.sp,
                                )
                                if (onOpenFile != null) {
                                    IconButton(onClick = { onOpenFile(file) }, modifier = Modifier.size(32.dp)) {
                                        Icon(Icons.AutoMirrored.Filled.OpenInNew, contentDescription = tr(Str.OpenNamed, file.name), modifier = Modifier.size(17.dp))
                                    }
                                }
                                if (onShareFile != null) {
                                    IconButton(onClick = { onShareFile(file) }, modifier = Modifier.size(32.dp)) {
                                        Icon(Icons.Default.Share, contentDescription = tr(Str.ShareNamed, file.name), modifier = Modifier.size(17.dp))
                                    }
                                }
                            }
                            val progress = file.progressBytes
                            Text(
                                if (progress == null) {
                                    "${file.name.substringAfterLast('.', tr(Str.FileWord)).uppercase()} · ${formatBytes(file.size)} · ${tr(Str.DownloadedUnknown)}"
                                } else {
                                    "${file.name.substringAfterLast('.', tr(Str.FileWord)).uppercase()} · ${formatBytes(progress)} / ${formatBytes(file.size)}"
                                },
                                fontSize = 11.sp,
                                color = FluxPalette.textMuted,
                            )
                            if (progress != null && file.size > 0) {
                                Spacer(Modifier.height(4.dp))
                                LinearProgressIndicator(
                                    progress = { (progress.toDouble() / file.size).coerceIn(0.0, 1.0).toFloat() },
                                    modifier = Modifier.fillMaxWidth().height(3.dp).clip(RoundedCornerShape(3.dp)),
                                    color = MaterialTheme.colorScheme.primary,
                                    trackColor = FluxPalette.surfaceMutedAlt2,
                                )
                            }
                        }
                    }
                }
                Spacer(Modifier.height(8.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    Button(onClick = onDismiss) { Text(tr(Str.Close)) }
                }
            }
        }
    }
}
