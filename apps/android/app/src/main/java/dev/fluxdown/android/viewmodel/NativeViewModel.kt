package dev.fluxdown.android.viewmodel

import android.content.Context
import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import dev.fluxdown.android.DownloadForegroundService
import dev.fluxdown.android.data.*
import dev.fluxdown.android.platform.AndroidCredentialVault
import dev.fluxdown.android.platform.AndroidSettingsStore
import dev.fluxdown.android.platform.AndroidUpdateChecker
import dev.fluxdown.android.platform.HlsRemuxCoordinator
import dev.fluxdown.android.platform.NetworkStatus
import dev.fluxdown.android.platform.SafCopyCoordinator
import dev.fluxdown.android.platform.TaskFileDispatcher
import dev.fluxdown.android.platform.TorrentMetadataClient
import dev.fluxdown.android.platform.QueueServiceController
import dev.fluxdown.android.platform.SafStorage
import dev.fluxdown.android.platform.SftpKnownHostsStore
import dev.fluxdown.android.platform.StoredAndroidCredential
import dev.fluxdown.android.platform.TaskFileResolver
import dev.fluxdown.android.viewmodel.HomeTab
import dev.fluxdown.android.viewmodel.NativeUiState
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import dev.fluxdown.android.ui.i18n.Str
import dev.fluxdown.android.ui.i18n.trApp

/**
 * 作者: long
 * Android 端凭据只保存引用名到普通偏好，用户名、密码和私钥使用 Keystore 中的 AES 密钥加密。
 * 这样任务 JSON、日志和 Rust 队列快照都不会携带认证材料；运行队列时才短暂解密到内存。
 */

internal class NativeViewModel(private val context: Context) : ViewModel() {
    private val settingsStore = AndroidSettingsStore(context)
    private val credentialVault = AndroidCredentialVault(context)
    private val storePath = File(context.filesDir, "fluxdown/rust-queue.json").absolutePath
    // 作者: long
    // Android 预览阶段先落到应用私有目录，避免 Rust 核心在未接入 SAF 授权时误写受保护的共享目录。
    // 接入系统目录选择器后，用户选择的持久化目录才会覆盖这个安全默认值。
    private val defaultOutputPath = File(context.filesDir, "Downloads").apply { mkdirs() }.absolutePath
    private val safStagingRoot = File(context.filesDir, "fluxdown/saf-staging").apply { mkdirs() }
    private val safStorage = SafStorage(context, safStagingRoot)
    private val fileResolver = TaskFileResolver(context, settingsStore)
    private val serviceController = QueueServiceController(context, storePath)
    private val queue = QueueRepository(storePath)
    private val torrentMetadata = TorrentMetadataClient(queue) { transform ->
        _state.value = transform(_state.value)
    }
    private val knownHostsRoot = File(context.filesDir, "fluxdown/security").apply { mkdirs() }
    private val knownHostsStore = SftpKnownHostsStore(context, knownHostsRoot)
    private val dispatcher = TaskFileDispatcher(context, fileResolver)
    // 作者: long
    // 状态必须先于下面的协作类声明：它们构造时就要拿到同一个 MutableStateFlow。
    private val _state = MutableStateFlow(
        NativeUiState(
            settings = settingsStore.load(defaultOutputPath),
            credentialReferences = settingsStore.credentialReferences(),
        ),
    )
    val state: StateFlow<NativeUiState> = _state.asStateFlow()
    // 作者: long
    // 剪贴板提示、产物打开/分享、保存位置与 known_hosts 选取这三块都是平台交互，
    // 拆成协作类后 NativeViewModel 只保留队列状态机本身。
    private val clipboard = ClipboardController(context, settingsStore, _state)
    private val fileActions = TaskFileActions(context, dispatcher, _state, viewModelScope)
    private val outputLocation = OutputLocationController(
        safStorage = safStorage,
        settingsStore = settingsStore,
        knownHostsStore = knownHostsStore,
        state = _state,
        scope = viewModelScope,
        refreshStorageStats = { path -> refreshStorageStats(path) },
    )
    private val safCopies = SafCopyCoordinator(settingsStore, safStorage)
    private val hlsRemux = HlsRemuxCoordinator()
    private val refreshInFlight = AtomicBoolean(false)
    private var wifiWatcher: java.io.Closeable? = null
    private val settings = SettingsController(
        context = context,
        credentialVault = credentialVault,
        settingsStore = settingsStore,
        queue = queue,
        defaultOutputPath = defaultOutputPath,
        updateState = { transform -> _state.value = transform(_state.value) },
        stateProvider = { _state.value },
        scope = viewModelScope,
    )
    private val newTask = NewTaskController(
        queue = queue,
        credentialVault = credentialVault,
        dispatcher = dispatcher,
        safCopies = safCopies,
        torrentMetadata = torrentMetadata,
        defaultOutputPath = defaultOutputPath,
        updateState = { transform -> _state.value = transform(_state.value) },
        onQueueChanged = { startQueue ->
            refreshOnce()
            if (startQueue) ensureQueueRunning()
        },
    )

