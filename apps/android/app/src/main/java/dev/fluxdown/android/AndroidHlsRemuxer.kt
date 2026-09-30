package dev.fluxdown.android

import android.media.MediaExtractor
import android.media.MediaMuxer
import android.media.MediaCodec
import java.io.File
import java.nio.ByteBuffer

/**
 * Android 原生 TS -> MP4 轻量转封装器。
 *
 * 作者: long
 * Rust 负责下载和分片合并；Android 端只在传统 HLS 已完成、用户没有选择保留 TS 时，
 * 使用系统媒体栈复制音视频轨道。这样不引入 ffmpeg，也不会把转换失败误报成 MP4。
 */
internal object AndroidHlsRemuxer {
    private const val BUFFER_SIZE = 1024 * 1024

    fun remuxTransportStream(source: File, target: File): Result<Long> = runCatching {
        require(source.isFile && source.length() > 0L) { "TS 文件不存在或为空" }
        target.parentFile?.mkdirs()
        if (target.exists() && !target.delete()) error("无法覆盖 MP4 输出文件")

        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        var started = false
        try {
            extractor.setDataSource(source.absolutePath)
            val muxerInstance = MediaMuxer(
                target.absolutePath,
                MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4,
            )
            muxer = muxerInstance
            val trackMap = mutableMapOf<Int, Int>()
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                val mime = format.getString(android.media.MediaFormat.KEY_MIME).orEmpty()
                if (mime.startsWith("audio/") || mime.startsWith("video/")) {
                    trackMap[index] = muxerInstance.addTrack(format)
                }
            }
            require(trackMap.isNotEmpty()) { "TS 中没有可写入 MP4 的音视频轨道" }

            muxerInstance.start()
            started = true
            val buffer = ByteBuffer.allocateDirect(BUFFER_SIZE)
            val bufferInfo = MediaCodec.BufferInfo()
            trackMap.forEach { (sourceTrack, outputTrack) ->
                // 作者: long
                // MediaExtractor 的游标会随着上一条轨道读到 EOF；切换音视频轨道前必须重新定位，
                // 否则双轨 TS 可能只写入第一条轨道，生成的 MP4 会缺音频或缺视频。
                extractor.selectTrack(sourceTrack)
                extractor.seekTo(0L, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                while (true) {
                    buffer.clear()
                    val sampleSize = extractor.readSampleData(buffer, 0)
                    if (sampleSize < 0) break
                    bufferInfo.offset = 0
                    bufferInfo.size = sampleSize
                    bufferInfo.presentationTimeUs = extractor.sampleTime.coerceAtLeast(0L)
                    bufferInfo.flags = extractor.sampleFlags
                    muxerInstance.writeSampleData(outputTrack, buffer, bufferInfo)
                    extractor.advance()
                }
                extractor.unselectTrack(sourceTrack)
            }
            muxerInstance.stop()
            started = false
            require(target.isFile && target.length() > 0L) { "MP4 转封装结果为空" }
            target.length()
        } finally {
            if (started) runCatching { muxer?.stop() }
            runCatching { muxer?.release() }
            extractor.release()
        }
    }.onFailure {
        runCatching { target.delete() }
    }
}
