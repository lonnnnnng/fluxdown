package dev.fluxdown.android.viewmodel

import dev.fluxdown.android.data.HlsVariantOption
import dev.fluxdown.android.data.KotlinSettings
import dev.fluxdown.android.data.QueueTask
import dev.fluxdown.android.data.TorrentSelection
import dev.fluxdown.android.platform.AndroidStorageStats
import dev.fluxdown.android.platform.AndroidUpdateReport
import dev.fluxdown.android.ui.i18n.Str
import dev.fluxdown.android.ui.i18n.trApp

/** 底部导航只有任务和设置两页；协议矩阵由任务卡片自身展示。 */
internal enum class HomeTab { Tasks, Settings }

/**
 * 作者: long
 * 单一 UI 状态快照。所有字段都由 NativeViewModel 统一更新，Composable 只读不写，
 * 避免多个页面各自持有状态导致队列快照与弹窗状态不同步。
 */
internal data class NativeUiState(
    val tasks: List<QueueTask> = emptyList(),
    val settings: KotlinSettings = KotlinSettings(),
    val selectedTab: HomeTab = HomeTab.Tasks,
    val isLoading: Boolean = false,
    val notice: String? = null,
    val rustVersion: String = trApp(Str.NotLoaded),
    val rustAbi: String = "-",
    val torrentSelection: TorrentSelection? = null,
    val torrentMetadataLoading: Boolean = false,
    val torrentMetadataError: String? = null,
    val newTaskSubmitting: Boolean = false,
    val newTaskError: String? = null,
    val isConfirmingTorrent: Boolean = false,
    val torrentDetail: TorrentSelection? = null,
    val torrentDetailTask: QueueTask? = null,
    val actionTask: QueueTask? = null,
    val propertiesTask: QueueTask? = null,
    val notificationPermissionRequest: Boolean = false,
    val credentialReferences: List<String> = emptyList(),
    val storageStats: AndroidStorageStats? = null,
    val storageLoading: Boolean = false,
    val storageUnavailable: Boolean = false,
    val updateChecking: Boolean = false,
    val updateReport: AndroidUpdateReport? = null,
    val hlsVariants: List<HlsVariantOption> = emptyList(),
    val hlsVariantsSource: String? = null,
    val hlsVariantsLoading: Boolean = false,
    val hlsVariantsError: String? = null,
    /** S5 启动时识别到的剪贴板下载源；非 null 时任务页顶部展示提示条。 */
    val clipboardSuggestion: String? = null,
    /** S1：已按「仅在 Wi-Fi 下下载」暂停，等待 Wi-Fi 恢复后自动继续。 */
    val networkPaused: Boolean = false,
)
