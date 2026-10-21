package dev.fluxdown.android.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 作者: long
 * 属性面板依赖的耗时/平均速度计算必须是真实值，这里用三种任务状态锁定行为：
 * 运行中（无结束时间）、已完成、失败（有结束时间但字节数少）。
 */
class TaskPropertiesFormattingTest {
    private fun task(
        state: String,
        downloaded: Long = 0L,
        total: Long? = null,
        startedAtMs: Long? = null,
        finishedAtMs: Long? = null,
        speed: Long = 0L,
        error: String? = null,
        source: String = "https://example.com/file.zip",
    ) = QueueTask(
        id = "t1",
        name = "file.zip",
        source = source,
        state = state,
        downloadedBytes = downloaded,
        totalBytes = total,
        speedBytesPerSecond = speed,
        hlsSegmentsWritten = null,
        hlsSegmentsTotal = null,
        startedAtMs = startedAtMs,
        finishedAtMs = finishedAtMs,
        error = error,
        outputDir = "/data/user/0/dev.fluxdown.android/files/Downloads",
        torrentName = null,
        torrentFiles = emptyList(),
        torrentFileIndices = emptySet(),
        hlsVariantIndex = null,
        hlsKeepTransportStream = false,
        hlsRemuxedToMp4 = false,
        credentialRef = null,
    )

    @Test
    fun runningTaskReportsInProgressDurationAndLiveAverage() {
        // 运行中没有结束时间，平均速度以"当前时间 - 开始时间"为分母，因此用相对当前的真实起点。
        val running = task(
            state = "running",
            downloaded = 5L * 1024 * 1024,
            total = 10L * 1024 * 1024,
            startedAtMs = System.currentTimeMillis() - 100_000L,
            speed = 1024L * 1024,
        )
        assertEquals("进行中", formatDuration(running.startedAtMs, running.finishedAtMs))
        // 平均速度按"已下载 / 已耗时"计算：5 MiB / 100s ≈ 51.2 KB/s。
        assertEquals("51.2 KB/s", formatAverageSpeed(running))
    }

    @Test
    fun finishedTaskUsesRealElapsedTime() {
        val finished = task(
            state = "finished",
            downloaded = 10L * 1024 * 1024,
            total = 10L * 1024 * 1024,
            startedAtMs = 1_000_000L,
            finishedAtMs = 1_000_000L + 125_000L,
        )
        assertEquals("2分5秒", formatDuration(finished.startedAtMs, finished.finishedAtMs))
        // 10 MiB / 125s ≈ 81.9 KB/s
        assertEquals("81.9 KB/s", formatAverageSpeed(finished))
    }

    @Test
    fun failedTaskStillReportsElapsedAndError() {
        val failed = task(
            state = "failed",
            downloaded = 1024L * 1024,
            total = 10L * 1024 * 1024,
            startedAtMs = 1_000_000L,
            finishedAtMs = 1_000_000L + 65_000L,
            error = "连接被重置",
        )
        assertEquals("1分5秒", formatDuration(failed.startedAtMs, failed.finishedAtMs))
        assertEquals("15.8 KB/s", formatAverageSpeed(failed))
        assertEquals("失败", failed.stateLabel())
        assertEquals("连接被重置", failed.error)
    }

    @Test
    fun durationHandlesHoursAndMissingTimestamps() {
        assertEquals("1小时1分1秒", formatDuration(0L + 1L, 3_661_000L + 1L))
        assertEquals("--", formatDuration(null, null))
        assertEquals("--", formatDuration(0L, 5_000L))
        assertEquals("--", formatDateTime(null))
        assertEquals("--", formatDateTime(0L))
        assertTrue(formatDateTime(1_700_000_000_000L).startsWith("20"))
    }

    @Test
    fun protocolLabelCoversEveryBuiltinEntry() {
        assertEquals("HTTPS", protocolLabelFor("https://example.com/a.zip"))
        assertEquals("WebDAVS", protocolLabelFor("webdavs://example.com/a.zip"))
        assertEquals("SFTP", protocolLabelFor("sftp://example.com/a.zip"))
        assertEquals("HLS", protocolLabelFor("https://example.com/live/index.m3u8?token=1"))
        assertEquals("Torrent", protocolLabelFor("https://example.com/a.torrent"))
        assertEquals("Magnet", protocolLabelFor("magnet:?xt=urn:btih:abc"))
        assertEquals("ED2K", protocolLabelFor("ed2k://|file|a.avi|123|hash|/"))
    }
}
