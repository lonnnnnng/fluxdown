package dev.fluxdown.android.ui.settings
import dev.fluxdown.android.*
import dev.fluxdown.android.ui.*
import dev.fluxdown.android.ui.queue.*
import dev.fluxdown.android.ui.settings.*
import dev.fluxdown.android.ui.newtask.*

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SystemUpdateAlt
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import dev.fluxdown.android.platform.formatOutputLocation
import dev.fluxdown.android.viewmodel.NativeUiState
import dev.fluxdown.android.viewmodel.*
import dev.fluxdown.android.ui.i18n.*
import androidx.compose.material.icons.filled.Language

@Composable
internal fun SettingsScreen(
    state: NativeUiState,
    model: NativeViewModel,
    onChooseOutputDirectory: () -> Unit,
    onChooseKnownHosts: () -> Unit,
) {
    val context = LocalContext.current
    var settings by remember(state.settings) { mutableStateOf(state.settings) }
    // 系统通知开关可能被用户在系统设置里关掉，因此每次重组都重新读一次，而不是只在启动时读。
    val notificationsEnabled = androidx.core.app.NotificationManagerCompat.from(context).areNotificationsEnabled()
    var showCredentialEditor by rememberSaveable { mutableStateOf(false) }
    var credentialToDelete by rememberSaveable { mutableStateOf<String?>(null) }
    fun updateSettings(next: KotlinSettings) {
        settings = next
        model.saveSettingsDraft(next)
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 16.dp, end = 16.dp, top = 10.dp, bottom = 88.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item {
            Text(tr(Str.TabSettings), fontSize = 18.sp, fontWeight = FontWeight.Normal, color = FluxPalette.textPrimary, modifier = Modifier.padding(bottom = 6.dp))
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(containerColor = FluxPalette.surfaceCard),
                shape = RoundedCornerShape(8.dp),
                border = BorderStroke(1.dp, FluxPalette.borderAccent),
            ) {
                Column(Modifier.fillMaxWidth()) {
                    SettingsCompactRow(
                        icon = Icons.Default.FolderOpen,
                        title = tr(Str.OutputLocation),
                        subtitle = formatOutputLocation(context, settings.outputPath),
                        trailing = {
                            IconButton(onClick = onChooseOutputDirectory, modifier = Modifier.size(38.dp)) {
                                Icon(Icons.Default.FolderOpen, contentDescription = tr(Str.ChooseSystemDir), tint = FluxPalette.textStrong, modifier = Modifier.size(18.dp))
                            }
                        },
                    )
                    Box(Modifier.padding(horizontal = 8.dp, vertical = 5.dp)) {
                        StorageStatsPanel(
                            stats = state.storageStats,
                            loading = state.storageLoading,
                            unavailable = state.storageUnavailable,
                        )
                    }
                    SettingsDivider()
                    SettingsValueRow(Icons.Default.Download, tr(Str.MaxConcurrency), tr(Str.MaxConcurrencyHint), settings.concurrency, tr(Str.UnitCount)) { updateSettings(settings.copy(concurrency = it)) }
                    SettingsDivider()
                    SettingsValueRow(Icons.Default.Settings, tr(Str.MaxThreads), tr(Str.MaxThreadsHint), settings.threads, tr(Str.UnitThreads)) { updateSettings(settings.copy(threads = it)) }
                    SettingsDivider()
                    SettingsValueRow(Icons.Default.Replay, tr(Str.RetryAttempts), tr(Str.RetryAttemptsHint), settings.retries, tr(Str.UnitTimes)) { updateSettings(settings.copy(retries = it)) }
                    SettingsDivider()
                    SettingsValueRow(Icons.Default.Speed, tr(Str.SpeedLimit), tr(Str.SpeedLimitHint), settings.speedLimit, "", placeholder = tr(Str.Unlimited)) { updateSettings(settings.copy(speedLimit = it)) }

                    // 作者: long
                    // S1/S2：网络与通知属于运行策略，紧跟下载参数，避免用户为了“少耗流量/要提醒”翻到页面底部。
                    SettingsDivider()
                    SettingsSwitchRow(
                        icon = Icons.Default.Wifi,
                        title = tr(Str.WifiOnly),
                        subtitle = tr(Str.WifiOnlyHint),
                        checked = settings.wifiOnly,
                    ) { updateSettings(settings.copy(wifiOnly = it)) }
                    SettingsDivider()
                    SettingsSwitchRow(
                        icon = Icons.Default.Notifications,
                        title = tr(Str.NotifyOnComplete),
                        subtitle = if (notificationsEnabled) tr(Str.NotifyOnCompleteHint) else tr(Str.NotifyPermissionMissing),
                        checked = settings.notifyOnComplete,
                    ) { updateSettings(settings.copy(notifyOnComplete = it)) }
                    if (!notificationsEnabled) {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(start = 42.dp, end = 10.dp, bottom = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                tr(Str.NotificationsDisabled),
                                fontSize = 10.5.sp,
                                color = FluxPalette.warning,
                                modifier = Modifier.weight(1f),
                            )
                            TextButton(onClick = { model.requestNotificationPermission() }) {
                                Text(tr(Str.GoEnable), fontSize = 11.5.sp, color = FluxPalette.accentStrong)
                            }
                        }
                    }

                    // 作者: long
                    // S5：剪贴板识别涉及隐私，开关放在“交互”位置而不是网络区域，方便用户随时关掉。
                    SettingsDivider()
                    SettingsSwitchRow(
                        icon = Icons.Default.ContentPaste,
                        title = tr(Str.ClipboardPrompt),
                        subtitle = tr(Str.ClipboardPromptHint),
                        checked = settings.clipboardPrompt,
                    ) { updateSettings(settings.copy(clipboardPrompt = it)) }

                    // 作者: long
                    // S3 主题：三态（跟随系统/浅色/深色），选择后立即落盘并重组整棵树。
                    SettingsDivider()
                    SettingsChoiceRow(
                        icon = Icons.Default.Palette,
                        title = tr(Str.Theme),
                        subtitle = tr(Str.ThemeHint),
                        currentLabel = when (settings.theme) {
                            KotlinSettings.THEME_LIGHT -> tr(Str.ThemeLight)
                            KotlinSettings.THEME_DARK -> tr(Str.ThemeDark)
                            else -> tr(Str.ThemeSystem)
                        },
                        options = listOf(
                            KotlinSettings.THEME_SYSTEM to tr(Str.ThemeSystem),
                            KotlinSettings.THEME_LIGHT to tr(Str.ThemeLight),
                            KotlinSettings.THEME_DARK to tr(Str.ThemeDark),
                        ),
                        onSelect = { updateSettings(settings.copy(theme = it)) },
                    )

                    // 作者: long
                    // S4 语言：中英文双语，切换后立即落盘（CompositionLocal 更新触发整棵界面重组）。
                    SettingsDivider()
                    SettingsChoiceRow(
                        icon = Icons.Default.Language,
                        title = tr(Str.Language),
                        subtitle = tr(Str.LanguageHint),
                        currentLabel = when (settings.language) {
                            KotlinSettings.LANGUAGE_EN -> tr(Str.LanguageEn)
                            else -> tr(Str.LanguageZh)
                        },
                        options = listOf(
                            KotlinSettings.LANGUAGE_ZH to tr(Str.LanguageZh),
                            KotlinSettings.LANGUAGE_EN to tr(Str.LanguageEn),
                        ),
                        onSelect = { updateSettings(settings.copy(language = it)) },
                    )

                    // 作者: long
                    // 凭据、SFTP 和版本信息仍保留在同一张设置卡中，但放在下载参数后面，首屏先突出高频下载配置。
                    SettingsDivider()
                    SettingsCompactRow(
                        icon = Icons.Default.Key,
                        title = tr(Str.Credentials),
                        subtitle = if (state.credentialReferences.isEmpty()) tr(Str.CredentialsHintEmpty) else tr(Str.SavedCredentialsCount, state.credentialReferences.size),
                        trailing = {
                            IconButton(onClick = { showCredentialEditor = true }, modifier = Modifier.size(38.dp)) {
                                Icon(Icons.Default.Add, contentDescription = tr(Str.AddCredential), tint = FluxPalette.accentStrong, modifier = Modifier.size(18.dp))
                            }
                        },
                    )
                    state.credentialReferences.forEach { reference ->
                        Row(Modifier.fillMaxWidth().padding(start = 42.dp, end = 10.dp, top = 1.dp, bottom = 1.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Security, contentDescription = null, tint = FluxPalette.accent, modifier = Modifier.size(14.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(reference, modifier = Modifier.weight(1f), fontSize = 10.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            IconButton(onClick = { credentialToDelete = reference }, modifier = Modifier.size(30.dp)) {
                                Icon(Icons.Default.DeleteOutline, contentDescription = tr(Str.DeleteCredential), tint = FluxPalette.danger, modifier = Modifier.size(16.dp))
                            }
                        }
                    }
                    SettingsDivider()
                    SettingsCompactRow(
                        icon = Icons.Default.Security,
                        title = tr(Str.SftpKnownHosts),
                        subtitle = if (settings.sftpKnownHostsPath.isBlank()) tr(Str.SftpKnownHostsUnset) else tr(Str.SftpKnownHostsSet),
                        trailing = {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                IconButton(onClick = onChooseKnownHosts, modifier = Modifier.size(34.dp)) {
                                    Icon(Icons.Default.FolderOpen, contentDescription = tr(Str.ImportKnownHosts), tint = FluxPalette.accentStrong, modifier = Modifier.size(17.dp))
                                }
                                if (settings.sftpKnownHostsPath.isNotBlank()) {
                                    IconButton(onClick = { model.clearSftpKnownHosts() }, modifier = Modifier.size(34.dp)) {
                                        Icon(Icons.Default.DeleteOutline, contentDescription = tr(Str.ClearKnownHosts), tint = FluxPalette.danger, modifier = Modifier.size(17.dp))
                                    }
                                }
                            }
                        },
                    )
                    SettingsDivider()
                    SettingsCompactRow(
                        icon = Icons.Default.Info,
                        title = tr(Str.CurrentVersion),
                        subtitle = "v$KOTLIN_APP_VERSION · Rust ${state.rustVersion}",
                        trailing = {
                            if (state.updateChecking) {
                                androidx.compose.material3.CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                            } else {
                                IconButton(onClick = model::checkForUpdates, modifier = Modifier.size(38.dp)) {
                                    Icon(Icons.Default.SystemUpdateAlt, contentDescription = tr(Str.CheckUpdate), tint = FluxPalette.accentStrong, modifier = Modifier.size(17.dp))
                                }
                            }
                        },
                    )
                }
            }
        }
    }

    if (showCredentialEditor) {
        CredentialEditorDialog(
            onDismiss = { showCredentialEditor = false },
            onSave = { reference, credential ->
                showCredentialEditor = false
                model.saveCredential(reference, credential)
            },
        )
    }
    credentialToDelete?.let { reference ->
        AlertDialog(
            onDismissRequest = { credentialToDelete = null },
            title = { Text(tr(Str.DeleteCredential), fontSize = 16.sp) },
            text = { Text(tr(Str.DeleteCredentialMessage, reference), fontSize = 13.sp) },
            confirmButton = {
                TextButton(onClick = { credentialToDelete = null; model.deleteCredential(reference) }) { Text(tr(Str.Delete)) }
            },
            dismissButton = { TextButton(onClick = { credentialToDelete = null }) { Text(tr(Str.Cancel)) } },
        )
    }
}
