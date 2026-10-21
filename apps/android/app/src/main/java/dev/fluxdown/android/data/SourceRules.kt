package dev.fluxdown.android.data

import android.util.Base64
import dev.fluxdown.android.ui.i18n.Str
import dev.fluxdown.android.ui.i18n.trApp

/**
 * 作者: long
 * 下载源校验规则与 SAF 路径回退规则。这些函数不持有 Android Context，
 * 因此可以脱离设备在 JVM 单测中直接覆盖。
 */

internal fun supportsCredentialProtocol(protocol: String?): Boolean = protocol in setOf(
    "http",
    "https",
    "webdav",
    "webdavs",
    "ftp",
    "ftps",
    "sftp",
    "smb",
)

internal fun downloadSourceIssue(source: String, protocol: String?): String? {
    if (source.isBlank()) return trApp(Str.PleaseEnterLink)
    if (protocol !in setOf(
            "http", "https", "m3u8", "torrent", "magnet", "ftp", "ftps",
            "sftp", "ed2k", "smb", "webdav", "webdavs",
        )
    ) {
        return trApp(Str.UnsupportedProtocolLink)
    }
    return null
}

internal fun hasUsableKnownHostEntry(content: String): Boolean = content.lineSequence().any { rawLine ->
    val line = rawLine.trim()
    if (line.isEmpty() || line.startsWith("#")) return@any false
    val fields = line.split(Regex("\\s+"))
    if (fields.size < 3 || fields[0].isBlank() || fields[1].isBlank()) return@any false
    runCatching {
        Base64.decode(fields[2], Base64.DEFAULT).isNotEmpty()
    }.getOrDefault(false)
}

internal fun firstValidatedQrDownloadSource(
    candidates: Iterable<Pair<String?, String?>>,
    detectProtocol: (String) -> String?,
): String? {
    // 作者: long
    // 一帧可能同时包含多个二维码；逐个尝试 raw/display 值，避免普通文本二维码排在前面时
    // 把后面的真实下载链接误判为无效。长度和协议校验都在纯函数内完成，便于 JVM 单测覆盖。
    candidates.forEach { (rawValue, displayValue) ->
        sequenceOf(rawValue, displayValue)
            .mapNotNull { it?.trim() }
            .filter { it.isNotEmpty() && it.length <= 8192 }
            .distinct()
            .forEach { candidate ->
                if (detectProtocol(candidate)?.let { it != "unknown" } == true) return candidate
            }
    }
    return null
}

internal fun torrentRetryOutputPath(taskOutputPath: String, persistedSafTarget: String?): String {
    // 作者: long
    // SAF 任务在 Rust 中使用私有暂存目录，重试时必须恢复用户授权的 content URI；
    // 偏好损坏或被清空时才回退到队列快照里的路径，避免把空值误当成可写目录。
    return persistedSafTarget
        ?.trim()
        ?.takeIf { it.startsWith("content://") }
        ?: taskOutputPath
}
