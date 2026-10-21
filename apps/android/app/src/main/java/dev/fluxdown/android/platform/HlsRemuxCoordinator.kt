package dev.fluxdown.android.platform

import android.util.Log
import dev.fluxdown.android.AndroidHlsRemuxer
import dev.fluxdown.android.data.QueueTask
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import dev.fluxdown.android.ui.i18n.Str
import dev.fluxdown.android.ui.i18n.trApp

/**
 * 作者: long
 * Android arm64 包不携带 ffmpeg，传统 HLS 由 Rust 保留为 TS 后在这里尝试系统级转封装；
 * 只有实际生成非空 MP4 后才把 TS 删除，失败路径继续保留可播放的原始 TS。
 */
internal class HlsRemuxCoordinator {
    private val inFlight = ConcurrentHashMap.newKeySet<String>()

    /** 对已完成但仍为 TS 的 HLS 任务做一次转封装；同一任务不会并发重复处理。 */
    suspend fun process(tasks: List<QueueTask>) {
        tasks.filter { task ->
            task.state == "finished" &&
                task.source.substringBefore('?').substringBefore('#').endsWith(".m3u8", ignoreCase = true) &&
                !task.hlsKeepTransportStream &&
                !task.hlsRemuxedToMp4
        }.forEach { task ->
            if (!inFlight.add(task.id)) return@forEach
            try {
                val source = File(task.outputDir, task.name)
                if (!source.isFile || !source.name.endsWith(".ts", ignoreCase = true)) return@forEach
                val target = File(source.parentFile, source.name.dropLast(3) + ".mp4")
                val result = withContext(Dispatchers.IO) {
                    AndroidHlsRemuxer.remuxTransportStream(source, target)
                }
                if (result.isSuccess && target.isFile && target.length() > 0L) {
                    runCatching { source.delete() }
                } else {
                    Log.w("FluxDownHlsRemux", trApp(Str.RemuxFailed, result.exceptionOrNull()?.message ?: trApp(Str.UnknownError)))
                }
            } finally {
                inFlight.remove(task.id)
            }
        }
    }
}
