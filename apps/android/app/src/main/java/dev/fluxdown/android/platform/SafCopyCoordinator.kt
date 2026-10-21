package dev.fluxdown.android.platform

import dev.fluxdown.android.data.QueueTask
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap
import dev.fluxdown.android.ui.i18n.Str
import dev.fluxdown.android.ui.i18n.trApp

/**
 * 作者: long
 * 队列状态仍由 Rust 决定；这里仅在完成态触发一次 SAF 文件复制，
 * 不把"已下载到私有目录"冒充"已保存到用户目录"。
 */
internal class SafCopyCoordinator(
    private val settingsStore: AndroidSettingsStore,
    private val safStorage: SafStorage,
) {
    private val inFlight = ConcurrentHashMap.newKeySet<String>()

    fun isTreeUri(path: String): Boolean = safStorage.isTreeUri(path)

    fun newTaskId(outputPath: String): String? = safStorage.newTaskId(outputPath)

    fun stagingPath(taskId: String): String = safStorage.stagingPath(taskId)

    fun rememberTarget(taskId: String, target: String) = settingsStore.rememberSafTarget(taskId, target)

    fun markPending(taskId: String) = settingsStore.markSafPending(taskId)

    fun forget(taskId: String) {
        settingsStore.forgetSafTarget(taskId)
        safStorage.forget(taskId)
    }

    /**
     * 异步复制已完成任务；同一任务不会重复复制，复制结果通过 [onNotice] 回传给调用方展示。
     */
    fun schedule(scope: CoroutineScope, tasks: List<QueueTask>, onNotice: (String) -> Unit) {
        tasks.filter { it.state == "finished" }.forEach { task ->
            val target = settingsStore.safTarget(task.id) ?: return@forEach
            if (settingsStore.isSafCopied(task.id)) return@forEach
            if (!inFlight.add(task.id)) return@forEach
            scope.launch(Dispatchers.IO) {
                val result = runCatching { safStorage.copy(task, target) }
                inFlight.remove(task.id)
                if (result.isSuccess) {
                    settingsStore.markSafCopied(task.id, result.getOrThrow())
                    onNotice(trApp(Str.SavedToSystemDir))
                } else {
                    onNotice(trApp(Str.SaveToSystemDirFailed, result.exceptionOrNull()?.message ?: trApp(Str.CopyErrorUnknown)))
                }
            }
        }
    }
}
