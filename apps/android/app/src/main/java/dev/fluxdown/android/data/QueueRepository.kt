package dev.fluxdown.android.data

import dev.fluxdown.android.core.RustCoreBridge
import org.json.JSONObject
import dev.fluxdown.android.ui.i18n.Str
import dev.fluxdown.android.ui.i18n.trApp

/**
 * 作者: long
 * Rust 队列的唯一访问层。ViewModel 只描述"要做什么"，具体 FFI 调用与 store 路径
 * 都收敛在这里，后续换 ABI 或改成本地实现时不需要动业务编排。
 */
internal class QueueRepository(private val storePath: String) {
    /** 原始 JSON 快照，保留给需要同时读取 error 字段的调用方。 */
    fun listRaw(): String = RustCoreBridge.queueList(storePath)

    /** 解析后的任务列表；进度、速度和终态都以 Rust 快照为准。 */
    fun snapshot(): List<QueueTask> = parseTasks(listRaw())

    fun add(request: JSONObject): String = RustCoreBridge.queueAdd(storePath, request.toString())

    fun remove(taskId: String): String = RustCoreBridge.queueRemove(storePath, taskId)

    fun pause(taskId: String): String = RustCoreBridge.queuePause(storePath, taskId)

    fun resume(taskId: String): String = RustCoreBridge.queueResume(storePath, taskId)

    fun reset(taskId: String): String = RustCoreBridge.queueReset(storePath, taskId)

    fun markHandedOff(taskId: String): String = RustCoreBridge.queueMarkHandedOff(storePath, taskId)

    /** 是否还有排队中或运行中的任务；没有时不应重复唤起前台服务。 */
    fun hasRunnableTask(): Boolean =
        snapshot().any { it.state == "queued" || it.state == "running" }

    fun torrentDetailsAsync(source: String, taskId: String = ""): String =
        RustCoreBridge.torrentDetailsAsync(source, taskId)

    fun runStatus(runId: String): String = RustCoreBridge.queueRunStatus(runId)

    fun forgetRun(runId: String) = RustCoreBridge.queueRunForget(runId)

    fun hlsVariants(source: String): String = RustCoreBridge.hlsVariants(source)

    val version: String get() = if (RustCoreBridge.isLoaded) RustCoreBridge.version() else trApp(Str.NotLoaded)

    val abi: String get() = if (RustCoreBridge.isLoaded) RustCoreBridge.abi() else "-"

    val loadError: String? get() = RustCoreBridge.loadError
}
