package dev.fluxdown.android.ui.queue
import dev.fluxdown.android.*
import dev.fluxdown.android.ui.*
import dev.fluxdown.android.ui.queue.*
import dev.fluxdown.android.ui.settings.*
import dev.fluxdown.android.ui.newtask.*

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
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
internal fun TaskActionsDialog(
    task: QueueTask,
    onDismiss: () -> Unit,
    onPause: () -> Unit,
    onResume: () -> Unit,
    onRetry: () -> Unit,
    onOpen: () -> Unit,
    onShare: () -> Unit,
    onCopySource: () -> Unit,
    onDetails: () -> Unit,
    onProperties: () -> Unit,
    onRemove: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(tr(Str.TaskActions), fontSize = 17.sp, fontWeight = FontWeight.Medium) },
        text = {
            Column(Modifier.fillMaxWidth()) {
                Text(task.displayName, maxLines = 2, overflow = TextOverflow.Ellipsis, fontSize = 12.sp, color = FluxPalette.textSecondary)
                val failure = localizedError(task.errorCode, task.error)
                if (task.state == "failed" && failure != null) {
                    Spacer(Modifier.height(6.dp))
                    Text(tr(Str.FieldFailureReason), fontSize = 11.sp, color = FluxPalette.danger)
                    Text(failure, fontSize = 11.sp, color = FluxPalette.dangerText, maxLines = 6, overflow = TextOverflow.Ellipsis)
                }
                Spacer(Modifier.height(8.dp))
                if (task.state == "running") {
                    TaskActionButton(Icons.Default.Pause, tr(Str.Pause), onPause)
                } else if (task.state == "paused") {
                    TaskActionButton(Icons.Default.PlayArrow, tr(Str.Continue), onResume)
                }
                if (task.state == "failed") {
                    TaskActionButton(Icons.Default.Refresh, tr(Str.Retry), onRetry)
                } else if (task.state == "finished") {
                    // 作者: long
                    // 完成任务重新运行需要清理旧断点并重新请求源文件；单独使用“重新下载”文案，避免和失败任务的“重试”混淆。
                    TaskActionButton(Icons.Default.Refresh, tr(Str.Redownload), onRetry)
                }
                val selectedTorrentFiles = task.torrentFiles.count {
                    task.torrentFileIndices.isEmpty() || it.index in task.torrentFileIndices
                }
                if (task.state == "finished" && selectedTorrentFiles <= 1) {
                    TaskActionButton(Icons.AutoMirrored.Filled.OpenInNew, tr(Str.OpenFile), onOpen)
                    TaskActionButton(Icons.Default.Share, tr(Str.ShareFile), onShare)
                }
                if (task.isTorrentResource) {
                    TaskActionButton(Icons.Default.FolderOpen, tr(Str.ResourceDetails), onDetails)
                }
                TaskActionButton(Icons.Default.Info, tr(Str.Properties), onProperties)
                TaskActionButton(Icons.Default.ContentCopy, tr(Str.CopyLink), onCopySource)
                TaskActionButton(Icons.Default.DeleteOutline, tr(Str.DeleteTask), onRemove, destructive = true)
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(tr(Str.Close)) } },
    )
}

@Composable
internal fun TaskActionButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
    destructive: Boolean = false,
) {
    TextButton(onClick = onClick, modifier = Modifier.fillMaxWidth()) {
        Icon(icon, contentDescription = null, tint = if (destructive) FluxPalette.danger else MaterialTheme.colorScheme.primary)
        Spacer(Modifier.width(10.dp))
        Text(label, modifier = Modifier.weight(1f), color = if (destructive) FluxPalette.danger else FluxPalette.textStrongAlt)
    }
}