    init {
        refresh()
        refreshStorageStats()
        watchWifiForDownloads()
    }

    /**
     * 作者: long
     * S1 切回 Wi-Fi 后自动继续：监听默认网络，重新出现可用 Wi-Fi 时再走一次调度。
     * 只在开关打开时真正调度，否则什么都不做。
     */
    private fun watchWifiForDownloads() {
        wifiWatcher = NetworkStatus.registerWifiWatcher(context) {
            if (!_state.value.settings.wifiOnly) return@registerWifiWatcher
            viewModelScope.launch {
                _state.value = _state.value.copy(networkPaused = false)
                ensureQueueRunning()
            }
        }
    }

    override fun onCleared() {
        wifiWatcher?.close()
        wifiWatcher = null
        super.onCleared()
    }

    /**
     * 作者: long
     * S5 启动时识别剪贴板链接。只在开关打开、且与上次提示的链接不同时才抛出建议，
     * 避免 Android 13+ 的粘贴提示和 UI 提示条每次启动都重复出现。
     */
    fun detectClipboardSource() = clipboard.detect()

    /** 用户点“新建”：返回待填充的下载源，并记下已提示过，后续启动不再弹。 */
    fun consumeClipboardSuggestion(): String? = clipboard.consume()

    fun dismissClipboardSuggestion() = clipboard.dismiss()

    fun selectTab(tab: HomeTab) {
        _state.value = _state.value.copy(selectedTab = tab, notice = null)
    }

    /** S2：从设置页主动申请通知权限（Android 13+）。 */
    fun requestNotificationPermission() {
        _state.value = _state.value.copy(notificationPermissionRequest = true)
    }

    fun clearNotificationPermissionRequest() {
        _state.value = _state.value.copy(notificationPermissionRequest = false)
    }

    fun refresh() {
        scheduleRefresh(startRunner = true)
    }
    /**
     * 只刷新队列快照，不重复唤起前台服务；任务页用它展示运行中的真实进度和速度。
     * 作者: long
     */
    fun refreshSnapshot() {
        scheduleRefresh(startRunner = false)
    }

    private fun scheduleRefresh(startRunner: Boolean) {
        if (!refreshInFlight.compareAndSet(false, true)) return
        viewModelScope.launch(Dispatchers.IO) {
            try {
                refreshOnce()
                if (startRunner) ensureQueueRunning()
            } finally {
                refreshInFlight.set(false)
            }
        }
    }

    fun addTask(
        source: String,
        fileName: String,
        outputPath: String,
        credentialRef: String?,
        expectedSha256: String,
        hlsVariantIndex: Int?,
        hlsAudioIndex: Int?,
        hlsKeepTransportStream: Boolean,
        onQueued: (() -> Unit)? = null,
    ) {
        if (_state.value.newTaskSubmitting || _state.value.torrentMetadataLoading) return
        _state.value = _state.value.copy(newTaskSubmitting = true, newTaskError = null, torrentMetadataError = null)
        viewModelScope.launch(Dispatchers.IO) {
            newTask.submit(
                source = source,
                fileName = fileName,
                outputPath = outputPath,
                credentialRef = credentialRef,
                expectedSha256 = expectedSha256,
                hlsVariantIndex = hlsVariantIndex,
                hlsAudioIndex = hlsAudioIndex,
                hlsKeepTransportStream = hlsKeepTransportStream,
                onQueued = onQueued,
            )
        }
    }

