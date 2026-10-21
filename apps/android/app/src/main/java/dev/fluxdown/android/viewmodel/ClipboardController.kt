package dev.fluxdown.android.viewmodel

import android.content.Context
import dev.fluxdown.android.data.ProtocolDetector
import dev.fluxdown.android.data.clipboardDownloadSource
import dev.fluxdown.android.platform.AndroidSettingsStore
import dev.fluxdown.android.platform.ClipboardSourceReader
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * 作者: long
 * S5 剪贴板链接识别。
 *
 * 单独成类的原因：读剪贴板必须发生在 Activity 拿到焦点之后（Android 10+ 会拒绝后台读取），
 * 而"提示过一次就不再提示"又需要落盘记录，两者都不属于 ViewModel 的队列职责。
 */
internal class ClipboardController(
    private val context: Context,
    private val settingsStore: AndroidSettingsStore,
    private val state: MutableStateFlow<NativeUiState>,
) {
    /**
     * 只在开关打开、且与上次提示的链接不同时才抛出建议，
     * 避免 Android 13+ 的粘贴提示和 UI 提示条每次启动都重复出现。
     */
    fun detect() {
        if (!state.value.settings.clipboardPrompt) return
        val raw = ClipboardSourceReader.read(context) ?: return
        val source = clipboardDownloadSource(raw) { ProtocolDetector.detect(it) } ?: return
        if (source == settingsStore.clipboardLastSeen()) return
        state.value = state.value.copy(clipboardSuggestion = source)
    }

    /** 用户点“新建”：返回待填充的下载源，并记下已提示过，后续启动不再弹。 */
    fun consume(): String? {
        val source = state.value.clipboardSuggestion ?: return null
        settingsStore.updateClipboardLastSeen(source)
        state.value = state.value.copy(clipboardSuggestion = null)
        return source
    }

    fun dismiss() {
        consume()
    }
}
