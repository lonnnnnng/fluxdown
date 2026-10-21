package dev.fluxdown.android.ui.queue
import dev.fluxdown.android.*
import dev.fluxdown.android.ui.*
import dev.fluxdown.android.ui.queue.*
import dev.fluxdown.android.ui.settings.*
import dev.fluxdown.android.ui.newtask.*

import androidx.compose.foundation.background
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DeleteSweep
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
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
import dev.fluxdown.android.viewmodel.NativeUiState
import dev.fluxdown.android.viewmodel.*
import dev.fluxdown.android.ui.i18n.*

internal enum class AndroidQueueFilter(val key: String) {
    All(KotlinSettings.FILTER_ALL),
    Unfinished(KotlinSettings.FILTER_UNFINISHED),
    Ended(KotlinSettings.FILTER_ENDED),
    Failed(KotlinSettings.FILTER_FAILED),
    ;

    companion object {
        fun fromKey(key: String?): AndroidQueueFilter =
            entries.firstOrNull { it.key == key } ?: All
    }
}

@Composable
internal fun QueueScreen(state: NativeUiState, model: NativeViewModel) {
    // 作者: long
    // S6 筛选条件存在设置快照里（落盘），不再用 rememberSaveable，
    // 这样进程被杀后重启仍能回到上次的筛选页。
    val selectedFilter = AndroidQueueFilter.fromKey(state.settings.queueFilter)
    var confirmClearFinished by rememberSaveable { mutableStateOf(false) }
    val finishedCount = state.tasks.count { it.state == "finished" || it.state == "handed-off" }
    val visibleTasks = state.tasks.filter { task ->
        when (selectedFilter) {
            AndroidQueueFilter.All -> true
            AndroidQueueFilter.Unfinished -> task.state in setOf("running", "queued", "paused")
            AndroidQueueFilter.Ended -> task.state in setOf("finished", "handed-off")
            AndroidQueueFilter.Failed -> task.state == "failed"
        }
    }
    Column(Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(tr(Str.TabTasks), fontSize = 18.sp, fontWeight = FontWeight.Normal, color = FluxPalette.textPrimary, modifier = Modifier.weight(1f))
            IconButton(
                onClick = { confirmClearFinished = true },
                enabled = finishedCount > 0,
                modifier = Modifier.size(38.dp),
            ) {
                Icon(
                    Icons.Default.DeleteSweep,
                    contentDescription = tr(Str.ClearFinished),
                    tint = if (finishedCount > 0) FluxPalette.textStrong else FluxPalette.iconDisabled,
                    modifier = Modifier.size(19.dp),
                )
            }
        }
        if (state.networkPaused) {
            // 作者: long
            // S1：非 Wi-Fi 下队列被主动挂起，任务仍是 queued；这里把原因讲清楚，避免看起来像卡住。
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(FluxPalette.warningSurface)
                    .padding(horizontal = 10.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Default.WifiOff, contentDescription = null, tint = FluxPalette.warningAlt, modifier = Modifier.size(15.dp))
                Spacer(Modifier.width(8.dp))
                Text(
                    tr(Str.NetworkPaused),
                    fontSize = 11.5.sp,
                    color = FluxPalette.warning,
                    modifier = Modifier.weight(1f),
                )
            }
        }
        QueueFilterStrip(
            selected = selectedFilter,
            counts = mapOf(
                AndroidQueueFilter.All to state.tasks.size,
                AndroidQueueFilter.Unfinished to state.tasks.count { it.state in setOf("running", "queued", "paused") },
                AndroidQueueFilter.Ended to finishedCount,
                AndroidQueueFilter.Failed to state.tasks.count { it.state == "failed" },
            ),
            onSelected = { model.setQueueFilter(it.key) },
        )
        if (visibleTasks.isEmpty()) {
            EmptyQueue()
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 16.dp, end = 16.dp, top = 10.dp, bottom = 88.dp),
                // 作者: long
                // 下载列表按任务卡连续排列，避免卡片间的外边距打断状态色和进度背景的连续阅读。
                verticalArrangement = Arrangement.spacedBy(0.dp),
            ) {
                items(visibleTasks, key = { it.id }) { task -> TaskRow(task, model) }
            }
        }
    }
    if (confirmClearFinished) {
        AlertDialog(
            onDismissRequest = { confirmClearFinished = false },
            title = { Text(tr(Str.ClearFinishedTitle), fontSize = 16.sp) },
            text = { Text(tr(Str.ClearFinishedMessage, finishedCount), fontSize = 13.sp) },
            confirmButton = {
                TextButton(onClick = { confirmClearFinished = false; model.clearFinishedTasks() }) { Text(tr(Str.ClearAction)) }
            },
            dismissButton = { TextButton(onClick = { confirmClearFinished = false }) { Text(tr(Str.Cancel)) } },
        )
    }
}

@Composable
internal fun QueueFilterStrip(
    selected: AndroidQueueFilter,
    counts: Map<AndroidQueueFilter, Int>,
    onSelected: (AndroidQueueFilter) -> Unit,
) {
    val labels = mapOf(
        AndroidQueueFilter.All to tr(Str.FilterAll),
        AndroidQueueFilter.Unfinished to tr(Str.FilterUnfinished),
        AndroidQueueFilter.Ended to tr(Str.FilterEnded),
        AndroidQueueFilter.Failed to tr(Str.FilterFailed),
    )
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp)
            .height(34.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(FluxPalette.surfaceTint)
            .padding(2.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        AndroidQueueFilter.values().forEach { filter ->
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxSize()
                    .clip(RoundedCornerShape(6.dp))
                    .background(if (filter == selected) FluxPalette.accent else Color.Transparent)
                    .clickable { onSelected(filter) },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    "${labels.getValue(filter)}(${counts[filter] ?: 0})",
                    color = if (filter == selected) Color.White else FluxPalette.textPrimary,
                    fontSize = 10.5.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
internal fun EmptyQueue() {
    Column(
        modifier = Modifier.fillMaxSize().padding(start = 16.dp, end = 16.dp, bottom = 88.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(containerColor = FluxPalette.surfaceCard),
            shape = RoundedCornerShape(8.dp),
            border = BorderStroke(1.dp, FluxPalette.borderAccent),
        ) {
            Column(
                Modifier.fillMaxWidth().padding(vertical = 30.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Box(Modifier.size(42.dp).clip(RoundedCornerShape(8.dp)).background(FluxPalette.surfaceTint), contentAlignment = Alignment.Center) {
                    Icon(Icons.Default.Download, contentDescription = null, tint = FluxPalette.accent, modifier = Modifier.size(22.dp))
                }
                Spacer(Modifier.height(10.dp))
                Text(tr(Str.EmptyQueueTitle), color = FluxPalette.textPrimary, fontSize = 14.sp)
                Text(tr(Str.EmptyQueueHint), color = FluxPalette.textSecondary, fontSize = 11.sp)
            }
        }
    }
}
