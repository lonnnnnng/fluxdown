package dev.fluxdown.android.ui.i18n

import dev.fluxdown.android.data.KotlinSettings
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * 作者: long
 * Rust 的 `USER_FACING_ERROR_CODES` 是错误码契约的唯一来源；界面必须为每个码提供
 * 中英双语文案，否则非中文用户在失败任务上会看到中文原文。
 *
 * 这里直接读 Rust 源码而不是抄一份列表，是为了让新增错误码忘记登记界面文案时立刻失败。
 */
class ErrorTextTest {

    private val rustSource = File("../../../crates/fluxdown-core/src/downloader.rs")

    private fun rustCodes(): List<String> {
        assumeTrue("找不到 Rust 源码，跳过跨端错误码一致性校验", rustSource.isFile)
        val text = rustSource.readText()
        val start = text.indexOf("pub const USER_FACING_ERROR_CODES")
        assertTrue("Rust 源码里没有 USER_FACING_ERROR_CODES", start >= 0)
        val open = text.indexOf('&', start)
        val body = text.substring(open, text.indexOf("];", open))
        return Regex("\"([a-z0-9_]+)\"").findAll(body).map { it.groupValues[1] }.toList()
    }

    @Test
    fun everyRustErrorCodeHasLocalizedText() {
        val codes = rustCodes()
        assertTrue("Rust 错误码列表为空", codes.size > 10)
        val missing = codes.filter { errorTextKey(it) == null }
        assertTrue("以下 Rust 错误码缺少界面文案（同步 ErrorText.kt 与 Strings.kt）：$missing", missing.isEmpty())
    }

    @Test
    fun unknownCodeFallsBackToRustMessage() {
        assertNull(errorTextKey("brand_new_code_from_future_rust"))
        assertEquals("网络连接失败", localizedErrorIn(KotlinSettings.LANGUAGE_ZH, "nope", "网络连接失败"))
        assertNull(localizedErrorIn(KotlinSettings.LANGUAGE_ZH, "nope", "   "))
        assertNull(localizedErrorIn(KotlinSettings.LANGUAGE_ZH, "nope", null))
    }

    @Test
    fun knownCodeIgnoresRustRawText() {
        // 已知错误码必须换成本地化文案，不能把中文原文透出去。
        val english = localizedErrorIn(KotlinSettings.LANGUAGE_EN, "disk_full", "磁盘空间不足")
        assertEquals(Str.ErrDiskFull.en, english)
        val chinese = localizedErrorIn(KotlinSettings.LANGUAGE_ZH, "disk_full", "磁盘空间不足")
        assertEquals(Str.ErrDiskFull.zh, chinese)
    }

    @Test
    fun everyErrorStringEntryIsActuallyUsed() {
        val used = rustCodes().mapNotNull { errorTextKey(it) }.toSet()
        val orphans = Str.entries
            .filter { it.name.startsWith("Err") && it !in used }
            .map { it.name }
        assertTrue("以下错误文案没有被任何 Rust 错误码使用：$orphans", orphans.isEmpty())
    }

    @Test
    fun localizedTextIsBilingualAndNonBlank() {
        rustCodes().forEach { code ->
            val key = errorTextKey(code)
            assertNotNull("错误码 $code 没有文案", key)
            assertTrue("$code 缺少中文文案", key!!.zh.isNotBlank())
            assertTrue("$code 缺少英文文案", key.en.isNotBlank())
            assertTrue("$code 中英文相同：${key.zh}", key.zh != key.en)
        }
    }
}
