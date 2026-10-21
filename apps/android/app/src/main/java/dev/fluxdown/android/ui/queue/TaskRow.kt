package dev.fluxdown.android.ui.queue
import dev.fluxdown.android.*
import dev.fluxdown.android.ui.*
import dev.fluxdown.android.ui.queue.*
import dev.fluxdown.android.ui.settings.*
import dev.fluxdown.android.ui.newtask.*

import androidx.compose.foundation.background
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.fluxdown.android.data.*
import dev.fluxdown.android.viewmodel.*
import dev.fluxdown.android.ui.i18n.*

@Composable
@OptIn(ExperimentalFoundationApi::class)
internal fun TaskRow(task: QueueTask, model: NativeViewModel) {
    val (tint, background, border, progressFill) = when (task.state) {
        "finished", "handed-off" -> listOf(FluxPalette.success, FluxPalette.successSurfaceSoft, FluxPalette.borderSuccess, FluxPalette.borderSuccess)
        "failed" -> listOf(FluxPalette.danger, FluxPalette.dangerSurfaceSoft, FluxPalette.borderDangerStrong, FluxPalette.borderDanger)
        "paused" -> listOf(FluxPalette.warningAlt2, FluxPalette.warningSurfaceSoft, FluxPalette.borderWarning, FluxPalette.borderWarning)
        else -> listOf(FluxPalette.accent, FluxPalette.backgroundAlt, FluxPalette.borderAccentStrong, FluxPalette.progressTrack)
    }
    Card(
        modifier = Modifier.fillMaxWidth().combinedClickable(
            onClick = {
                if (task.isTorrentResource) {
                    model.showTorrentDetails(task)
                } else if (task.state == "paused") {
                    model.resume(task)
                } else if (task.state == "running") {
                    model.pause(task)
                }
            },
            onLongClick = {
                model.showTaskActions(task)
            },
        ),
        colors = CardDefaults.cardColors(containerColor = background),
        shape = RoundedCornerShape(8.dp),
        border = BorderStroke(1.dp, border),
    ) {
        BoxWithConstraints {
            if (task.totalBytes != null && task.totalBytes > 0L && task.progress > 0f) {
                Box(
                    Modifier
                        .width(maxWidth * task.progress)
                        .matchParentSize()
                        .background(progressFill),
                )
            }
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 5.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier.size(25.dp).clip(RoundedCornerShape(7.dp)).background(FluxPalette.surfaceCard.copy(alpha = 0.76f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        if (task.isTorrentResource) Icons.Default.FolderOpen else Icons.Default.Download,
                        contentDescription = null,
                        tint = tint,
                        modifier = Modifier.size(14.dp),
                    )
                }
                Spacer(Modifier.width(8.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            task.displayName,
                            modifier = Modifier.weight(1f),
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            fontSize = 12.sp,
                            lineHeight = 14.sp,
                            color = FluxPalette.textPrimary,
                        )
                        Spacer(Modifier.width(5.dp))
                        Surface(color = tint.copy(alpha = 0.14f), shape = RoundedCornerShape(5.dp)) {
                            Text(
                                when (task.state) {
                                    "running" -> "${(task.progress * 100).toInt()}%"
                                    "finished" -> tr(Str.DoneShort)
                                    else -> task.stateLabel(LocalLanguage.current)
                                },
                                color = tint,
                                fontSize = 9.5.sp,
                                modifier = Modifier.padding(horizontal = 5.dp, vertical = 2.dp),
                                maxLines = 1,
                            )
                        }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            "${formatBytes(task.downloadedBytes)}/${task.totalBytes?.let(::formatBytes) ?: tr(Str.Unknown)}",
                            fontSize = 10.sp,
                            color = FluxPalette.textSecondary,
                        )
                        Spacer(Modifier.weight(1f))
                        if (task.state == "running") {
                            val segmentLabel = task.hlsSegmentLabel(LocalLanguage.current)
                            Text(
                                buildString {
                                    if (segmentLabel != null) append("$segmentLabel · ")
                                    append(tr(Str.SpeedValue, formatBytes(task.speedBytesPerSecond)))
                                },
                                fontSize = 10.sp,
                                color = FluxPalette.textSecondary,
                            )
                        } else if (task.state == "finished") {
                            Text(
                                task.finishedAtMs?.let(::formatTaskTime) ?: "--",
                                fontSize = 10.sp,
                                color = tint,
                                maxLines = 1,
                            )
                        } else if (task.state == "failed") {
                            Text(
                                buildString {
                                    task.hlsSegmentLabel(LocalLanguage.current)?.let { append("$it · ") }
                                    append(tr(Str.StateFailed))
                                },
                                fontSize = 10.sp,
                                color = tint,
                            )
                        }
                    }
                    if (task.state == "failed" && !task.error.isNullOrBlank()) {
                        Text(task.error, color = FluxPalette.danger, fontSize = 9.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        }
    }
}
