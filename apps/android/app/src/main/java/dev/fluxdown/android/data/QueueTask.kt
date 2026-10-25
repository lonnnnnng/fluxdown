package dev.fluxdown.android.data

import dev.fluxdown.android.ui.i18n.Str
import dev.fluxdown.android.ui.i18n.trApp

/**
 * 作者: long
 * 队列任务的 UI 投影。字段与 Rust 队列快照一一对应，Kotlin 侧只做展示所需的派生，
 * 不复制下载状态机；所有状态判断仍以 Rust 写入的 `state` 为准。
 */
internal data class QueueTask(
    val id: String,
    val name: String,
    val source: String,
    val state: String,
    val downloadedBytes: Long,
    val totalBytes: Long?,
    val speedBytesPerSecond: Long,
    val hlsSegmentsWritten: Int?,
    val hlsSegmentsTotal: Int?,
    val startedAtMs: Long?,
    val finishedAtMs: Long?,
    val error: String?,
    /** Rust 写入的稳定错误码；旧队列或未分类错误为 null，界面回退展示 [error]。 */
    val errorCode: String? = null,
    val outputDir: String,
    val torrentName: String?,
    val torrentFiles: List<TorrentFileSelection>,
    val torrentFileIndices: Set<Int>,
    val hlsVariantIndex: Int?,
    /** 用户显式选定的 HLS 音轨下标（EXT-X-MEDIA 音频列表下标）；null 表示不下载额外音轨。 */
    val hlsAudioIndex: Int? = null,
    /** 音轨落盘路径；仅当选定音轨且下载成功时有值。 */
    val hlsAudioPath: String? = null,
    val hlsKeepTransportStream: Boolean,
    val hlsRemuxedToMp4: Boolean,
    val credentialRef: String?,
) {
    // 作者: long
    // Torrent/Magnet 是目录型资源，列表入口应展示 metadata 根目录；具体文件留在资源详情中查看。
    val isTorrentResource: Boolean
        get() = torrentFiles.isNotEmpty() || torrentName != null

    val displayName: String
        get() = when {
            isTorrentResource -> torrentResourceDirectoryLabel(torrentName, torrentFiles.map { it.name })
            hlsRemuxedToMp4 && name.endsWith(".ts", ignoreCase = true) -> name.dropLast(3) + ".mp4"
            else -> name
        }

    val progress: Float
        get() = if (state == "finished") 1f
        else if (totalBytes == null || totalBytes <= 0) 0f
        else (downloadedBytes.toDouble() / totalBytes).coerceIn(0.0, 1.0).toFloat()

    /** 已确认的 Torrent/Magnet 文件；为空表示普通单文件任务。 */
    val selectedTorrentFiles: List<TorrentFileSelection>
        get() = if (torrentFileIndices.isEmpty()) {
            emptyList()
        } else {
            torrentFiles.filter { it.index in torrentFileIndices }
        }
}

internal fun torrentResourceDirectoryLabel(name: String?, fileNames: List<String>): String {
    val metadataName = name?.trim().orEmpty()
    if (metadataName.isEmpty()) return trApp(Str.TorrentResource)
    // 作者: long
    // 单文件种子的 metadata 名通常就是文件名；列表展示资源入口时去掉文件扩展名，
    // 文件全名、格式和大小仍在详情中，避免目录入口看起来像单个 MP4/MKV 文件。
    if (fileNames.size == 1 && metadataName.equals(fileNames[0], ignoreCase = true)) {
        return metadataName.substringBeforeLast('.', metadataName).ifBlank { metadataName }
    }
    return metadataName
}

internal data class TorrentFileSelection(
    val index: Int,
    val path: String,
    val name: String,
    val size: Long,
    val isStreamable: Boolean,
    val progressBytes: Long? = null,
)

internal data class TorrentSelection(
    val source: String,
    val requestedFileName: String,
    val outputPath: String,
    val directoryName: String,
    val files: List<TorrentFileSelection>,
    val infoHash: String?,
    val onConfirmed: (() -> Unit)? = null,
    val replaceTaskId: String? = null,
)

internal data class HlsVariantOption(
    val index: Int,
    val bandwidth: Long,
    val averageBandwidth: Long?,
    val codecs: String?,
    val resolution: String?,
    val frameRate: Double?,
)

/**
 * 作者: long
 * HLS master playlist 里 EXT-X-MEDIA 声明的音轨。
 * 移动端没有 ffmpeg，无法把音轨与视频混流，所以选定后单独落盘为独立文件；
 * [index] 是音频子列表下标（与 Rust `hls_audio_renditions` 一致），不是全量 EXT-X-MEDIA 下标。
 */
internal data class HlsAudioOption(
    val index: Int,
    val groupId: String,
    val name: String,
    val language: String?,
    val isDefault: Boolean,
    val channels: String?,
)
