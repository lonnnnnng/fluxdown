package dev.fluxdown.android.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * 作者: long
 * S5 剪贴板识别规则的单测：剪贴板内容经常混着标题、标点和换行，
 * 这里锁定"只取第一个可识别链接"的行为，避免误提示普通文本。
 */
class ClipboardRulesTest {
    private val detect: (String) -> String? = { source ->
        when {
            source.startsWith("http://") || source.startsWith("https://") -> "https"
            source.startsWith("magnet:") -> "magnet"
            source.endsWith(".torrent") -> "torrent"
            source.startsWith("ftp://") -> "ftp"
            else -> "unknown"
        }
    }

    @Test
    fun extractsUrlFromSurroundingText() {
        val raw = "分享文件： 复制这段内容 https://example.com/demo.bin 提取码 1234"
        assertEquals("https://example.com/demo.bin", clipboardDownloadSource(raw, detect))
    }

    @Test
    fun stripsQuotesAndChinesePunctuation() {
        val raw = "“https://example.com/a.zip”，"
        assertEquals("https://example.com/a.zip", clipboardDownloadSource(raw, detect))
    }

    @Test
    fun prefersFirstRecognisedCandidateAcrossLines() {
        val raw = "标题行\n\nmagnet:?xt=urn:btih:abcdef\n备用 https://example.com/b.bin"
        assertEquals("magnet:?xt=urn:btih:abcdef", clipboardDownloadSource(raw, detect))
    }

    @Test
    fun plainTextIsNotSuggested() {
        assertNull(clipboardDownloadSource("今天天气不错，记得下载更新。", detect))
        assertNull(clipboardDownloadSource("", detect))
        assertNull(clipboardDownloadSource(null, detect))
    }

    @Test
    fun unknownSchemeIsIgnored() {
        assertNull(clipboardDownloadSource("file:///sdcard/demo.bin", detect))
    }

    @Test
    fun overlyLongClipboardIsIgnored() {
        val raw = "x".repeat(9_000) + " https://example.com/demo.bin"
        assertNull(clipboardDownloadSource(raw, detect))
    }
}
