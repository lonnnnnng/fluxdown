package dev.fluxdown.android.viewmodel

import dev.fluxdown.android.data.QueueRepository
import dev.fluxdown.android.data.ProtocolDetector
import dev.fluxdown.android.data.TorrentSelection
import dev.fluxdown.android.data.downloadSourceIssue
import dev.fluxdown.android.data.parseDataString
import dev.fluxdown.android.data.parseError
import dev.fluxdown.android.data.supportsCredentialProtocol
import dev.fluxdown.android.platform.AndroidCredentialVault
import dev.fluxdown.android.platform.SafCopyCoordinator
import dev.fluxdown.android.platform.TaskFileDispatcher
import dev.fluxdown.android.platform.TorrentMetadataClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import dev.fluxdown.android.ui.i18n.Str
import dev.fluxdown.android.ui.i18n.trApp

/**
 * 作者: long
 * 新建任务的编排：协议识别 → 凭据校验 → Torrent metadata → 写入 Rust 队列 → 触发调度。
 * 抽出来是因为这段逻辑同时涉及队列、凭据、SAF 和 ed2k 移交，放在 ViewModel 里会淹没状态管理。
 */
internal class NewTaskController(
    private val queue: QueueRepository,
    private val credentialVault: AndroidCredentialVault,
    private val dispatcher: TaskFileDispatcher,
    private val safCopies: SafCopyCoordinator,
    private val torrentMetadata: TorrentMetadataClient,
    private val defaultOutputPath: String,
    private val updateState: ((NativeUiState) -> NativeUiState) -> Unit,
    private val onQueueChanged: suspend (startQueue: Boolean) -> Unit,
) {
    private suspend fun publish(transform: (NativeUiState) -> NativeUiState) {
        withContext(Dispatchers.Main) { updateState(transform) }
    }

    private suspend fun showError(message: String) {
        // 作者: long
        // 新建任务的错误已经在当前弹框内展示，页面顶部不再重复追加一条系统提示，避免遮挡任务列表。
        publish { it.copy(newTaskError = message, notice = null) }
    }

    suspend fun submit(
        source: String,
        fileName: String,
        outputPath: String,
        credentialRef: String?,
        expectedSha256: String,
        hlsVariantIndex: Int?,
        hlsAudioIndex: Int?,
        hlsKeepTransportStream: Boolean,
        onQueued: (() -> Unit)?,
    ) {
        try {
            val normalizedSource = source.trim()
            val protocol = ProtocolDetector.detect(normalizedSource)
            val sourceError = downloadSourceIssue(normalizedSource, protocol)
            if (sourceError != null) {
                showError(sourceError)
                return
            }
            val normalizedCredential = credentialRef?.trim()?.takeIf { it.isNotEmpty() }
            if (normalizedCredential != null && !supportsCredentialProtocol(protocol)) {
                showError(trApp(Str.ProtocolNoCredential))
                return
            }
            if (normalizedCredential != null) {
                val credential = credentialVault.get(normalizedCredential)
                if (credential == null) {
                    showError(trApp(Str.CredentialUnavailable))
                    return
                }
                if (credential.usesPrivateKey && protocol != "sftp") {
                    showError(trApp(Str.SftpKeyOnlyForSftp))
                    return
                }
            }
            if (protocol == "torrent" || protocol == "magnet") {
                torrentMetadata.inspect(
                    normalizedSource,
                    fileName.trim(),
                    outputPath.ifBlank { defaultOutputPath },
                    onQueued,
                )
                return
            }
            // 作者: long
            // ed2k 由外部客户端接管；先确认系统有接收者，再写队列，避免无接管应用时闪现空任务。
            if (protocol == "ed2k" && !dispatcher.canHandoffEd2k(normalizedSource)) {
                showError(trApp(Str.NoEd2kApp))
                return
            }
            val selectedOutput = outputPath.ifBlank { defaultOutputPath }
            val taskId = safCopies.newTaskId(selectedOutput)
            val request = JSONObject()
                .put("source", normalizedSource)
                .put("outputDir", rustOutputPath(selectedOutput, taskId))
            taskId?.let { request.put("taskId", it) }
            if (fileName.isNotBlank()) request.put("fileName", fileName.trim())
            if (expectedSha256.isNotBlank()) request.put("expectedSha256", expectedSha256.trim())
            normalizedCredential?.let { request.put("credentialRef", it) }
            hlsVariantIndex?.let { request.put("hlsVariantIndex", it) }
            hlsAudioIndex?.let { request.put("hlsAudioIndex", it) }
            if (hlsKeepTransportStream) request.put("hlsKeepTransportStream", true)
            val outcome = enqueue(
                request,
                selectedOutput.takeIf { safCopies.isTreeUri(it) },
                startQueue = protocol != "ed2k",
            )
            if (outcome.error != null) {
                return
            }
            val taskIdFromQueue = outcome.taskId
            if (protocol == "ed2k" && taskIdFromQueue != null) {
                if (handoffEd2k(normalizedSource, taskIdFromQueue)) {
                    withContext(Dispatchers.Main) { onQueued?.invoke() }
                }
            } else if (protocol != "ed2k") {
                withContext(Dispatchers.Main) { onQueued?.invoke() }
            } else {
                showError(trApp(Str.Ed2kNoTaskId))
            }
        } catch (error: Throwable) {
            if (error is kotlinx.coroutines.CancellationException) throw error
            showError(error.message ?: trApp(Str.TaskCreateFailed))
        } finally {
            publish { it.copy(newTaskSubmitting = false) }
        }
    }

    /** 用户在 Torrent 文件选择弹框里确认后，才真正写入队列。 */
    suspend fun confirmTorrent(selection: TorrentSelection, selectedIndexes: Set<Int>) {
        if (selectedIndexes.isEmpty()) {
            publish { it.copy(isConfirmingTorrent = false, newTaskError = trApp(Str.SelectOneFile), notice = null) }
            return
        }
        val files = JSONArray()
        selection.files.forEach { file ->
            files.put(
                JSONObject()
                    .put("index", file.index)
                    .put("path", file.path)
                    .put("name", file.name)
                    .put("size", file.size)
                    .put("isStreamable", file.isStreamable),
            )
        }
        val taskId = safCopies.newTaskId(selection.outputPath)
        val request = JSONObject()
            .put("source", selection.source)
            .put("outputDir", rustOutputPath(selection.outputPath, taskId))
            .put("fileName", selection.requestedFileName.ifBlank { selection.directoryName })
            .put("torrentName", selection.directoryName)
            .put("torrentFileIndices", JSONArray(selectedIndexes.toList().sorted()))
            .put("torrentFiles", files)
        taskId?.let { request.put("taskId", it) }
        val result = queue.add(request)
        val newTaskId = parseDataString(result, "id")
        var message = parseError(result)
        if (message == null && taskId != null) {
            safCopies.rememberTarget(taskId, selection.outputPath)
        }
        if (message == null && selection.replaceTaskId != null) {
            // 作者: long
            // 重试必须先确保新任务已经落盘，再替换旧失败任务；这样 metadata 获取失败、用户取消选择
            // 或新任务入队失败时，旧任务仍可继续查看和再次重试，不会出现“任务凭空消失”。
            val removeMessage = parseError(queue.remove(selection.replaceTaskId))
            if (removeMessage != null) {
                (newTaskId ?: taskId)?.let { createdTaskId ->
                    queue.remove(createdTaskId)
                    safCopies.forget(createdTaskId)
                }
                message = trApp(Str.ReplaceTaskFailed, removeMessage)
            } else {
                safCopies.forget(selection.replaceTaskId)
            }
        }
        withContext(Dispatchers.Main) {
            updateState {
                it.copy(
                    torrentSelection = if (message == null) null else selection,
                    isConfirmingTorrent = false,
                    newTaskError = message,
                    notice = null,
                )
            }
            if (message == null) selection.onConfirmed?.invoke()
        }
        // 作者: long
        // 替换失败时新任务可能已被回滚，立即刷新列表让 UI 与持久化队列一致，避免用户看到残留重复项。
        onQueueChanged(message == null)
    }

    /**
     * SAF 目录不能作为 POSIX 路径交给 Rust；先为任务建立私有暂存目录，完成后再复制到用户目录。
     * 作者: long
     */
    private data class EnqueueOutcome(val taskId: String?, val error: String?)

    private suspend fun enqueue(request: JSONObject, safTarget: String?, startQueue: Boolean = true): EnqueueOutcome {
        val result = queue.add(request)
        val message = parseError(result)
        val taskId = parseDataString(result, "id")
        if (message == null && safTarget != null) {
            parseDataString(result, "id")?.let { safCopies.rememberTarget(it, safTarget) }
        }
        publish { it.copy(notice = null, newTaskError = message) }
        if (message == null) {
            onQueueChanged(startQueue && taskId != null)
        }
        return EnqueueOutcome(taskId, message)
    }

    private suspend fun handoffEd2k(source: String, taskId: String): Boolean {
        val result = runCatching { dispatcher.handoffEd2k(source) }
            .onSuccess {
                queue.markHandedOff(taskId)
                publish { it.copy(notice = null) }
            }
            .onFailure {
                queue.remove(taskId)
                showError(trApp(Str.Ed2kHandoffFailed, it.message ?: trApp(Str.UnknownError)))
            }
        onQueueChanged(false)
        return result.isSuccess
    }

    private fun rustOutputPath(outputPath: String, taskId: String?): String =
        if (taskId == null) outputPath else safCopies.stagingPath(taskId)
}
