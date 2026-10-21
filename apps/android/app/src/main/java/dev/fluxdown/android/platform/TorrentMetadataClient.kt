package dev.fluxdown.android.platform

import dev.fluxdown.android.data.QueueRepository
import dev.fluxdown.android.data.QueueTask
import dev.fluxdown.android.data.TorrentSelection
import dev.fluxdown.android.data.parseDataString
import dev.fluxdown.android.data.parseError
import dev.fluxdown.android.data.parseTorrentSelection
import dev.fluxdown.android.data.savedTorrentSelection
import dev.fluxdown.android.viewmodel.NativeUiState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import dev.fluxdown.android.ui.i18n.Str
import dev.fluxdown.android.ui.i18n.trApp

/**
 * 作者: long
 * Torrent/Magnet 的 metadata 会话编排。Rust 侧是异步 run，这里负责轮询到终态、
 * 解析成文件清单，并把结果交回 ViewModel 更新状态；UI 不直接接触 run 生命周期。
 */
internal class TorrentMetadataClient(
    private val queue: QueueRepository,
    private val updateState: ((NativeUiState) -> NativeUiState) -> Unit,
) {
    private suspend fun publish(transform: (NativeUiState) -> NativeUiState) {
        withContext(Dispatchers.Main) { updateState(transform) }
    }

    /**
     * 解析 metadata 但不写队列；只有用户确认文件选择后才创建任务。
     */
    suspend fun inspect(
        source: String,
        fileName: String,
        outputPath: String,
        onQueued: (() -> Unit)?,
        replaceTaskId: String? = null,
    ) {
        publish { it.copy(torrentMetadataLoading = true, torrentMetadataError = null, notice = null) }
        var metadataRunId: String? = null
        try {
            val start = queue.torrentDetailsAsync(source)
            val runId = parseDataString(start, "runId")
            if (runId == null) {
                val message = parseError(start) ?: trApp(Str.MetadataStartFailed)
                publish { it.copy(notice = null, newTaskError = message, torrentMetadataError = message) }
                return
            }
            metadataRunId = runId
            var detailsStatus = "running"
            var terminalStatus = start
            val deadlineNanos = System.nanoTime() + 90_000_000_000L
            while (detailsStatus == "running") {
                if (System.nanoTime() >= deadlineNanos) {
                    throw IllegalStateException(trApp(Str.MetadataTimeout))
                }
                delay(500)
                terminalStatus = queue.runStatus(runId)
                detailsStatus = parseDataString(terminalStatus, "state") ?: "failed"
            }
            if (detailsStatus != "finished") {
                val message = parseDataString(terminalStatus, "error") ?: trApp(Str.MetadataFailed)
                publish { it.copy(notice = null, newTaskError = message, torrentMetadataError = message) }
                return
            }
            val selection = parseTorrentSelection(
                terminalStatus,
                source,
                fileName,
                outputPath,
                onQueued,
                replaceTaskId,
            )
            if (selection == null || selection.files.isEmpty()) {
                val message = trApp(Str.MetadataNoFiles)
                publish { it.copy(notice = null, newTaskError = message, torrentMetadataError = message) }
                return
            }
            publish {
                it.copy(torrentSelection = selection, torrentMetadataError = null, newTaskError = null, notice = null)
            }
        } catch (error: Throwable) {
            if (error is kotlinx.coroutines.CancellationException) throw error
            val message = error.message?.trim().takeUnless { it.isNullOrEmpty() } ?: trApp(Str.MetadataFailed)
            publish { it.copy(notice = null, newTaskError = message, torrentMetadataError = message) }
        } finally {
            metadataRunId?.let { queue.forgetRun(it) }
            publish { it.copy(torrentMetadataLoading = false) }
        }
    }

    /**
     * 运行中的 Torrent 由 Rust 返回逐文件进度；暂停或完成后没有活动会话时，
     * 回退到入队时保存的 metadata，避免 Magnet 详情触发第二次网络等待。
     */
    suspend fun loadRunningDetails(task: QueueTask, outputPath: String) {
        val fallback = savedTorrentSelection(task, outputPath)
        fun show(selection: TorrentSelection) {
            updateState { it.copy(torrentDetail = selection, torrentDetailTask = task, notice = null) }
        }
        var detailsRunId: String? = null
        try {
            val start = queue.torrentDetailsAsync(task.source, task.id)
            val runId = parseDataString(start, "runId")
            if (runId == null) {
                withContext(Dispatchers.Main) { show(fallback) }
                return
            }
            detailsRunId = runId
            var detailsStatus = "running"
            var terminalStatus = start
            val deadlineNanos = System.nanoTime() + 30_000_000_000L
            while (detailsStatus == "running") {
                if (System.nanoTime() >= deadlineNanos) break
                delay(400)
                terminalStatus = queue.runStatus(runId)
                detailsStatus = parseDataString(terminalStatus, "state") ?: "failed"
            }
            val selection = if (detailsStatus == "finished") {
                parseTorrentSelection(terminalStatus, task.source, task.name, outputPath)
            } else {
                null
            }
            val selected = selection?.let { value ->
                if (task.torrentFileIndices.isEmpty()) value
                else value.copy(files = value.files.filter { it.index in task.torrentFileIndices })
            }
            withContext(Dispatchers.Main) { show(selected ?: fallback) }
        } catch (error: Throwable) {
            if (error is kotlinx.coroutines.CancellationException) throw error
            // 作者: long
            // 详情查询只影响展示，不应因为 metadata 会话异常让任务页或下载任务崩溃；
            // 回退到入队时保存的文件清单，用户仍可查看已确认内容和落盘进度。
            withContext(Dispatchers.Main) { show(fallback) }
        } finally {
            detailsRunId?.let { queue.forgetRun(it) }
        }
    }
}
