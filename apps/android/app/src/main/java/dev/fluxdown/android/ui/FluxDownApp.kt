package dev.fluxdown.android.ui
import dev.fluxdown.android.*
import dev.fluxdown.android.ui.*
import dev.fluxdown.android.ui.queue.*
import dev.fluxdown.android.ui.settings.*
import dev.fluxdown.android.ui.newtask.*

import android.Manifest
import android.os.Build
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.outlined.Download as DownloadOutlined
import androidx.compose.material.icons.outlined.Settings as SettingsOutlined
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.fluxdown.android.data.*
import dev.fluxdown.android.ui.collectAsStateCompat
import dev.fluxdown.android.viewmodel.HomeTab
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import dev.fluxdown.android.viewmodel.*
import dev.fluxdown.android.ui.i18n.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun FluxDownApp(model: NativeViewModel) {
    val state by model.state.collectAsStateCompat()
    val context = LocalContext.current
    var showNewTask by rememberSaveable { mutableStateOf(false) }
    var showExitConfirm by rememberSaveable { mutableStateOf(false) }
    // S5：从剪贴板提示条进入新建任务时，把链接带进弹框。
    var pendingClipboardSource by rememberSaveable { mutableStateOf<String?>(null) }
    // 作者: long
    // 一级页面返回只退出当前 Activity；Rust 队列和前台服务继续负责已入队任务，避免用户误触返回键时中断下载。
    BackHandler {
        showExitConfirm = true
    }
    val notificationPermissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        model.clearNotificationPermissionRequest()
        // 作者: long
        // Android 首次授权通知后，之前被系统暂缓的前台服务不会自动重试；刷新会重新检查队列并唤起 runner。
        model.refresh()
    }
    val outputDirectoryLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        uri?.let(model::selectOutputDirectory)
    }
    val knownHostsLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let(model::importSftpKnownHosts)
    }

    androidx.compose.runtime.LaunchedEffect(state.notificationPermissionRequest) {
        if (state.notificationPermissionRequest && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    androidx.compose.runtime.LaunchedEffect(state.selectedTab) {
        // 作者: long
        // Rust 下载在前台服务中执行，Activity 不应持有执行协程；这里只轮询持久化快照，
        // 让任务卡片在切回前台后持续显示真实进度、速度和完成时间。
        while (isActive) {
            if (state.selectedTab == HomeTab.Tasks) model.refreshSnapshot()
            delay(1_000)
        }
    }

    Scaffold(
        bottomBar = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(FluxPalette.surfaceCard)
                    .navigationBarsPadding(),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().height(54.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    BottomNavItem(
                        selected = state.selectedTab == HomeTab.Tasks,
                        icon = if (state.selectedTab == HomeTab.Tasks) Icons.Default.Download else Icons.Outlined.DownloadOutlined,
                        label = tr(Str.TabTasks),
                        onClick = { model.selectTab(HomeTab.Tasks) },
                        modifier = Modifier.weight(1f),
                    )
                    BottomNavItem(
                        selected = state.selectedTab == HomeTab.Settings,
                        icon = if (state.selectedTab == HomeTab.Settings) Icons.Default.Settings else Icons.Outlined.SettingsOutlined,
                        label = tr(Str.TabSettings),
                        onClick = { model.selectTab(HomeTab.Settings) },
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        },
        floatingActionButton = {
            if (state.selectedTab == HomeTab.Tasks) {
                FloatingActionButton(
                    onClick = { model.clearNewTaskError(); showNewTask = true },
                    containerColor = MaterialTheme.colorScheme.primary,
                ) {
                    Icon(Icons.Default.Add, contentDescription = tr(Str.NewTask))
                }
            }
        },
        containerColor = FluxPalette.background,
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            state.clipboardSuggestion?.let { source ->
                ClipboardSuggestionBar(
                    source = source,
                    onCreate = {
                        pendingClipboardSource = model.consumeClipboardSuggestion()
                        model.clearNewTaskError()
                        showNewTask = true
                    },
                    onDismiss = model::dismissClipboardSuggestion,
                )
            }
            state.notice?.let { notice ->
                Text(
                    text = notice,
                    modifier = Modifier.fillMaxWidth().background(FluxPalette.surfaceTintAlt2).padding(horizontal = 16.dp, vertical = 8.dp),
                    color = FluxPalette.accentDarker,
                    fontSize = 12.sp,
                )
            }
            when (state.selectedTab) {
                HomeTab.Tasks -> QueueScreen(state, model)
                HomeTab.Settings -> SettingsScreen(
                    state,
                    model,
                    onChooseOutputDirectory = { outputDirectoryLauncher.launch(null) },
                    onChooseKnownHosts = { knownHostsLauncher.launch(arrayOf("text/*", "application/octet-stream")) },
                )
            }
        }
    }

    if (showNewTask) {
        NewTaskDialog(
            defaultOutputPath = state.settings.outputPath,
            initialSource = pendingClipboardSource,
            onDismiss = { model.clearNewTaskError(); showNewTask = false; pendingClipboardSource = null },
            credentialReferences = state.credentialReferences,
            hlsVariants = state.hlsVariants,
            hlsAudioRenditions = state.hlsAudioRenditions,
            hlsVariantsSource = state.hlsVariantsSource,
            hlsVariantsLoading = state.hlsVariantsLoading,
            hlsVariantsError = state.hlsVariantsError,
            onLoadHlsVariants = model::loadHlsVariants,
            torrentMetadataLoading = state.torrentMetadataLoading,
            torrentMetadataError = state.torrentMetadataError,
            newTaskSubmitting = state.newTaskSubmitting,
            newTaskError = state.newTaskError,
            onSourceChanged = model::clearNewTaskError,
            onConfirm = { source, fileName, outputPath, credentialRef, expectedSha256, hlsVariantIndex, hlsAudioIndex, hlsKeepTransportStream ->
                model.addTask(
                    source,
                    fileName,
                    outputPath,
                    credentialRef,
                    expectedSha256,
                    hlsVariantIndex,
                    hlsAudioIndex,
                    hlsKeepTransportStream,
                    onQueued = { model.clearNewTaskError(); showNewTask = false; pendingClipboardSource = null },
                )
            },
        )
    }

    state.updateReport?.let { report ->
        UpdateResultDialog(
            report = report,
            onDismiss = model::clearUpdateReport,
            onDownload = report.downloadUrl?.let { url -> { model.clearUpdateReport(); model.openExternalUrl(url) } },
            onOpenRelease = { model.clearUpdateReport(); model.openExternalUrl(report.releaseUrl) },
        )
    }

    state.torrentSelection?.let { selection ->
        TorrentSelectionDialog(
            selection = selection,
            isConfirming = state.isConfirmingTorrent,
            error = state.newTaskError,
            onDismiss = model::cancelTorrentSelection,
            onConfirm = { selected -> model.confirmTorrentSelection(selection, selected) },
        )
    }

    state.torrentDetail?.let { selection ->
        val task = state.torrentDetailTask
        TorrentDetailsDialog(
            selection = selection,
            onDismiss = model::closeTorrentDetails,
            onOpenFile = task?.takeIf { it.state == "finished" }?.let { current ->
                { file -> model.openTorrentFile(current, file) }
            },
            onShareFile = task?.takeIf { it.state == "finished" }?.let { current ->
                { file -> model.shareTorrentFile(current, file) }
            },
        )
    }

    state.actionTask?.let { task ->
        TaskActionsDialog(
            task = task,
            onDismiss = model::closeTaskActions,
            onPause = { model.closeTaskActions(); model.pause(task) },
            onResume = { model.closeTaskActions(); model.resume(task) },
            onRetry = { model.closeTaskActions(); model.retry(task) },
            onOpen = { model.openTask(task) },
            onShare = { model.shareTask(task) },
            onCopySource = { model.copySource(task) },
            onDetails = {
                model.closeTaskActions()
                if (task.isTorrentResource) model.showTorrentDetails(task)
            },
            onProperties = {
                model.closeTaskActions()
                model.showTaskProperties(task)
            },
            onRemove = { model.closeTaskActions(); model.remove(task) },
        )
    }

    state.propertiesTask?.let { task ->
        TaskPropertiesDialog(task = task, onDismiss = model::closeTaskProperties)
    }

    if (showExitConfirm) {
        AlertDialog(
            onDismissRequest = { showExitConfirm = false },
            title = { Text(tr(Str.QuitFluxDown), fontSize = 16.sp) },
            text = { Text(tr(Str.QuitMessage), fontSize = 13.sp) },
            confirmButton = {
                TextButton(
                    onClick = {
                        showExitConfirm = false
                        (context as? ComponentActivity)?.finish()
                    },
                ) { Text(tr(Str.Quit)) }
            },
            dismissButton = {
                TextButton(onClick = { showExitConfirm = false }) { Text(tr(Str.Cancel)) }
            },
        )
    }
}

/**
 * 作者: long
 * S5 剪贴板提示条。用内联横条而不是弹框：用户可能在刚启动就想手动新建任务，
 * 弹框会抢焦点；横条只占一行，点“新建”才把链接带进新建弹框。
 */
@Composable
internal fun ClipboardSuggestionBar(
    source: String,
    onCreate: () -> Unit,
    onDismiss: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(FluxPalette.successSurface)
            .padding(start = 16.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.Default.ContentPaste,
            contentDescription = null,
            tint = FluxPalette.successAlt,
            modifier = Modifier.size(15.dp),
        )
        Spacer(Modifier.width(6.dp))
        Column(Modifier.weight(1f)) {
            Text(tr(Str.ClipboardDetected), color = FluxPalette.successAlt, fontSize = 11.sp, maxLines = 1)
            Text(
                source,
                color = FluxPalette.successText,
                fontSize = 10.5.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        TextButton(onClick = onCreate) { Text(tr(Str.Create), fontSize = 12.sp) }
        TextButton(onClick = onDismiss) { Text(tr(Str.Ignore), fontSize = 12.sp, color = FluxPalette.successTextAlt) }
    }
}

@Composable
internal fun BottomNavItem(
    selected: Boolean,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val contentColor = if (selected) FluxPalette.accent else Color.Black
    Box(
        modifier = modifier
            .height(54.dp)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .width(64.dp)
                .height(54.dp),
            contentAlignment = Alignment.Center,
        ) {
            // 作者: long
            // TabBar 的文字和图标必须完整落在系统导航栏上方；扩大安全容器后再整体下移，避免文字底部被父布局裁掉。
            Column(
                modifier = Modifier.offset(y = 10.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Icon(icon, contentDescription = label, tint = contentColor, modifier = Modifier.size(18.dp))
                Text(
                    label,
                    color = contentColor,
                    fontSize = 10.5.sp,
                    lineHeight = 10.5.sp,
                    fontWeight = FontWeight.Normal,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}