    fun clearNewTaskError() {
        _state.value = _state.value.copy(newTaskError = null, torrentMetadataError = null)
    }

    private suspend fun showNewTaskError(message: String) {
        withContext(Dispatchers.Main) {
            // 作者: long
            // 新建任务的错误已经在当前弹框内展示，页面顶部不再重复追加一条系统提示，避免遮挡任务列表。
            _state.value = _state.value.copy(newTaskError = message, notice = null)
        }
    }

    /**
     * SAF 目录不能作为 POSIX 路径交给 Rust；先为任务建立私有暂存目录，完成后再复制到用户目录。
     * 作者: long
     */
    private suspend fun enqueue(request: JSONObject, safTarget: String?, startQueue: Boolean = true): String? {
        val result = queue.add(request)
        val message = parseError(result)
        val taskId = parseDataString(result, "id")
        if (message == null && safTarget != null) {
            parseDataString(result, "id")?.let { rememberSafTarget(it, safTarget) }
        }
        withContext(Dispatchers.Main) {
            _state.value = _state.value.copy(
                notice = null,
                newTaskError = message,
            )
        }
        if (message == null) {
            refreshOnce()
            if (startQueue && taskId != null) ensureQueueRunning()
        }
        return taskId
    }

    private suspend fun handoffEd2k(source: String, taskId: String): Boolean {
        val result = runCatching { context.startActivity(dispatcher.ed2kIntent(source)) }
            .onSuccess {
                queue.markHandedOff(taskId)
                withContext(Dispatchers.Main) {
                    _state.value = _state.value.copy(notice = null)
                }
            }
            .onFailure {
                queue.remove(taskId)
                showNewTaskError(trApp(Str.Ed2kHandoffFailed, it.message ?: trApp(Str.UnknownError)))
            }
        refreshOnce()
        return result.isSuccess
    }

    /**
     * Torrent/Magnet 先解析 metadata，不写入队列；只有用户确认文件选择后才创建任务。
     * 作者: long
     */
    private suspend fun inspectTorrent(
        source: String,
        fileName: String,
        outputPath: String,
        onQueued: (() -> Unit)?,
        replaceTaskId: String? = null,
    ) {
        torrentMetadata.inspect(source, fileName, outputPath, onQueued, replaceTaskId)
    }

    fun showTorrentDetails(task: QueueTask) {
        val outputPath = _state.value.settings.outputPath.ifBlank { defaultOutputPath }
        if (task.state != "running") {
            // 作者: long
            // 非运行任务没有活动 session；直接读取持久化的确认结果，避免 Magnet 详情触发第二次网络等待。
            _state.value = _state.value.copy(
                torrentDetail = savedTorrentSelection(task, outputPath),
                torrentDetailTask = task,
                notice = null,
            )
            return
        }
        viewModelScope.launch(Dispatchers.IO) { torrentMetadata.loadRunningDetails(task, outputPath) }
    }

    fun closeTorrentDetails() {
        _state.value = _state.value.copy(torrentDetail = null, torrentDetailTask = null)
    }

    fun confirmTorrentSelection(selection: TorrentSelection, selectedIndexes: Set<Int>) {
        if (_state.value.isConfirmingTorrent) return
        _state.value = _state.value.copy(isConfirmingTorrent = true)
        viewModelScope.launch(Dispatchers.IO) { newTask.confirmTorrent(selection, selectedIndexes) }
    }

    fun cancelTorrentSelection() {
        if (_state.value.isConfirmingTorrent) return
        _state.value = _state.value.copy(torrentSelection = null, newTaskError = null, notice = null)
    }

    fun remove(task: QueueTask) {
        mutateTask(task, { queue.remove(task.id) }) {
            forgetSafTarget(task.id)
        }
    }

