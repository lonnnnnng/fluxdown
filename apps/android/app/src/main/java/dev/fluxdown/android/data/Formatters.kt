package dev.fluxdown.android.data

import dev.fluxdown.android.ui.i18n.AppLanguage
import dev.fluxdown.android.ui.i18n.Str
import dev.fluxdown.android.ui.i18n.text
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 作者: long
 * 展示层格式化：只负责把队列快照里的原始值转成用户可读文案，不做任何业务判断。
 */

internal fun QueueTask.stateLabel(language: String = AppLanguage.current): String = when (state) {
    "running" -> Str.StateRunning.text(language)
    "queued" -> Str.StateQueued.text(language)
    "paused" -> Str.StatePaused.text(language)
    "finished" -> Str.StateFinished.text(language)
    "failed" -> Str.StateFailedShort.text(language)
    "handed-off" -> Str.StateHandedOff.text(language)
    else -> state
}

internal fun QueueTask.hlsSegmentLabel(language: String = AppLanguage.current): String? {
    val written = hlsSegmentsWritten ?: return null
    val total = hlsSegmentsTotal ?: return null
    if (!source.substringBefore('?').substringBefore('#').endsWith(".m3u8", ignoreCase = true)) return null
    return String.format(Str.HlsSegmentProgress.text(language), written, total)
}

internal fun formatBytes(value: Long): String = when {
    value >= 1024L * 1024L * 1024L -> "%.1f GB".format(value / 1024.0 / 1024.0 / 1024.0)
    value >= 1024L * 1024L -> "%.1f MB".format(value / 1024.0 / 1024.0)
    value >= 1024L -> "%.1f KB".format(value / 1024.0)
    else -> "$value B"
}

internal fun formatTaskTime(value: Long): String = runCatching {
    SimpleDateFormat("yyyyMMdd HH:mm:ss", Locale.getDefault()).format(Date(value))
}.getOrDefault("--")

/** 属性面板使用的完整时间格式，缺失时统一显示占位符而不是 1970 年。 */
internal fun formatDateTime(value: Long?): String {
    if (value == null || value <= 0L) return "--"
    return runCatching {
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault()).format(Date(value))
    }.getOrDefault("--")
}

/** 耗时展示：不足 1 分钟用秒，超过 1 小时带小时位。 */
internal fun formatDuration(startMs: Long?, endMs: Long?, language: String = AppLanguage.current): String {
    if (startMs == null || startMs <= 0L) return "--"
    val end = endMs?.takeIf { it >= startMs } ?: return Str.StateInProgress.text(language)
    val totalSeconds = ((end - startMs) / 1000L).coerceAtLeast(0L)
    val hours = totalSeconds / 3600L
    val minutes = (totalSeconds % 3600L) / 60L
    val seconds = totalSeconds % 60L
    return when {
        hours > 0L -> String.format(Str.DurationHms.text(language), hours, minutes, seconds)
        minutes > 0L -> String.format(Str.DurationMs.text(language), minutes, seconds)
        else -> String.format(Str.DurationS.text(language), seconds)
    }
}

/**
 * 作者: long
 * 平均速度 = 已下载字节 / 实际耗时。只在任务已经产生可计算的耗时时返回，
 * 避免运行中把瞬时速度冒充平均速度。
 */
internal fun formatAverageSpeed(task: QueueTask): String {
    val start = task.startedAtMs ?: return "--"
    val end = task.finishedAtMs ?: System.currentTimeMillis()
    val elapsedMs = (end - start).coerceAtLeast(0L)
    if (elapsedMs < 1000L) return "--"
    val bytesPerSecond = task.downloadedBytes * 1000L / elapsedMs
    return "${formatBytes(bytesPerSecond)}/s"
}

/** 从下载源推断展示用协议名；Rust 已识别的协议优先，避免大小写和查询串干扰。 */
internal fun protocolLabelFor(source: String, language: String = AppLanguage.current): String {
    val path = source.substringBefore('?').substringBefore('#')
    // HLS 与 Torrent 是"基于 HTTP 的封装协议"，光看 scheme 会被误判成 HTTPS，
    // 因此先按扩展名判定，再回落到 scheme 映射。
    if (path.endsWith(".m3u8", ignoreCase = true)) return "HLS"
    if (path.endsWith(".torrent", ignoreCase = true)) return "Torrent"
    val scheme = source.substringBefore(':', missingDelimiterValue = "").trim().lowercase(Locale.ROOT)
    return when (scheme) {
        "http" -> "HTTP"
        "https" -> "HTTPS"
        "ftp" -> "FTP"
        "ftps" -> "FTPS"
        "sftp" -> "SFTP"
        "smb" -> "SMB"
        "webdav" -> "WebDAV"
        "webdavs" -> "WebDAVS"
        "magnet" -> "Magnet"
        "ed2k" -> "ED2K"
        else -> Str.Unknown.text(language)
    }
}
