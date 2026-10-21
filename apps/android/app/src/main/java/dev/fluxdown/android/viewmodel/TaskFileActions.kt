package dev.fluxdown.android.viewmodel

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import dev.fluxdown.android.data.QueueTask
import dev.fluxdown.android.data.TorrentFileSelection
import dev.fluxdown.android.platform.TaskFileDispatcher
import dev.fluxdown.android.ui.i18n.Str
import dev.fluxdown.android.ui.i18n.trApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 作者: long
 * 任务产物的对外动作：复制链接、用其他应用打开、分享。
 *
 * 从 ViewModel 拆出来的原因：这里全是 Android 平台交互（ClipboardManager / Intent），
 * 属于 platform 语义；ViewModel 只保留“用户点了哪个动作”的状态流转。
 */
internal class TaskFileActions(
    private val context: Context,
    private val dispatcher: TaskFileDispatcher,
    private val state: MutableStateFlow<NativeUiState>,
    private val scope: CoroutineScope,
) {
    fun copySource(task: QueueTask) {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        clipboard?.setPrimaryClip(ClipData.newPlainText("FluxDown", task.source))
        state.value = state.value.copy(actionTask = null, notice = trApp(Str.LinkCopiedNotice))
    }

    fun open(task: QueueTask) = dispatch(task, Intent.ACTION_VIEW)

    fun share(task: QueueTask) = dispatch(task, Intent.ACTION_SEND)

    fun openFile(task: QueueTask, file: TorrentFileSelection) {
        if (isSelectedArtifact(task, file)) dispatch(task, Intent.ACTION_VIEW, file.path)
    }

    fun shareFile(task: QueueTask, file: TorrentFileSelection) {
        if (isSelectedArtifact(task, file)) dispatch(task, Intent.ACTION_SEND, file.path)
    }

    /** 只有“已完成 + 该文件确实在任务里 + 用户在 metadata 阶段选中过”才允许打开，避免给出不存在的路径。 */
    private fun isSelectedArtifact(task: QueueTask, file: TorrentFileSelection): Boolean =
        task.state == "finished" &&
            task.torrentFiles.any { it.index == file.index && it.path == file.path } &&
            (task.torrentFileIndices.isEmpty() || file.index in task.torrentFileIndices)

    /**
     * 完成任务的真实产物可能在应用私有目录，也可能已被复制到 SAF 目录；统一解析成可授权的 content URI，
     * 避免把私有路径直接交给其他应用，也避免 SAF 目录被误当作 POSIX 文件路径。
     */
    private fun dispatch(task: QueueTask, action: String, relativePath: String? = null) {
        scope.launch(Dispatchers.IO) {
            val notice = dispatcher.dispatch(task, action, relativePath)
            withContext(Dispatchers.Main) {
                state.value = if (notice == null) {
                    state.value.copy(actionTask = null)
                } else {
                    state.value.copy(actionTask = null, notice = notice)
                }
            }
        }
    }
}