    /**
     * 作者: long
     * S6 一键清理已完成任务：只删 finished / handed-off，不碰运行中、暂停、排队和失败任务，
     * 避免用户误以为“清理”会丢掉仍需重试的失败记录。
     */
    fun clearFinishedTasks() {
        val finished = _state.value.tasks.filter { it.state == "finished" || it.state == "handed-off" }
        if (finished.isEmpty()) {
            _state.value = _state.value.copy(notice = trApp(Str.NothingToClearNotice))
            return
        }
        viewModelScope.launch(Dispatchers.IO) {
            var removed = 0
            var failure: String? = null
            for (task in finished) {
                val message = parseError(queue.remove(task.id))
                if (message == null) {
                    removed++
                    forgetSafTarget(task.id)
                } else {
                    failure = message
                }
            }
            withContext(Dispatchers.Main) {
                _state.value = _state.value.copy(
                    notice = failure ?: trApp(Str.ClearedTasksNotice, removed),
                )
            }
            refreshSnapshot()
        }
    }

    /** S6 筛选条件持久化；只改设置快照，不重跑整份设置校验。 */
    fun setQueueFilter(filter: String) {
        if (filter !in KotlinSettings.FILTERS) return
        if (_state.value.settings.queueFilter == filter) return
        settingsStore.updateQueueFilter(filter)
        _state.value = _state.value.copy(settings = _state.value.settings.copy(queueFilter = filter))
    }

    fun pause(task: QueueTask) {
        mutateTask(task, { queue.pause(task.id) })
    }

    fun resume(task: QueueTask) {
        mutateTask(task, { queue.resume(task.id) })
    }

    fun reset(task: QueueTask) {
        mutateTask(task, { queue.reset(task.id) }) {
            markSafPending(task.id)
        }
    }

    fun retry(task: QueueTask) {
        if (!task.isTorrentResource) {
            reset(task)
            return
        }
        // 作者: long
        // Torrent/Magnet 失败后重新解析 metadata，给用户重新确认文件集合的机会；
        // 直接 queueReset 会沿用过期会话，容易把失败任务再次卡在等待 Peer 状态。
        _state.value = _state.value.copy(actionTask = null, torrentMetadataError = null, newTaskError = null)
        viewModelScope.launch(Dispatchers.IO) {
            val retryOutputPath = torrentRetryOutputPath(
                taskOutputPath = task.outputDir,
                persistedSafTarget = settingsStore.safTarget(task.id),
            )
            inspectTorrent(
                source = task.source,
                fileName = task.name,
                outputPath = retryOutputPath,
                onQueued = null,
                replaceTaskId = task.id,
            )
        }
    }

    fun showTaskActions(task: QueueTask) {
        _state.value = _state.value.copy(actionTask = task)
    }

    fun closeTaskActions() {
        _state.value = _state.value.copy(actionTask = null)
    }

    fun showTaskProperties(task: QueueTask) {
        _state.value = _state.value.copy(propertiesTask = task)
    }

    fun closeTaskProperties() {
        _state.value = _state.value.copy(propertiesTask = null)
    }

    fun copySource(task: QueueTask) = fileActions.copySource(task)

    fun openTask(task: QueueTask) = fileActions.open(task)

    fun shareTask(task: QueueTask) = fileActions.share(task)

    fun openTorrentFile(task: QueueTask, file: TorrentFileSelection) = fileActions.openFile(task, file)

    fun shareTorrentFile(task: QueueTask, file: TorrentFileSelection) = fileActions.shareFile(task, file)

    fun selectOutputDirectory(uri: Uri) = outputLocation.select(uri)

    fun importSftpKnownHosts(uri: Uri) = outputLocation.importKnownHosts(uri)

    fun clearSftpKnownHosts() = outputLocation.clearKnownHosts()

    fun saveCredential(reference: String, credential: StoredAndroidCredential) =
        settings.saveCredential(reference, credential)

    fun deleteCredential(reference: String) = settings.deleteCredential(reference)

    fun checkForUpdates() = settings.checkForUpdates()

    fun loadHlsVariants(source: String) = settings.loadHlsVariants(source)

    fun clearUpdateReport() {
        _state.value = _state.value.copy(updateReport = null)
    }

    fun openExternalUrl(url: String) {
        runCatching { AndroidUpdateChecker.openUrl(context, url) }
            .onFailure { _state.value = _state.value.copy(notice = trApp(Str.CannotOpenDownloadPage)) }
    }

