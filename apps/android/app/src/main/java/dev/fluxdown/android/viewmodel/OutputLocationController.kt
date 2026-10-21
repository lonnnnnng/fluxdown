package dev.fluxdown.android.viewmodel

import android.net.Uri
import dev.fluxdown.android.platform.AndroidSettingsStore
import dev.fluxdown.android.platform.SafStorage
import dev.fluxdown.android.platform.SftpKnownHostsStore
import dev.fluxdown.android.ui.i18n.Str
import dev.fluxdown.android.ui.i18n.trApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 作者: long
 * 保存位置与 SFTP known_hosts 的选取逻辑。
 *
 * 两者都是“用户从系统选择器拿回一个 content:// URI，再落成 Rust 能读的形态”，
 * 与队列状态机无关，所以从 ViewModel 里独立出来。
 */
internal class OutputLocationController(
    private val safStorage: SafStorage,
    private val settingsStore: AndroidSettingsStore,
    private val knownHostsStore: SftpKnownHostsStore,
    private val state: MutableStateFlow<NativeUiState>,
    private val scope: CoroutineScope,
    private val refreshStorageStats: (String) -> Unit,
) {
    fun select(uri: Uri) {
        scope.launch(Dispatchers.IO) {
            val persisted = safStorage.persistTree(uri)
            withContext(Dispatchers.Main) {
                if (persisted == null) {
                    state.value = state.value.copy(notice = trApp(Str.DirNotWritable))
                } else {
                    val path = uri.toString()
                    val settings = state.value.settings.copy(outputPath = path)
                    settingsStore.updateOutputPath(path)
                    state.value = state.value.copy(
                        settings = settings,
                        notice = trApp(
                            Str.OutputSelectedNotice,
                            persisted.name ?: trApp(Str.OutputChosenDirLabel),
                        ),
                    )
                    refreshStorageStats(path)
                }
            }
        }
    }

    /**
     * SAF 返回的是 content URI，Rust 只能读取 POSIX 文件；因此把 known_hosts 复制到应用私有目录，
     * 并只把私有副本路径传给 Rust，避免授权失效或外部文件被替换造成主机密钥策略漂移。
     */
    fun importKnownHosts(uri: Uri) {
        scope.launch(Dispatchers.IO) {
            val result = runCatching { knownHostsStore.import(uri) }
            withContext(Dispatchers.Main) {
                result.onSuccess { path ->
                    val settings = state.value.settings.copy(sftpKnownHostsPath = path)
                    settingsStore.updateKnownHostsPath(path)
                    state.value = state.value.copy(settings = settings, notice = trApp(Str.KnownHostsUpdatedNotice))
                }.onFailure {
                    state.value = state.value.copy(notice = it.message ?: trApp(Str.KnownHostsReadFailed))
                }
            }
        }
    }

    fun clearKnownHosts() {
        knownHostsStore.clear(state.value.settings.sftpKnownHostsPath)
        val settings = state.value.settings.copy(sftpKnownHostsPath = "")
        settingsStore.clearKnownHostsPath()
        state.value = state.value.copy(settings = settings, notice = trApp(Str.KnownHostsClearedNotice))
    }
}
