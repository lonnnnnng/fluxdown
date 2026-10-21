package dev.fluxdown.android.platform

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.fluxdown.android.data.KotlinSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * 作者: long
 * 设置项的落盘契约：S1–S6 的每一项都必须能在新建 store 实例后原样读回，
 * 这就是“重启后保持”的自动化替代验证（真机侧另有手工回归）。
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class AndroidSettingsStoreTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()

    @Test
    fun defaultsMatchProductIntent() {
        val settings = AndroidSettingsStore(context).load("/tmp/Downloads")
        assertEquals("5", settings.concurrency)
        assertEquals("16", settings.threads)
        assertEquals("3", settings.retries)
        assertEquals("", settings.speedLimit)
        assertEquals("/tmp/Downloads", settings.outputPath)
        assertFalse("默认不限制 Wi-Fi", settings.wifiOnly)
        assertTrue("默认发送完成通知", settings.notifyOnComplete)
        assertEquals(KotlinSettings.THEME_SYSTEM, settings.theme)
        assertEquals(KotlinSettings.LANGUAGE_ZH, settings.language)
        assertTrue("默认识别剪贴板", settings.clipboardPrompt)
        assertEquals(KotlinSettings.FILTER_ALL, settings.queueFilter)
    }

    @Test
    fun everySettingSurvivesNewStoreInstance() {
        AndroidSettingsStore(context).save(
            KotlinSettings(
                concurrency = "9",
                threads = "24",
                retries = "5",
                speedLimit = "2.5",
                outputPath = "/sdcard/FluxDown",
                sftpKnownHostsPath = "/data/known_hosts",
                wifiOnly = true,
                notifyOnComplete = false,
                theme = KotlinSettings.THEME_DARK,
                language = KotlinSettings.LANGUAGE_EN,
                clipboardPrompt = false,
                queueFilter = KotlinSettings.FILTER_ENDED,
            ),
        )
        // 新建实例模拟进程重启后重新读取。
        val reloaded = AndroidSettingsStore(context).load("/fallback")
        assertEquals("9", reloaded.concurrency)
        assertEquals("24", reloaded.threads)
        assertEquals("5", reloaded.retries)
        assertEquals("2.5", reloaded.speedLimit)
        assertEquals("/sdcard/FluxDown", reloaded.outputPath)
        assertEquals("/data/known_hosts", reloaded.sftpKnownHostsPath)
        assertTrue(reloaded.wifiOnly)
        assertFalse(reloaded.notifyOnComplete)
        assertEquals(KotlinSettings.THEME_DARK, reloaded.theme)
        assertEquals(KotlinSettings.LANGUAGE_EN, reloaded.language)
        assertFalse(reloaded.clipboardPrompt)
        assertEquals(KotlinSettings.FILTER_ENDED, reloaded.queueFilter)
    }

    @Test
    fun queueFilterUpdatesIndependently() {
        val store = AndroidSettingsStore(context)
        store.save(KotlinSettings(concurrency = "7"))
        store.updateQueueFilter(KotlinSettings.FILTER_FAILED)
        val reloaded = AndroidSettingsStore(context).load("/tmp")
        assertEquals(KotlinSettings.FILTER_FAILED, reloaded.queueFilter)
        assertEquals("切换筛选不应覆盖下载参数", "7", reloaded.concurrency)
    }

    @Test
    fun unknownPersistedValuesFallBackToDefaults() {
        context.getSharedPreferences("fluxdown.kotlin.settings", Context.MODE_PRIVATE)
            .edit()
            .putString("theme", "sepia")
            .putString("language", "fr")
            .putString("queueFilter", "bogus")
            .apply()
        val reloaded = AndroidSettingsStore(context).load("/tmp")
        assertEquals(KotlinSettings.THEME_SYSTEM, reloaded.theme)
        assertEquals(KotlinSettings.LANGUAGE_ZH, reloaded.language)
        assertEquals(KotlinSettings.FILTER_ALL, reloaded.queueFilter)
    }
}
