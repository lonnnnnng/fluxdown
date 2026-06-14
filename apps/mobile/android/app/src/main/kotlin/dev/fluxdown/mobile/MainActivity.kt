package dev.fluxdown.mobile

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.StatFs
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.fluxdown.mobile/storage"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getStorageStats" -> {
                    val requestedPath = call.argument<String>("path") ?: filesDir.absolutePath
                    val target = resolveExistingPath(File(requestedPath))
                    try {
                        val stat = StatFs(target.absolutePath)
                        val totalBytes = stat.blockCountLong * stat.blockSizeLong
                        val freeBytes = stat.availableBlocksLong * stat.blockSizeLong
                        result.success(
                            mapOf(
                                "totalBytes" to totalBytes,
                                "freeBytes" to freeBytes
                            )
                        )
                    } catch (error: Exception) {
                        result.error("storage_stats_failed", error.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.fluxdown.mobile/media"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "remuxTsToMp4" -> {
                    val sourcePath = call.argument<String>("sourcePath")
                    val outputPath = call.argument<String>("outputPath")
                    if (sourcePath.isNullOrBlank() || outputPath.isNullOrBlank()) {
                        result.error("invalid_arguments", "sourcePath and outputPath are required", null)
                        return@setMethodCallHandler
                    }

                    Thread {
                        try {
                            val outputBytes = remuxTsToMp4(File(sourcePath), File(outputPath))
                            mainHandler.post {
                                result.success(mapOf("outputBytes" to outputBytes))
                            }
                        } catch (error: Exception) {
                            mainHandler.post {
                                result.error("remux_failed", error.message, null)
                            }
                        }
                    }.start()
                    return@setMethodCallHandler
                }

                else -> result.notImplemented()
            }
        }
    }

    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    private fun resolveExistingPath(file: File): File {
        var current: File? = file
        while (current != null && !current.exists()) {
            current = current.parentFile
        }
        return current ?: filesDir
    }

    private fun remuxTsToMp4(source: File, output: File): Long {
        if (!source.exists() || source.length() <= 0L) {
            throw IllegalArgumentException("Source TS file does not exist or is empty")
        }

        output.parentFile?.mkdirs()
        val tempOutput = File(output.parentFile ?: filesDir, "${output.name}.tmp")
        if (tempOutput.exists()) {
            tempOutput.delete()
        }

        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        var muxerStarted = false

        try {
            extractor.setDataSource(source.absolutePath)
            muxer = MediaMuxer(tempOutput.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

            val trackMap = mutableMapOf<Int, Int>()
            var maxInputSize = 1024 * 1024
            for (trackIndex in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(trackIndex)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith("video/") && !mime.startsWith("audio/")) {
                    continue
                }
                val outputTrackIndex = muxer.addTrack(format)
                trackMap[trackIndex] = outputTrackIndex
                extractor.selectTrack(trackIndex)
                if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                    maxInputSize = maxOf(maxInputSize, format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE))
                }
            }

            if (trackMap.isEmpty()) {
                throw IllegalStateException("No audio or video tracks were found in the TS file")
            }

            muxer.start()
            muxerStarted = true

            val buffer = ByteBuffer.allocateDirect(maxInputSize)
            val bufferInfo = MediaCodec.BufferInfo()
            while (true) {
                buffer.clear()
                val sampleSize = extractor.readSampleData(buffer, 0)
                if (sampleSize < 0) {
                    break
                }

                val inputTrackIndex = extractor.sampleTrackIndex
                val outputTrackIndex = trackMap[inputTrackIndex]
                if (sampleSize > 0 && outputTrackIndex != null) {
                    bufferInfo.set(
                        0,
                        sampleSize,
                        extractor.sampleTime.coerceAtLeast(0L),
                        extractor.sampleFlags
                    )
                    muxer.writeSampleData(outputTrackIndex, buffer, bufferInfo)
                }
                if (!extractor.advance()) {
                    break
                }
            }

            if (output.exists()) {
                output.delete()
            }
            if (!tempOutput.renameTo(output)) {
                tempOutput.copyTo(output, overwrite = true)
                tempOutput.delete()
            }
            return output.length()
        } finally {
            if (muxerStarted) {
                closeQuietly { muxer?.stop() }
            }
            closeQuietly { muxer?.release() }
            closeQuietly { extractor.release() }
            if (tempOutput.exists()) {
                tempOutput.delete()
            }
        }
    }

    private fun closeQuietly(action: () -> Unit) {
        try {
            action()
        } catch (_: Exception) {
        }
    }
}
