package dev.fluxdown.android.viewmodel

import android.content.Context
import dev.fluxdown.android.data.KOTLIN_APP_VERSION
import dev.fluxdown.android.data.KotlinSettings
import dev.fluxdown.android.data.QueueRepository
import dev.fluxdown.android.data.parseError
import dev.fluxdown.android.data.parseHlsAudioRenditions
import dev.fluxdown.android.data.parseHlsVariants
import dev.fluxdown.android.platform.AndroidCredentialVault
import dev.fluxdown.android.platform.AndroidSettingsStore
import dev.fluxdown.android.platform.AndroidStorageProbe
import dev.fluxdown.android.platform.AndroidUpdateChecker
import dev.fluxdown.android.platform.StoredAndroidCredential
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import dev.fluxdown.android.ui.i18n.Str
import dev.fluxdown.android.ui.i18n.trApp

/**
 * 作者: long
 * 设置、凭据、存储统计、更新检查和 HLS 清晰度探测的统一编排。
 * 这些操作都以"写一次持久化 + 回写一份 UI 快照"收尾，集中在这里避免 ViewModel 变成杂物间。
 */
internal class SettingsController(
    private val context: Context,
    private val credentialVault: AndroidCredentialVault,
    private val settingsStore: AndroidSettingsStore,
    private val queue: QueueRepository,
    private val defaultOutputPath: String,
    private val updateState: ((NativeUiState) -> NativeUiState) -> Unit,
    private val stateProvider: () -> NativeUiState,
    private val scope: CoroutineScope,
) {
    private suspend fun publish(transform: (NativeUiState) -> NativeUiState) {
        withContext(Dispatchers.Main) { updateState(transform) }
    }

    fun saveCredential(reference: String, credential: StoredAndroidCredential) {
        scope.launch(Dispatchers.IO) {
            val result = runCatching {
                credentialVault.put(reference, credential)
                val normalized = reference.trim()
                val references = (current().credentialReferences + normalized).toSet().toList().sorted()
                settingsStore.saveCredentialReferences(references)
                references
            }
            result.onSuccess { references ->
                publish { it.copy(credentialReferences = references, notice = trApp(Str.CredentialSavedNotice)) }
            }.onFailure { error ->
                publish { it.copy(notice = error.message ?: trApp(Str.CredentialSaveFailed)) }
            }
        }
    }

    fun deleteCredential(reference: String) {
        scope.launch(Dispatchers.IO) {
            val result = runCatching {
                credentialVault.remove(reference)
                val references = current().credentialReferences.filterNot { it == reference }
                settingsStore.saveCredentialReferences(references)
                references
            }
            result.onSuccess { references ->
                publish { it.copy(credentialReferences = references, notice = trApp(Str.CredentialDeletedNotice)) }
            }.onFailure { error ->
                publish { it.copy(notice = error.message ?: trApp(Str.CredentialDeleteFailed)) }
            }
        }
    }

    fun checkForUpdates() {
        if (current().updateChecking) return
        updateState { it.copy(updateChecking = true) }
        scope.launch(Dispatchers.IO) {
            val result = runCatching { AndroidUpdateChecker.fetchLatest(KOTLIN_APP_VERSION) }
            publish { it.copy(updateChecking = false) }
            result.onSuccess { report ->
                publish { it.copy(notice = trApp(Str.UpdateCheckDone), updateReport = report) }
            }.onFailure { error ->
                publish { it.copy(notice = error.message ?: trApp(Str.UpdateCheckFailed), updateReport = null) }
            }
        }
    }

    fun loadHlsVariants(source: String) {
        val requested = source.trim()
        if (!requested.substringBefore('?').substringBefore('#').endsWith(".m3u8", ignoreCase = true)) {
            updateState { it.copy(hlsVariants = emptyList(), hlsAudioRenditions = emptyList(), hlsVariantsSource = null, hlsVariantsLoading = false, hlsVariantsError = null) }
            return
        }
        if (current().hlsVariantsLoading && current().hlsVariantsSource == requested) return
        updateState { it.copy(hlsVariants = emptyList(), hlsAudioRenditions = emptyList(), hlsVariantsSource = requested, hlsVariantsLoading = true, hlsVariantsError = null) }
        scope.launch(Dispatchers.IO) {
            val envelope = queue.hlsVariants(requested)
            val error = parseError(envelope)
            val result = if (error == null) parseHlsVariants(envelope) else emptyList()
            // 作者: long
            // 音轨与清晰度来自同一份 master playlist，一次点击要一起读出来；
            // 音轨读取失败只影响音轨列表，不应把已拿到的清晰度也清空。
            val audio = if (error == null) parseHlsAudioRenditions(queue.hlsAudioRenditions(requested)) else emptyList()
            withContext(Dispatchers.Main) {
                // 作者: long
                // 网络请求返回可能晚于用户继续编辑链接，只接受仍对应当前地址的结果，避免旧清晰度列表套到新任务。
                updateState {
                    if (it.hlsVariantsSource == requested) {
                        it.copy(hlsVariants = result, hlsAudioRenditions = audio, hlsVariantsLoading = false, hlsVariantsError = error)
                    } else {
                        it
                    }
                }
            }
        }
    }

    fun refreshStorageStats(path: String) {
        updateState { it.copy(storageLoading = true) }
        scope.launch(Dispatchers.IO) {
            val stats = AndroidStorageProbe.read(context, path)
            publish { it.copy(storageStats = stats, storageLoading = false, storageUnavailable = stats == null) }
        }
    }

    fun saveSettings(settings: KotlinSettings, showNotice: Boolean = true) {
        val normalized = settings.copy(
            concurrency = settings.concurrency.toIntOrNull()?.coerceIn(1, 30)?.toString() ?: "5",
            threads = settings.threads.toIntOrNull()?.coerceIn(1, 32)?.toString() ?: "16",
            retries = settings.retries.toIntOrNull()?.coerceIn(0, 10)?.toString() ?: "3",
            speedLimit = settings.speedLimit.trim().let { value ->
                if (value.isBlank()) "" else value.toDoubleOrNull()?.coerceAtLeast(0.0)?.toString() ?: ""
            },
            outputPath = settings.outputPath.ifBlank { defaultOutputPath },
            sftpKnownHostsPath = settings.sftpKnownHostsPath.trim(),
        )
        settingsStore.save(normalized)
        updateState { it.copy(settings = normalized, notice = if (showNotice) trApp(Str.SettingsSavedNotice) else it.notice) }
        refreshStorageStats(normalized.outputPath)
    }

    /**
     * 设置输入框采用原版的即时保存方式；编辑中的空值暂不回填默认值，避免用户清空输入时光标被打断。
     * 作者: long
     */
    fun saveSettingsDraft(settings: KotlinSettings) {
        val draft = settings.copy(
            concurrency = settings.concurrency.filter(Char::isDigit),
            threads = settings.threads.filter(Char::isDigit),
            retries = settings.retries.filter(Char::isDigit),
            speedLimit = settings.speedLimit.filter { it.isDigit() || it == '.' },
            outputPath = settings.outputPath.ifBlank { defaultOutputPath },
            sftpKnownHostsPath = settings.sftpKnownHostsPath.trim(),
        )
        settingsStore.save(draft)
        updateState { it.copy(settings = draft) }
    }

    private fun current(): NativeUiState = stateProvider()
}
