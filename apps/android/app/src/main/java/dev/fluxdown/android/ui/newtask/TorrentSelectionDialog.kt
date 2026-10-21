package dev.fluxdown.android.ui.newtask
import dev.fluxdown.android.*
import dev.fluxdown.android.ui.*
import dev.fluxdown.android.ui.queue.*
import dev.fluxdown.android.ui.settings.*
import dev.fluxdown.android.ui.newtask.*

import androidx.compose.foundation.BorderStroke
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.fluxdown.android.data.*
import dev.fluxdown.android.viewmodel.*
import dev.fluxdown.android.ui.i18n.*

@Composable
internal fun TorrentSelectionDialog(
    selection: TorrentSelection,
    isConfirming: Boolean,
    error: String?,
    onDismiss: () -> Unit,
    onConfirm: (Set<Int>) -> Unit,
) {
    var selectedIndexes by remember(selection.files) {
        mutableStateOf(selection.files.map { it.index }.toSet())
    }
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
                Text(selection.directoryName, fontSize = 14.sp, color = FluxPalette.textStrongAlt4)
                selection.infoHash?.let { hash ->
                    Text("Info hash：$hash", fontSize = 10.sp, color = FluxPalette.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Spacer(Modifier.height(12.dp))
                Text(tr(Str.SelectFilesTitle, selectedIndexes.size, selection.files.size), fontSize = 12.sp, color = FluxPalette.textSecondary)
                error?.let { message ->
                    Spacer(Modifier.height(6.dp))
                    Card(
                        modifier = Modifier.fillMaxWidth(),
                        colors = CardDefaults.cardColors(containerColor = FluxPalette.dangerSurface),
                        border = BorderStroke(1.dp, FluxPalette.borderDanger),
                    ) {
                        Text(tr(Str.AddToQueueFailed, message), modifier = Modifier.padding(9.dp), fontSize = 11.sp, color = FluxPalette.dangerText)
                    }
                }
                Spacer(Modifier.height(6.dp))
                LazyColumn(
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    items(selection.files, key = { it.index }) { file ->
                        val checked = file.index in selectedIndexes
                        Row(
                            modifier = Modifier.fillMaxWidth().clickable {
                                selectedIndexes = if (checked) selectedIndexes - file.index else selectedIndexes + file.index
                            }.padding(vertical = 7.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Checkbox(
                                checked = checked,
                                onCheckedChange = { value ->
                                    selectedIndexes = if (value) selectedIndexes + file.index else selectedIndexes - file.index
                                },
                            )
                            Spacer(Modifier.width(6.dp))
                            Column(Modifier.weight(1f)) {
                                Text(file.path, fontSize = 13.sp)
                                Text(
                                    "${file.name.substringAfterLast('.', tr(Str.FileWord)).uppercase()} · ${formatBytes(file.size)}",
                                    fontSize = 11.sp,
                                    color = FluxPalette.textMuted,
                                )
                            }
                        }
                    }
                }
                Spacer(Modifier.height(8.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    OutlinedButton(onClick = onDismiss, enabled = !isConfirming) { Text(tr(Str.Cancel)) }
                    Spacer(Modifier.width(8.dp))
                    Button(onClick = { onConfirm(selectedIndexes) }, enabled = selectedIndexes.isNotEmpty() && !isConfirming) {
                        Text(tr(Str.ConfirmAndAdd))
                    }
                }
            }
        }
    }
}
