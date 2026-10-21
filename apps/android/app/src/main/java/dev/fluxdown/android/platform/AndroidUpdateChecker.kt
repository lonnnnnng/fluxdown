package dev.fluxdown.android.platform

import android.content.Context
import android.content.Intent
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import dev.fluxdown.android.ui.i18n.Str
import dev.fluxdown.android.ui.i18n.trApp

/**
 * 作者: long
 * 更新检查只读取 GitHub Releases 的公开接口，不引入额外依赖；版本比较与网络请求分离，
 * 让版本号规则可以脱离设备在 JVM 单测里覆盖。
 */
internal object AndroidUpdateChecker {
    private const val LATEST_RELEASE_URL = "https://api.github.com/repos/lonnnnnng/fluxdown/releases/latest"
    private const val FALLBACK_RELEASE_URL = "https://github.com/lonnnnnng/fluxdown/releases/latest"
    private const val TIMEOUT_MS = 15_000

    fun fetchLatest(currentVersion: String): AndroidUpdateReport {
        val connection = (URL(LATEST_RELEASE_URL).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = TIMEOUT_MS
            readTimeout = TIMEOUT_MS
            setRequestProperty("Accept", "application/vnd.github+json")
            setRequestProperty("User-Agent", "FluxDown-Kotlin")
        }
        return try {
            if (connection.responseCode !in 200..299) error(trApp(Str.UpdateServerError, connection.responseCode))
            val root = JSONObject(connection.inputStream.bufferedReader().use { reader -> reader.readText() })
            val latest = normalizeVersion(root.optString("tag_name"))
            require(latest.isNotBlank()) { trApp(Str.UpdateMissingVersion) }
            val current = normalizeVersion(currentVersion)
            AndroidUpdateReport(
                currentVersion = current,
                latestVersion = latest,
                hasUpdate = compareVersions(latest, current) > 0,
                releaseUrl = root.optString("html_url").ifBlank { FALLBACK_RELEASE_URL },
                downloadUrl = firstApkUrl(root.optJSONArray("assets") ?: JSONArray()),
                releaseNotes = root.optString("body").ifBlank { null },
            )
        } finally {
            connection.disconnect()
        }
    }

    fun openUrl(context: Context, url: String) {
        context.startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    /** 只接受 https 的 apk 直链，避免把明文下载地址当成可安装包推给用户。 */
    private fun firstApkUrl(assets: JSONArray): String? = buildList {
        for (index in 0 until assets.length()) {
            val asset = assets.optJSONObject(index) ?: continue
            val name = asset.optString("name")
            val url = asset.optString("browser_download_url")
            if (name.endsWith(".apk", ignoreCase = true) && url.startsWith("https://")) add(url)
        }
    }.firstOrNull()
}

/** 去掉 v 前缀与 -alpha.6 / +build 之类的后缀，只保留主干版本号。 */
internal fun normalizeVersion(value: String): String =
    value.trim().removePrefix("v").substringBefore("-").substringBefore("+")

/** 按数字段逐位比较，缺失的段按 0 处理，因此 1.0.28 与 1.0.28.0 视为相同版本。 */
internal fun compareVersions(left: String, right: String): Int {
    val a = Regex("\\d+").findAll(left).map { it.value.toInt() }.toList()
    val b = Regex("\\d+").findAll(right).map { it.value.toInt() }.toList()
    for (index in 0 until maxOf(a.size, b.size)) {
        val diff = (a.getOrNull(index) ?: 0).compareTo(b.getOrNull(index) ?: 0)
        if (diff != 0) return diff
    }
    return 0
}
