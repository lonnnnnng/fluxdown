package dev.fluxdown.android

import android.content.Context
import android.media.MediaExtractor
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.FileOutputStream
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidHlsRemuxerTest {
    private val context: Context
        get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val testContext: Context
        get() = InstrumentationRegistry.getInstrumentation().context

    @Test
    fun remuxesDualTrackTransportStreamIntoPlayableMp4() {
        val source = copyFixtureToCache("dual_track.ts")
        val target = File(context.cacheDir, "dual-track-${System.nanoTime()}.mp4")

        val result = AndroidHlsRemuxer.remuxTransportStream(source, target)

        assertTrue("双轨 TS 应能被 Android 媒体栈转封装", result.isSuccess)
        assertTrue("MP4 输出不能为空", target.isFile && target.length() > 0L)
        assertTrackCounts(target, expectedAudioTracks = 1, expectedVideoTracks = 1)
        source.delete()
        target.delete()
    }

    @Test
    fun remuxesLongerBFrameTransportStreamWithAvailableAudioTrack() {
        val source = copyFixtureToCache("complex_multi_audio.ts")
        val target = File(context.cacheDir, "complex-${System.nanoTime()}.mp4")

        val result = AndroidHlsRemuxer.remuxTransportStream(source, target)

        assertTrue("包含 B 帧和多音频源的 TS 应能转封装", result.isSuccess)
        assertTrue("复杂媒体 MP4 输出不能为空", target.isFile && target.length() > 0L)
        val sourceTracks = trackCounts(source)
        val outputTracks = trackCounts(target)
        Log.i("FluxDownHlsTest", "complex source tracks=$sourceTracks output tracks=$outputTracks")
        // Android MediaExtractor 在当前 Redmi 媒体栈上只暴露同一 MPEG-TS program 的一条音频轨；
        // 这里验证转封装不会丢失它能解析到的轨道，第二音轨的选择属于后续 HLS rendition 能力。
        assertTrue("Android 源 TS 应暴露视频和至少一条音频轨，实际为 $sourceTracks", sourceTracks == (1 to 1))
        assertTrue("输出应保留 Android 源 TS 暴露的音视频轨，实际为 $outputTracks", outputTracks == sourceTracks)
        source.delete()
        target.delete()
    }

    @Test
    fun remuxesAudioOnlyTransportStream() {
        val source = copyFixtureToCache("audio_only.ts")
        val target = File(context.cacheDir, "audio-only-${System.nanoTime()}.mp4")

        val result = AndroidHlsRemuxer.remuxTransportStream(source, target)

        assertTrue("仅音频 TS 应能转封装", result.isSuccess)
        assertTrackCounts(target, expectedAudioTracks = 1, expectedVideoTracks = 0)
        source.delete()
        target.delete()
    }

    @Test
    fun remuxesVideoOnlyTransportStream() {
        val source = copyFixtureToCache("video_only.ts")
        val target = File(context.cacheDir, "video-only-${System.nanoTime()}.mp4")

        val result = AndroidHlsRemuxer.remuxTransportStream(source, target)

        assertTrue("仅视频 TS 应能转封装", result.isSuccess)
        assertTrackCounts(target, expectedAudioTracks = 0, expectedVideoTracks = 1)
        source.delete()
        target.delete()
    }

    @Test
    fun rejectsEmptyTransportStreamAndDoesNotLeaveTarget() {
        val source = File(context.cacheDir, "empty-${System.nanoTime()}.ts")
        val target = File(context.cacheDir, "empty-${System.nanoTime()}.mp4")
        source.createNewFile()

        val result = AndroidHlsRemuxer.remuxTransportStream(source, target)

        assertTrue("空 TS 必须失败", result.isFailure)
        assertFalse("失败时不能留下空 MP4", target.exists())
        source.delete()
    }

    @Test
    fun rejectsCorruptedTransportStreamAndKeepsSourceForRetry() {
        val source = File(context.cacheDir, "corrupted-${System.nanoTime()}.ts")
        val target = File(context.cacheDir, "corrupted-${System.nanoTime()}.mp4")
        source.writeBytes(ByteArray(1024) { index -> (index % 13).toByte() })

        val result = AndroidHlsRemuxer.remuxTransportStream(source, target)

        assertTrue("损坏 TS 必须失败", result.isFailure)
        assertFalse("失败时不能留下伪 MP4", target.exists())
        assertTrue("失败后源 TS 应保留，便于用户重试", source.isFile)
        source.delete()
    }

    private fun copyFixtureToCache(name: String): File {
        val target = File(context.cacheDir, "fixture-${System.nanoTime()}-$name")
        testContext.assets.open(name).use { input ->
            FileOutputStream(target).use { output -> input.copyTo(output) }
        }
        assertNotNull(target)
        return target
    }

    private fun assertTrackCounts(file: File, expectedAudioTracks: Int, expectedVideoTracks: Int) {
        val (audioTracks, videoTracks) = trackCounts(file)
        assertTrue("MP4 音频轨数量应为 $expectedAudioTracks，实际为 $audioTracks", audioTracks == expectedAudioTracks)
        assertTrue("MP4 视频轨数量应为 $expectedVideoTracks，实际为 $videoTracks", videoTracks == expectedVideoTracks)
    }

    private fun trackCounts(file: File): Pair<Int, Int> {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(file.absolutePath)
            var audioTracks = 0
            var videoTracks = 0
            for (index in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(index)
                    .getString(android.media.MediaFormat.KEY_MIME)
                    .orEmpty()
                if (mime.startsWith("audio/")) audioTracks += 1
                if (mime.startsWith("video/")) videoTracks += 1
            }
            return audioTracks to videoTracks
        } finally {
            extractor.release()
        }
    }
}
