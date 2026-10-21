package dev.fluxdown.android.data

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import dev.fluxdown.android.ui.i18n.Str
import dev.fluxdown.android.ui.i18n.trApp

/**
 * 作者: long
 * Rust 队列快照 / FFI 信封的纯解析层。全部是纯函数（除 HLS 转封装探测会读文件时间戳），
 * 便于在 JVM 单测里直接覆盖，不依赖 Android 框架。
 */

internal fun parseTasks(envelope: String): List<QueueTask> = runCatching {
    val root = JSONObject(envelope)
    val data = root.optJSONArray("data") ?: JSONArray()
    buildList {
        for (index in 0 until data.length()) {
            val task = data.optJSONObject(index) ?: continue
            val total = if (task.isNull("total_bytes")) null else task.optLong("total_bytes", 0L)
            val rawFileName = task.optString("file_name").ifBlank { task.optString("source") }
            val rawOutputDir = task.optString("output_dir").ifBlank { task.optString("outputDir") }
            val rawSource = task.optString("source")
            val rawKeepTs = task.optBoolean("hls_keep_transport_stream", false)
            val hlsRemuxedToMp4 = if (
                rawSource.substringBefore('?').substringBefore('#').endsWith(".m3u8", ignoreCase = true) &&
                !rawKeepTs &&
                rawFileName.endsWith(".ts", ignoreCase = true)
            ) {
                val transport = File(rawOutputDir, rawFileName)
                val mp4 = File(rawOutputDir, rawFileName.dropLast(3) + ".mp4")
                // 作者: long
                // 多个 HLS 任务可能共用保存目录和文件名；只有 MP4 比当前 TS 更新，
                // 或 TS 已被删除且 MP4 仍存在时，才把它认作本任务的转封装结果。
                mp4.isFile && (!transport.isFile || mp4.lastModified() >= transport.lastModified())
            } else {
                false
            }
            val torrentFiles = parseTorrentFiles(task.optJSONArray("torrent_files"))
            val torrentFileIndices = parseTorrentIndices(task.optJSONArray("torrent_file_indices"))
            val selectedTorrentFiles = torrentFiles.filter { file ->
                torrentFileIndices.isNotEmpty() && file.index in torrentFileIndices
            }
            // 作者: long
            // 队列卡片只统计用户确认过的 Torrent/Magnet 文件；Rust 新版本会直接写入选中进度，
            // 这里再按 metadata 做一次兼容收口，避免旧队列把未选择文件混进总量。
            val displayTotal = selectedTorrentFiles
                .takeIf { it.isNotEmpty() }
                ?.sumOf { it.size }
                ?: total
            val rawDownloaded = task.optLong("downloaded_bytes", 0L)
            val displayDownloaded = selectedTorrentFiles
                .takeIf { it.isNotEmpty() }
                ?.let { files ->
                    val fileProgress = files.mapNotNull { it.progressBytes }
                    when {
                        task.optString("state") == "finished" -> files.sumOf { it.size }
                        fileProgress.isNotEmpty() -> fileProgress.sum().coerceAtMost(files.sumOf { it.size })
                        else -> rawDownloaded.coerceAtMost(files.sumOf { it.size })
                    }
                }
                ?: rawDownloaded
            add(
                QueueTask(
                    id = task.optString("id"),
                    name = rawFileName,
                    source = rawSource,
                    state = task.optString("state", "queued"),
                    downloadedBytes = displayDownloaded,
                    totalBytes = displayTotal,
                    speedBytesPerSecond = task.optLong("current_speed_bytes_per_second", 0L),
                    hlsSegmentsWritten = task.optNullableInt("hls_segments_written", "hlsSegmentsWritten"),
                    hlsSegmentsTotal = task.optNullableInt("hls_segments_total", "hlsSegmentsTotal"),
                    startedAtMs = task.optNullableLong("started_at_ms", "startedAtMs"),
                    finishedAtMs = task.optNullableLong("finished_at_ms", "finishedAtMs"),
                    error = task.optNullableString("error"),
                    outputDir = rawOutputDir,
                    torrentName = task.optNullableString("torrent_name", "torrentName"),
                    torrentFiles = torrentFiles,
                    torrentFileIndices = torrentFileIndices,
                    hlsVariantIndex = if (task.isNull("hls_variant_index")) null else task.optInt("hls_variant_index", -1).takeIf { it >= 0 },
                    hlsKeepTransportStream = rawKeepTs,
                    hlsRemuxedToMp4 = hlsRemuxedToMp4,
                    credentialRef = task.optNullableString("credential_ref", "credentialRef"),
                ),
            )
        }
    }
}.getOrDefault(emptyList())

