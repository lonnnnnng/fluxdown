package dev.fluxdown.android

import android.content.Intent
import androidx.core.content.ContextCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.fluxdown.android.core.RustCoreBridge
import java.io.BufferedInputStream
import java.io.File
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Kotlin -> JNI -> Rust 队列的最小真机闭环。
 *
 * 作者: long
 * 这组用例使用设备回环 HTTP 服务，不依赖公网资源；因此能稳定保护入队、异步运行、
 * 断点续传和 416 回退等核心迁移边界，而不是只验证按钮能否点击。
 */
@RunWith(AndroidJUnit4::class)
class RustQueueInstrumentationTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun queueDownloadsLoopbackHttpThroughRust() {
        val payload = "kotlin-rust-real-download".toByteArray()
        val server = LoopbackHttpServer(payload, rejectFirstRange = false)
        try {
            val result = runQueueTask(server.url, payload, staleBytes = null)
            assertEquals("finished", result.state)
            assertEquals(payload.size.toLong(), result.downloadedBytes)
            assertEquals(payload.toList(), result.outputBytes.toList())
        } finally {
            server.close()
        }
    }

    @Test
    fun queueRetriesStalePartialAfterHttp416ThroughRust() {
        val payload = "fresh-kotlin-rust-payload".toByteArray()
        val server = LoopbackHttpServer(payload, rejectFirstRange = true)
        try {
            val result = runQueueTask(server.url, payload, staleBytes = payload + "-stale".toByteArray())
            assertEquals("finished", result.state)
            assertEquals(payload.toList(), result.outputBytes.toList())
            assertTrue("应先收到一次带 Range 的 416", server.rangeRequests.await(2, TimeUnit.SECONDS))
        } finally {
            server.close()
        }
    }

    @Test
    fun queueRetriesTransientHttpFailureThroughRust() {
        val payload = "retry-through-kotlin-rust".toByteArray()
        val server = LoopbackHttpServer(payload, rejectFirstRange = false, transientFailures = 2)
        try {
            // 作者: long
            // 让回环服务前两次返回 503，验证设置透传的重试次数真的由 Rust runner 执行，
            // 而不是 Kotlin 在 UI 层把失败任务伪装成完成。
            val result = runQueueTask(server.url, payload, staleBytes = null, retryAttempts = 2)
            assertEquals("finished", result.state)
            assertEquals(payload.toList(), result.outputBytes.toList())
            assertEquals("应包含两次 503 和一次成功请求", 3, server.requestCount.get())
        } finally {
            server.close()
        }
    }

    @Test
    fun foregroundServiceRunsRustQueueThroughLoopbackHttp() {
        val payload = "foreground-service-rust-download".toByteArray()
        val server = LoopbackHttpServer(payload, rejectFirstRange = false)
        val root = File(context.cacheDir, "rust-service-${UUID.randomUUID()}").apply { mkdirs() }
        val store = File(root, "queue.json")
        val output = File(root, "downloads").apply { mkdirs() }
        val file = File(output, "service.bin")
        val settings = context.getSharedPreferences("fluxdown.kotlin.settings", 0)
        val previousThreads = settings.getString("threads", null)
        val previousConcurrency = settings.getString("concurrency", null)
        val previousRetries = settings.getString("retries", null)
        try {
            // 作者: long
            // 这个 fixture 只实现单连接 HTTP；把服务参数收窄到单线程，专门验证 runner 已由 Service 接管。
            settings.edit()
                .putString("threads", "1")
                .putString("concurrency", "1")
                .putString("retries", "0")
                .commit()
            val add = RustCoreBridge.queueAdd(
                store.absolutePath,
                JSONObject()
                    .put("source", server.url)
                    .put("outputDir", output.absolutePath)
                    .put("fileName", file.name)
                    .toString(),
            )
            assertTrue("服务测试入队失败: $add", parseOk(add))
            val serviceIntent = Intent(context, DownloadForegroundService::class.java).apply {
                action = DownloadForegroundService.ACTION_START
                putExtra(DownloadForegroundService.EXTRA_STORE_PATH, store.absolutePath)
            }
            ContextCompat.startForegroundService(context, serviceIntent)

            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
            var state = "queued"
            var finalTask = JSONObject()
            while (System.nanoTime() < deadline && state != "finished" && state != "failed") {
                finalTask = queueTask(
                    RustCoreBridge.queueList(store.absolutePath),
                    JSONObject(add).getJSONObject("data").getString("id"),
                )
                state = finalTask.optString("state", "unknown")
                if (state != "finished" && state != "failed") Thread.sleep(200)
            }
            assertTrue("服务任务失败: $finalTask", state == "finished")
            assertEquals(payload.toList(), file.readBytes().toList())
        } finally {
            context.stopService(Intent(context, DownloadForegroundService::class.java))
            settings.edit().apply {
                if (previousThreads == null) remove("threads") else putString("threads", previousThreads)
                if (previousConcurrency == null) remove("concurrency") else putString("concurrency", previousConcurrency)
                if (previousRetries == null) remove("retries") else putString("retries", previousRetries)
            }.commit()
            server.close()
            root.deleteRecursively()
        }
    }

    private fun runQueueTask(
        url: String,
        payload: ByteArray,
        staleBytes: ByteArray?,
        retryAttempts: Int = 0,
    ): QueueResult {
        val root = File(context.cacheDir, "rust-queue-${UUID.randomUUID()}").apply { mkdirs() }
        val store = File(root, "queue.json")
        val output = File(root, "downloads").apply { mkdirs() }
        val file = File(output, "fixture.bin")
        staleBytes?.let { file.writeBytes(it) }

        val add = RustCoreBridge.queueAdd(
            store.absolutePath,
            JSONObject()
                .put("source", url)
                .put("outputDir", output.absolutePath)
                .put("fileName", file.name)
                .toString(),
        )
        assertTrue("入队失败: ${RustCoreBridge.loadError ?: add}", parseOk(add))
        val taskId = JSONObject(add).getJSONObject("data").getString("id")
        val run = RustCoreBridge.queueRunQueued(
            store.absolutePath,
            JSONObject()
                .put("concurrency", 1)
                .put("threadCount", 1)
                .put("retryAttempts", retryAttempts)
                .toString(),
        )
        assertTrue("启动 Rust 队列失败: $run", parseOk(run))
        val runId = JSONObject(run).getJSONObject("data").getString("runId")

        var state = "running"
        var task = JSONObject()
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
        while (System.nanoTime() < deadline && state == "running") {
            task = queueTask(RustCoreBridge.queueList(store.absolutePath), taskId)
            state = task.optString("state", "unknown")
            if (state == "running" || state == "queued") Thread.sleep(150)
        }
        while (parseState(RustCoreBridge.queueRunStatus(runId)) == "running" && System.nanoTime() < deadline) {
            Thread.sleep(150)
        }
        RustCoreBridge.queueRunForget(runId)
        val finalTask = queueTask(RustCoreBridge.queueList(store.absolutePath), taskId)
        assertEquals("finished", finalTask.optString("state"))
        assertTrue("队列任务应在 30 秒内结束", System.nanoTime() < deadline)
        val outputBytes = file.readBytes()
        root.deleteRecursively()
        return QueueResult(
            state = finalTask.optString("state"),
            downloadedBytes = finalTask.optLong("downloaded_bytes"),
            outputBytes = outputBytes,
        )
    }

    private fun parseOk(envelope: String): Boolean = JSONObject(envelope).optBoolean("ok", false)

    private fun parseState(envelope: String): String =
        JSONObject(envelope).optJSONObject("data")?.optString("state").orEmpty()

    private fun queueTask(envelope: String, id: String): JSONObject {
        val tasks = JSONObject(envelope).optJSONArray("data") ?: JSONArray()
        for (index in 0 until tasks.length()) {
            val task = tasks.optJSONObject(index) ?: continue
            if (task.optString("id") == id) return task
        }
        return JSONObject()
    }

    private data class QueueResult(
        val state: String,
        val downloadedBytes: Long,
        val outputBytes: ByteArray,
    )

    private class LoopbackHttpServer(
        private val payload: ByteArray,
        private val rejectFirstRange: Boolean,
        transientFailures: Int = 0,
    ) : AutoCloseable {
        private val server = ServerSocket(0, 4, java.net.InetAddress.getByName("127.0.0.1"))
        private val thread = Thread(::serve, "fluxdown-android-test-http")
        val url = "http://127.0.0.1:${server.localPort}/fixture.bin"
        val rangeRequests = CountDownLatch(1)
        val requestCount = AtomicInteger(0)
        private val transientFailuresRemaining = AtomicInteger(transientFailures)
        @Volatile
        private var rangeRejected = false

        init {
            thread.start()
        }

        private fun serve() {
            while (!server.isClosed) {
                runCatching { server.accept() }.getOrNull()?.let { socket ->
                    Thread({ respond(socket) }, "fluxdown-android-test-http-client").start()
                }
            }
        }

        private fun respond(socket: Socket) {
            socket.use { client ->
                val request = BufferedInputStream(client.getInputStream())
                val bytes = buildString {
                    var previous = -1
                    var current: Int
                    while (request.read().also { current = it } >= 0) {
                        append(current.toChar())
                        if (previous == '\r'.code && current == '\n'.code && endsWith("\r\n\r\n")) break
                        previous = current
                    }
                }
                requestCount.incrementAndGet()
                val hasRange = bytes.lineSequence().any { it.startsWith("Range:", ignoreCase = true) }
                if (hasRange && rejectFirstRange && !rangeRejected) {
                    rangeRejected = true
                    rangeRequests.countDown()
                    val writer = client.getOutputStream().bufferedWriter()
                    writer.write("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */${payload.size}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                    writer.flush()
                    return
                }
                if (hasRange) rangeRequests.countDown()
                val writer = client.getOutputStream().bufferedWriter()
                if (transientFailuresRemaining.getAndUpdate { remaining -> (remaining - 1).coerceAtLeast(0) } > 0) {
                    writer.write("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                    writer.flush()
                    return
                }
                writer.write("HTTP/1.1 200 OK\r\nContent-Length: ${payload.size}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n")
                writer.flush()
                client.getOutputStream().write(payload)
                client.getOutputStream().flush()
            }
        }

        override fun close() {
            server.close()
            thread.join(2000)
        }
    }
}