    fun refreshStorageStats(path: String = _state.value.settings.outputPath) =
        settings.refreshStorageStats(path)

    fun saveSettings(settings: KotlinSettings, showNotice: Boolean = true) =
        this.settings.saveSettings(settings, showNotice)

    fun saveSettingsDraft(settings: KotlinSettings) = this.settings.saveSettingsDraft(settings)

    private fun mutateTask(task: QueueTask, mutation: () -> String, onSuccess: () -> Unit = {}) {
        viewModelScope.launch(Dispatchers.IO) {
            val result = mutation()
            val message = parseError(result)
            withContext(Dispatchers.Main) {
                _state.value = _state.value.copy(notice = message)
            }
            if (message == null) onSuccess()
            refreshOnce()
            // 作者: long
            // reset 会把已完成任务重新置为 queued，不能用变更前的 finished 状态阻止调度器启动；
            // 其他操作没有待运行任务时 ensureQueueRunning 会立即返回，不会重复创建运行句柄。
            if (message == null) ensureQueueRunning()
        }
    }

    /**
     * 从 Rust 队列读取一次真实状态。下载进度、速度和终态都以这个快照为准，UI 不维护假进度。
     * 作者: long
     */
    private suspend fun refreshOnce() {
        val result = queue.listRaw()
        val tasks = parseTasks(result)
        hlsRemux.process(tasks)
        scheduleSafCopies(tasks)
        val version = queue.version
        val abi = queue.abi
        val notice = parseError(result) ?: queue.loadError
        withContext(Dispatchers.Main) {
            _state.value = _state.value.copy(
                tasks = tasks,
                isLoading = false,
                notice = notice,
                rustVersion = version,
                rustAbi = abi,
            )
        }
    }

    /**
     * 只唤起前台服务，不在 Activity 生命周期中持有 Rust runner。
     * 作者: long
     * 这样 UI 进程重建、切到后台或被系统回收时，下载执行仍由可恢复的服务负责。
     */
    private suspend fun ensureQueueRunning() {
        if (!queue.hasRunnableTask()) {
            _state.value = _state.value.copy(networkPaused = false)
            return
        }
        // 作者: long
        // S1 仅在 Wi-Fi 下下载：非 Wi-Fi 时不启动 runner，改为在任务页顶部给出可解释的状态，
        // 任务本身保持 queued，回到 Wi-Fi 后由 watchWifiForDownloads 自动续跑。
        if (_state.value.settings.wifiOnly && !NetworkStatus.isWifiConnected(context)) {
            _state.value = _state.value.copy(networkPaused = true)
            return
        }
        _state.value = _state.value.copy(networkPaused = false)
        startForegroundMonitor(DownloadForegroundService.ACTION_START)
        // 作者: long
        // 前台服务接管是内部调度细节，不在任务页顶部追加提示；真实状态由任务卡片和通知栏展示。
    }

    private fun startForegroundMonitor(action: String) {
        if (serviceController.needsNotificationPermission()) {
            _state.value = _state.value.copy(notificationPermissionRequest = true)
        }
        serviceController.start(action)
    }

    private fun isTreeUri(path: String): Boolean = safCopies.isTreeUri(path)

    private fun taskIdForOutput(outputPath: String): String? = safCopies.newTaskId(outputPath)

    private fun rustOutputPath(outputPath: String, taskId: String?): String =
        if (taskId == null) outputPath else safCopies.stagingPath(taskId)

    private fun rememberSafTarget(taskId: String, target: String) = safCopies.rememberTarget(taskId, target)

    private fun markSafPending(taskId: String) = safCopies.markPending(taskId)

    private fun forgetSafTarget(taskId: String) = safCopies.forget(taskId)

    private fun scheduleSafCopies(tasks: List<QueueTask>) {
        safCopies.schedule(viewModelScope, tasks) { notice ->
            viewModelScope.launch(Dispatchers.Main) {
                _state.value = _state.value.copy(notice = notice)
            }
        }
    }

    companion object {
        fun factory(context: Context): ViewModelProvider.Factory =
            object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T =
                    NativeViewModel(context.applicationContext) as T
            }
    }
}