internal fun parseTorrentFiles(filesJson: JSONArray?): List<TorrentFileSelection> {
    if (filesJson == null) return emptyList()
    return buildList {
        for (index in 0 until filesJson.length()) {
            val file = filesJson.optJSONObject(index) ?: continue
            val progress = if (file.isNull("progress_bytes")) null else file.optLong("progress_bytes", 0L)
            add(
                TorrentFileSelection(
                    index = file.optInt("index", index),
                    path = file.optString("path").ifBlank { file.optString("name") },
                    name = file.optString("name").ifBlank { file.optString("path") },
                    size = file.optLong("size", 0L),
                    isStreamable = file.optBoolean("is_streamable", file.optBoolean("isStreamable", false)),
                    progressBytes = progress,
                ),
            )
        }
    }
}

internal fun JSONObject.optNullableLong(vararg keys: String): Long? {
    for (key in keys) {
        if (!isNull(key) && has(key)) {
            optLong(key, 0L).takeIf { it > 0L }?.let { return it }
        }
    }
    return null
}

internal fun JSONObject.optNullableInt(vararg keys: String): Int? {
    for (key in keys) {
        if (!isNull(key) && has(key)) {
            optInt(key, -1).takeIf { it >= 0 }?.let { return it }
        }
    }
    return null
}

/**
 * 作者: long
 * org.json 的 optString 会把 JSON null 读成字面量 "null"，直接展示会在属性面板里出现 "null" 文本。
 * 这里统一把 null / 空串 / 字面量 "null" 归一成 Kotlin null。
 */
internal fun JSONObject.optNullableString(vararg keys: String): String? {
    for (key in keys) {
        if (!has(key) || isNull(key)) continue
        val value = optString(key).trim()
        if (value.isEmpty() || value.equals("null", ignoreCase = true)) continue
        return value
    }
    return null
}

internal fun parseTorrentIndices(indices: JSONArray?): Set<Int> {
    if (indices == null) return emptySet()
    return buildSet {
        for (index in 0 until indices.length()) {
            indices.optInt(index, -1).takeIf { it >= 0 }?.let(::add)
        }
    }
}

internal fun parseError(envelope: String): String? = runCatching {
    val root = JSONObject(envelope)
    if (root.optBoolean("ok", false)) null else root.optString("error").ifBlank { trApp(Str.RustUnknownError) }
}.getOrNull()

internal fun parseDataString(envelope: String, key: String): String? = runCatching {
    val root = JSONObject(envelope)
    if (!root.optBoolean("ok", false)) return@runCatching null
    root.optJSONObject("data")?.optString(key)?.takeIf { it.isNotBlank() }
}.getOrNull()

internal fun parseHlsVariants(envelope: String): List<HlsVariantOption> = runCatching {
    val root = JSONObject(envelope)
    if (!root.optBoolean("ok", false)) return@runCatching emptyList()
    val data = root.optJSONArray("data") ?: return@runCatching emptyList()
    buildList {
        for (index in 0 until data.length()) {
            val item = data.optJSONObject(index) ?: continue
            add(
                HlsVariantOption(
                    index = item.optInt("index", index),
                    bandwidth = item.optLong("bandwidth", 0L),
                    averageBandwidth = if (item.isNull("average_bandwidth")) null else item.optLong("average_bandwidth", 0L),
                    codecs = item.optString("codecs").takeUnless { it.isBlank() || it.equals("null", ignoreCase = true) },
                    resolution = item.optString("resolution").takeUnless { it.isBlank() || it.equals("null", ignoreCase = true) },
                    frameRate = if (item.isNull("frame_rate")) null else item.optDouble("frame_rate", 0.0),
                ),
            )
        }
    }
}.getOrDefault(emptyList())

internal fun parseTorrentSelection(
    envelope: String,
    source: String,
    requestedFileName: String,
    outputPath: String,
    onConfirmed: (() -> Unit)? = null,
    replaceTaskId: String? = null,
): TorrentSelection? = runCatching {
    val root = JSONObject(envelope)
    val report = root.optJSONObject("data")?.optJSONObject("report") ?: return@runCatching null
    val filesJson = report.optJSONArray("files") ?: return@runCatching null
    val files = parseTorrentFiles(filesJson)
    val rawInfoHash = report.opt("info_hash")
    val infoHash = rawInfoHash
        ?.takeIf { it != JSONObject.NULL }
        ?.toString()
        ?.trim()
        ?.takeIf { it.isNotEmpty() && !it.equals("null", ignoreCase = true) }
    TorrentSelection(
        source = source,
        requestedFileName = requestedFileName,
        outputPath = outputPath,
        directoryName = report.optString("name").ifBlank { trApp(Str.TorrentResource) },
        files = files,
        infoHash = infoHash,
        onConfirmed = onConfirmed,
        replaceTaskId = replaceTaskId,
    )
}.getOrNull()
