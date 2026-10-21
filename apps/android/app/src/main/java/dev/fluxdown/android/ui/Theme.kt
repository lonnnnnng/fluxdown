package dev.fluxdown.android.ui
import dev.fluxdown.android.*
import dev.fluxdown.android.data.KotlinSettings

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.State
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import kotlinx.coroutines.flow.StateFlow
import dev.fluxdown.android.ui.i18n.LocalLanguage

/**
 * 作者: long
 * S3 主题支持要求"浅色/深色"两套语义色，而界面里原本散落着大量 Color(0xFF...) 字面量。
 * 这里把它们收敛成语义 token：界面只引用 FluxPalette.xxx，深浅切换只改本文件。
 */
internal data class FluxColors(
    val textPrimary: Color,
    val textStrong: Color,
    val textStrongAlt: Color,
    val textStrongAlt2: Color,
    val textStrongAlt3: Color,
    val textStrongAlt4: Color,
    val textSecondary: Color,
    val textMuted: Color,
    val textDisabled: Color,
    val iconDisabled: Color,
    val accent: Color,
    val accentStrong: Color,
    val accentDarker: Color,
    val primary: Color,
    val secondary: Color,
    val danger: Color,
    val dangerStrong: Color,
    val dangerText: Color,
    val dangerSurface: Color,
    val dangerSurfaceSoft: Color,
    val warning: Color,
    val warningAlt: Color,
    val warningAlt2: Color,
    val warningSurface: Color,
    val warningSurfaceSoft: Color,
    val success: Color,
    val successAlt: Color,
    val successText: Color,
    val successTextAlt: Color,
    val successSurface: Color,
    val successSurfaceSoft: Color,
    val background: Color,
    val backgroundAlt: Color,
    val surfaceCard: Color,
    val surfaceMuted: Color,
    val surfaceMutedAlt: Color,
    val surfaceMutedAlt2: Color,
    val surfaceTint: Color,
    val surfaceTintAlt: Color,
    val surfaceTintAlt2: Color,
    val surfaceTintAlt3: Color,
    val surfaceTintAlt4: Color,
    val chipBackground: Color,
    val border: Color,
    val borderAlt: Color,
    val borderAlt2: Color,
    val borderAccent: Color,
    val borderAccentStrong: Color,
    val borderDanger: Color,
    val borderDangerStrong: Color,
    val borderWarning: Color,
    val borderSuccess: Color,
    val progressTrack: Color,
)

private val LightFluxColors = FluxColors(
        textPrimary = Color(0xFF20252B),
        textStrong = Color(0xFF3F4B55),
        textStrongAlt = Color(0xFF2C3E50),
        textStrongAlt2 = Color(0xFF50606C),
        textStrongAlt3 = Color(0xFF5D646D),
        textStrongAlt4 = Color(0xFF31566E),
        textSecondary = Color(0xFF687782),
        textMuted = Color(0xFF74838D),
        textDisabled = Color(0xFF9AA8B2),
        iconDisabled = Color(0xFFB6C0C8),
        accent = Color(0xFF168BD1),
        accentStrong = Color(0xFF0F6FA8),
        accentDarker = Color(0xFF17658F),
        primary = Color(0xFF2B8FD8),
        secondary = Color(0xFF1F7A9E),
        danger = Color(0xFFC64B4B),
        dangerStrong = Color(0xFFB33A3A),
        dangerText = Color(0xFF7A3030),
        dangerSurface = Color(0xFFFFF1F1),
        dangerSurfaceSoft = Color(0xFFFFF5F5),
        warning = Color(0xFF8A5A10),
        warningAlt = Color(0xFFB4761A),
        warningAlt2 = Color(0xFFB7791F),
        warningSurface = Color(0xFFFFF4E0),
        warningSurfaceSoft = Color(0xFFFFFAF0),
        success = Color(0xFF2E8B57),
        successAlt = Color(0xFF3E7D3A),
        successText = Color(0xFF4C5A50),
        successTextAlt = Color(0xFF6B7A70),
        successSurface = Color(0xFFEFF7EC),
        successSurfaceSoft = Color(0xFFF1FBF5),
        background = Color(0xFFF4F8FC),
        backgroundAlt = Color(0xFFF7FCFF),
        surfaceCard = Color(0xFFFFFFFF),
        surfaceMuted = Color(0xFFE8F1F7),
        surfaceMutedAlt = Color(0xFFE5EEF4),
        surfaceMutedAlt2 = Color(0xFFE6EDF2),
        surfaceTint = Color(0xFFE8F5FC),
        surfaceTintAlt = Color(0xFFEAF6FD),
        surfaceTintAlt2 = Color(0xFFE8F3FB),
        surfaceTintAlt3 = Color(0xFFD9EAF5),
        surfaceTintAlt4 = Color(0xFFF3F6FE),
        chipBackground = Color(0xFFDDECFB),
        border = Color(0xFFCFE5F3),
        borderAlt = Color(0xFFCFDCE6),
        borderAlt2 = Color(0xFFCBD5E1),
        borderAccent = Color(0x2A168BD1),
        borderAccentStrong = Color(0x4A168BD1),
        borderDanger = Color(0x3AC64B4B),
        borderDangerStrong = Color(0x4AC64B4B),
        borderWarning = Color(0x4AB7791F),
        borderSuccess = Color(0x4A2E8B57),
        progressTrack = Color(0xB89DD8F5),
)

