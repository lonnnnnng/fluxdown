package dev.fluxdown.android.core

/**
 * Kotlin 到 Rust ABI 1 的最薄桥接层。
 *
 * 作者: long
 * native 层返回统一 JSON 信封，Kotlin 不复制协议实现，只负责把 UI 请求交给现有
 * `fluxdown-ffi`，这样迁移期间 Flutter、桌面和 Kotlin 读取的是同一份任务数据。
 */
object RustCoreBridge {
    private var loadFailure: Throwable? = null

    val isLoaded: Boolean
        get() = loadFailure == null

    val loadError: String?
        get() = loadFailure?.message

    init {
        try {
            System.loadLibrary("fluxdown_android")
        } catch (error: Throwable) {
            loadFailure = error
        }
    }

    fun version(): String = callOrError { versionNative() }

    fun abi(): String = callOrError { abiNative() }

    fun detect(source: String): String = callOrError { detectNative(source) }

    fun hlsVariants(source: String): String = callOrError { hlsVariantsNative(source) }

    fun torrentDetailsAsync(source: String, taskId: String = ""): String =
        callOrError { torrentDetailsAsyncNative(source, taskId) }

    fun queueList(storePath: String): String = callOrError { queueListNative(storePath) }

    fun queueRecoverInterrupted(storePath: String): String =
        callOrError { queueRecoverInterruptedNative(storePath) }

    fun queueAdd(storePath: String, requestJson: String): String =
        callOrError { queueAddNative(storePath, requestJson) }

    fun queueRunQueued(storePath: String, optionsJson: String): String =
        callOrError { queueRunQueuedNative(storePath, optionsJson) }

    fun queueRunStatus(runId: String): String =
        callOrError { queueRunStatusNative(runId) }

    fun queueRunForget(runId: String): String =
        callOrError { queueRunForgetNative(runId) }

    fun queuePause(storePath: String, taskId: String): String =
        callOrError { queuePauseNative(storePath, taskId) }

    fun queueResume(storePath: String, taskId: String): String =
        callOrError { queueResumeNative(storePath, taskId) }

    fun queueReset(storePath: String, taskId: String): String =
        callOrError { queueResetNative(storePath, taskId) }

    fun queueMarkHandedOff(storePath: String, taskId: String): String =
        callOrError { queueMarkHandedOffNative(storePath, taskId) }

    fun queueRemove(storePath: String, taskId: String): String =
        callOrError { queueRemoveNative(storePath, taskId) }

    private fun callOrError(block: () -> String): String {
        val failure = loadFailure
        if (failure != null) {
            return errorEnvelope("Rust 核心未加载: ${failure.message ?: failure::class.simpleName}")
        }
        return try {
            block()
        } catch (error: Throwable) {
            errorEnvelope("调用 Rust 核心失败: ${error.message ?: error::class.simpleName}")
        }
    }

    private fun errorEnvelope(message: String): String =
        "{\"ok\":false,\"error\":${org.json.JSONObject.quote(message)}}"

    private external fun versionNative(): String
    private external fun abiNative(): String
    private external fun detectNative(source: String): String
    private external fun hlsVariantsNative(source: String): String
    private external fun torrentDetailsAsyncNative(source: String, taskId: String): String
    private external fun queueListNative(storePath: String): String
    private external fun queueRecoverInterruptedNative(storePath: String): String
    private external fun queueAddNative(storePath: String, requestJson: String): String
    private external fun queueRunQueuedNative(storePath: String, optionsJson: String): String
    private external fun queueRunStatusNative(runId: String): String
    private external fun queueRunForgetNative(runId: String): String
    private external fun queuePauseNative(storePath: String, taskId: String): String
    private external fun queueResumeNative(storePath: String, taskId: String): String
    private external fun queueResetNative(storePath: String, taskId: String): String
    private external fun queueMarkHandedOffNative(storePath: String, taskId: String): String
    private external fun queueRemoveNative(storePath: String, taskId: String): String
}
