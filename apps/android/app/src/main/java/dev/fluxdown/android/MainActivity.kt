package dev.fluxdown.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.lifecycle.ViewModelProvider
import dev.fluxdown.android.ui.FluxDownApp
import dev.fluxdown.android.ui.FluxDownKotlinTheme
import dev.fluxdown.android.ui.collectAsStateCompat
import dev.fluxdown.android.viewmodel.NativeViewModel

/**
 * 作者: long
 * 只负责 Activity 壳与导航装配：创建 ViewModel、套主题、挂根 Composable。
 * 业务编排在 viewmodel/，Android 能力在 platform/，解析与模型在 data/，界面在 ui/。
 */
class MainActivity : ComponentActivity() {
    private lateinit var model: NativeViewModel

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        model = ViewModelProvider(this, NativeViewModel.factory(this))[NativeViewModel::class.java]
        setContent {
            // 作者: long
            // S3 主题跟随设置变化：themeKey 直接来自持久化的设置，切换后无需重建 Activity 即可重组。
            val state by model.state.collectAsStateCompat()
            // S4 语言：设置里的语言同时驱动 CompositionLocal 与无 Context 场景的兜底语言。
            dev.fluxdown.android.ui.i18n.AppLanguage.current = state.settings.language
            FluxDownKotlinTheme(themeKey = state.settings.theme, languageKey = state.settings.language) {
                FluxDownApp(model)
            }
        }
    }

    /**
     * S5 剪贴板识别挂在窗口焦点回调上：Android 10+ 只有在应用获得焦点后才允许读取剪贴板，
     * 否则 ClipboardService 会以 "application is not in focus" 拒绝并返回 null。
     * 重复触发由"同一链接只提示一次"兜底，不会重复打扰。
     */
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && ::model.isInitialized) model.detectClipboardSource()
    }
}