private val DarkFluxColors = FluxColors(
        textPrimary = Color(0xFFE7EEF5),
        textStrong = Color(0xFFC6D3DE),
        textStrongAlt = Color(0xFFB4C4D2),
        textStrongAlt2 = Color(0xFFAEBECD),
        textStrongAlt3 = Color(0xFFA2B2C1),
        textStrongAlt4 = Color(0xFFA6B6C5),
        textSecondary = Color(0xFF9FB0BF),
        textMuted = Color(0xFF8B9AA8),
        textDisabled = Color(0xFF6B7A88),
        iconDisabled = Color(0xFF5A6874),
        accent = Color(0xFF63B8EE),
        accentStrong = Color(0xFF7FC7F0),
        accentDarker = Color(0xFF9AD2F2),
        primary = Color(0xFF63B8EE),
        secondary = Color(0xFF6FC7DE),
        danger = Color(0xFFE88A8A),
        dangerStrong = Color(0xFFF0A0A0),
        dangerText = Color(0xFFFFC9C9),
        dangerSurface = Color(0xFF3A2225),
        dangerSurfaceSoft = Color(0xFF33201F),
        warning = Color(0xFFE7B96A),
        warningAlt = Color(0xFFEDC98A),
        warningAlt2 = Color(0xFFEDC98A),
        warningSurface = Color(0xFF3A2F1B),
        warningSurfaceSoft = Color(0xFF322A1C),
        success = Color(0xFF6FD39A),
        successAlt = Color(0xFF8BD98A),
        successText = Color(0xFFB6C7BB),
        successTextAlt = Color(0xFF9FB0A6),
        successSurface = Color(0xFF1E2E24),
        successSurfaceSoft = Color(0xFF1C2C22),
        background = Color(0xFF0E1620),
        backgroundAlt = Color(0xFF101A24),
        surfaceCard = Color(0xFF16202B),
        surfaceMuted = Color(0xFF1F2C39),
        surfaceMutedAlt = Color(0xFF1C2936),
        surfaceMutedAlt2 = Color(0xFF1D2A37),
        surfaceTint = Color(0xFF16293A),
        surfaceTintAlt = Color(0xFF172A3B),
        surfaceTintAlt2 = Color(0xFF162838),
        surfaceTintAlt3 = Color(0xFF1B3040),
        surfaceTintAlt4 = Color(0xFF152636),
        chipBackground = Color(0xFF1E3448),
        border = Color(0xFF27455C),
        borderAlt = Color(0xFF2A3A48),
        borderAlt2 = Color(0xFF2E4051),
        borderAccent = Color(0x4A63B8EE),
        borderAccentStrong = Color(0x5A63B8EE),
        borderDanger = Color(0x5AE88A8A),
        borderDangerStrong = Color(0x66E88A8A),
        borderWarning = Color(0x66E7B96A),
        borderSuccess = Color(0x666FD39A),
        progressTrack = Color(0xFF1E3448),
)

private val LocalFluxColors = staticCompositionLocalOf { LightFluxColors }

/**
 * 界面层的唯一取色入口。用 @Composable getter 而不是全局常量，
 * 这样调用点不需要额外声明局部变量，也能在深浅切换时自动重组。
 */
