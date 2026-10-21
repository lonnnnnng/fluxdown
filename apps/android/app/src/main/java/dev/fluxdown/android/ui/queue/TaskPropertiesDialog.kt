package dev.fluxdown.android.ui.queue

import dev.fluxdown.android.ui.FluxPalette

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.fluxdown.android.data.QueueTask
import dev.fluxdown.android.data.formatAverageSpeed
import dev.fluxdown.android.data.formatBytes
import dev.fluxdown.android.data.formatDateTime
import dev.fluxdown.android.data.formatDuration
import dev.fluxdown.android.data.protocolLabelFor
import dev.fluxdown.android.data.stateLabel
import dev.fluxdown.android.platform.formatOutputLocation
import dev.fluxdown.android.ui.i18n.*

/**
 * 作者: long
 * 任务属性面板：字段与 Flutter 版 main.dart 的属性弹窗保持一致，
 * 耗时和平均速度都由队列快照里的 startedAtMs/finishedAtMs 实时计算，不使用占位值。
 */
@Composable
internal fun TaskPropertiesDialog(task: QueueTask, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val sizeText = when {
        (task.totalBytes ?: 0L) > 0L -> formatBytes(task.totalBytes!!)
        task.downloadedBytes > 0L -> tr(Str.SizeUnknown, formatBytes(task.downloadedBytes))
        else -> tr(Str.Unknown)
    }
    val speedText = buildString {
        append(tr(Str.SpeedAverage)).append(formatAverageSpeed(task))
        if (task.state == "running" && task.speedBytesPerSecond > 0L) {
            append(tr(Str.SpeedAverageWithCurrent)).append(formatBytes(task.speedBytesPerSecond)).append("/s")
        }
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(tr(Str.TaskProperties), fontSize = 17.sp, fontWeight = FontWeight.Medium) },
        text = {
            Column(
                Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState()),
            ) {
                SelectionContainer {
                    Column(Modifier.fillMaxWidth()) {
                        PropertyRow(tr(Str.FieldFileName), task.displayName)
                        PropertyRow(tr(Str.FieldSource), task.source, mono = true)
                        PropertyRow(tr(Str.FieldOutputPath), formatOutputLocation(context, task.outputDir), mono = true)
                        PropertyRow(tr(Str.FieldProtocol), protocolLabelFor(task.source, LocalLanguage.current))
                        PropertyRow(tr(Str.FieldStatus), task.stateLabel(LocalLanguage.current))
                        PropertyRow(tr(Str.FieldFileSize), sizeText)
                        PropertyRow(tr(Str.FieldStartedAt), formatDateTime(task.startedAtMs))
                        PropertyRow(tr(Str.FieldFinishedAt), formatDateTime(task.finishedAtMs))
                        PropertyRow(tr(Str.FieldElapsed), formatDuration(task.startedAtMs, task.finishedAtMs, LocalLanguage.current))
                        PropertyRow(tr(Str.FieldSpeed), speedText)
                        PropertyRow(tr(Str.FieldError), task.error?.takeIf { it.isNotBlank() } ?: tr(Str.None))
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(tr(Str.Close)) } },
    )
}

@Composable
private fun PropertyRow(label: String, value: String, mono: Boolean = false) {
    Text(label, fontSize = 11.sp, color = FluxPalette.textSecondary)
    Text(
        value,
        fontSize = 12.sp,
        color = FluxPalette.textStrongAlt,
        fontFamily = if (mono) FontFamily.Monospace else FontFamily.Default,
    )
    Spacer(Modifier.height(8.dp))
}