internal object FluxPalette {
    val textPrimary: Color @Composable get() = LocalFluxColors.current.textPrimary
    val textStrong: Color @Composable get() = LocalFluxColors.current.textStrong
    val textStrongAlt: Color @Composable get() = LocalFluxColors.current.textStrongAlt
    val textStrongAlt2: Color @Composable get() = LocalFluxColors.current.textStrongAlt2
    val textStrongAlt3: Color @Composable get() = LocalFluxColors.current.textStrongAlt3
    val textStrongAlt4: Color @Composable get() = LocalFluxColors.current.textStrongAlt4
    val textSecondary: Color @Composable get() = LocalFluxColors.current.textSecondary
    val textMuted: Color @Composable get() = LocalFluxColors.current.textMuted
    val textDisabled: Color @Composable get() = LocalFluxColors.current.textDisabled
    val iconDisabled: Color @Composable get() = LocalFluxColors.current.iconDisabled
    val accent: Color @Composable get() = LocalFluxColors.current.accent
    val accentStrong: Color @Composable get() = LocalFluxColors.current.accentStrong
    val accentDarker: Color @Composable get() = LocalFluxColors.current.accentDarker
    val primary: Color @Composable get() = LocalFluxColors.current.primary
    val secondary: Color @Composable get() = LocalFluxColors.current.secondary
    val danger: Color @Composable get() = LocalFluxColors.current.danger
    val dangerStrong: Color @Composable get() = LocalFluxColors.current.dangerStrong
    val dangerText: Color @Composable get() = LocalFluxColors.current.dangerText
    val dangerSurface: Color @Composable get() = LocalFluxColors.current.dangerSurface
    val dangerSurfaceSoft: Color @Composable get() = LocalFluxColors.current.dangerSurfaceSoft
    val warning: Color @Composable get() = LocalFluxColors.current.warning
    val warningAlt: Color @Composable get() = LocalFluxColors.current.warningAlt
    val warningAlt2: Color @Composable get() = LocalFluxColors.current.warningAlt2
    val warningSurface: Color @Composable get() = LocalFluxColors.current.warningSurface
    val warningSurfaceSoft: Color @Composable get() = LocalFluxColors.current.warningSurfaceSoft
    val success: Color @Composable get() = LocalFluxColors.current.success
    val successAlt: Color @Composable get() = LocalFluxColors.current.successAlt
    val successText: Color @Composable get() = LocalFluxColors.current.successText
    val successTextAlt: Color @Composable get() = LocalFluxColors.current.successTextAlt
    val successSurface: Color @Composable get() = LocalFluxColors.current.successSurface
    val successSurfaceSoft: Color @Composable get() = LocalFluxColors.current.successSurfaceSoft
    val background: Color @Composable get() = LocalFluxColors.current.background
    val backgroundAlt: Color @Composable get() = LocalFluxColors.current.backgroundAlt
    val surfaceCard: Color @Composable get() = LocalFluxColors.current.surfaceCard
    val surfaceMuted: Color @Composable get() = LocalFluxColors.current.surfaceMuted
    val surfaceMutedAlt: Color @Composable get() = LocalFluxColors.current.surfaceMutedAlt
    val surfaceMutedAlt2: Color @Composable get() = LocalFluxColors.current.surfaceMutedAlt2
    val surfaceTint: Color @Composable get() = LocalFluxColors.current.surfaceTint
    val surfaceTintAlt: Color @Composable get() = LocalFluxColors.current.surfaceTintAlt
    val surfaceTintAlt2: Color @Composable get() = LocalFluxColors.current.surfaceTintAlt2
    val surfaceTintAlt3: Color @Composable get() = LocalFluxColors.current.surfaceTintAlt3
    val surfaceTintAlt4: Color @Composable get() = LocalFluxColors.current.surfaceTintAlt4
    val chipBackground: Color @Composable get() = LocalFluxColors.current.chipBackground
    val border: Color @Composable get() = LocalFluxColors.current.border
    val borderAlt: Color @Composable get() = LocalFluxColors.current.borderAlt
    val borderAlt2: Color @Composable get() = LocalFluxColors.current.borderAlt2
    val borderAccent: Color @Composable get() = LocalFluxColors.current.borderAccent
    val borderAccentStrong: Color @Composable get() = LocalFluxColors.current.borderAccentStrong
    val borderDanger: Color @Composable get() = LocalFluxColors.current.borderDanger
    val borderDangerStrong: Color @Composable get() = LocalFluxColors.current.borderDangerStrong
    val borderWarning: Color @Composable get() = LocalFluxColors.current.borderWarning
    val borderSuccess: Color @Composable get() = LocalFluxColors.current.borderSuccess
    val progressTrack: Color @Composable get() = LocalFluxColors.current.progressTrack
}

/**
 * @param themeKey KotlinSettings.THEME_SYSTEM / THEME_LIGHT / THEME_DARK
 */
@Composable
internal fun FluxDownKotlinTheme(
    themeKey: String = KotlinSettings.THEME_SYSTEM,
    languageKey: String = KotlinSettings.LANGUAGE_ZH,
    content: @Composable () -> Unit,
) {
    val dark = when (themeKey) {
        KotlinSettings.THEME_LIGHT -> false
        KotlinSettings.THEME_DARK -> true
        else -> isSystemInDarkTheme()
    }
    val palette = if (dark) DarkFluxColors else LightFluxColors
    val colors = if (dark) {
        darkColorScheme(
            primary = Color(0xFF63B8EE),
            onPrimary = Color(0xFF06263A),
            secondary = Color(0xFF6FC7DE),
            background = Color(0xFF0E1620),
            surface = Color(0xFF16202B),
            surfaceVariant = Color(0xFF1F2C39),
            onSurface = Color(0xFFE7EEF5),
            onBackground = Color(0xFFE7EEF5),
        )
    } else {
        lightColorScheme(
            primary = Color(0xFF2B8FD8),
            onPrimary = Color.White,
            secondary = Color(0xFF1F7A9E),
            background = Color(0xFFF4F8FC),
            surface = Color.White,
            surfaceVariant = Color(0xFFE8F1F7),
            onSurface = Color(0xFF20252B),
            onBackground = Color(0xFF20252B),
        )
    }
    CompositionLocalProvider(LocalFluxColors provides palette, LocalLanguage provides languageKey) {
        MaterialTheme(colorScheme = colors, content = content)
    }
}

/** 兼容封装：集中 collectAsState 的调用点，方便后续替换成 lifecycle-aware 版本。 */
@Composable
internal fun <T> StateFlow<T>.collectAsStateCompat(): State<T> = collectAsState()
