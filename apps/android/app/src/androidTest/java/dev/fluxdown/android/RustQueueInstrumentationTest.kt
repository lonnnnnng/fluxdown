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
import org.junit.Assume.assumeTrue
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
    fun queueDownloadsLargeHttpPayloadThroughRust() {
        val payload = ByteArray(16 * 1024 * 1024) { index -> (index * 31 % 251).toByte() }
        val server = SlowLoopbackHttpServer(payload, chunkSize = 64 * 1024, chunkDelayMs = 0)
        try {
            val result = runQueueTask(server.url, payload, staleBytes = null)
            assertEquals("finished", result.state)
            assertEquals(payload.size.toLong(), result.downloadedBytes)
            assertEquals(sha256(payload), sha256(result.outputBytes))
        } finally {
            server.close()
        }
    }

    @Test
    fun queueStreamsLongHlsPlaylistThroughRust() {
        val segmentCount = 48
        val segmentSize = 128 * 1024
        val server = HlsLoopbackHttpServer(segmentCount, segmentSize, chunkDelayMs = 2)
        val root = File(context.cacheDir, "rust-hls-stress-${UUID.randomUUID()}").apply { mkdirs() }
        val store = File(root, "queue.json")
        val output = File(root, "downloads").apply { mkdirs() }
        var runId: String? = null
        try {
            val add = RustCoreBridge.queueAdd(
                store.absolutePath,
                JSONObject()
                    .put("source", server.playlistUrl)
                    .put("outputDir", output.absolutePath)
                    .put("fileName", "long-hls.ts")
                    .put("hlsKeepTransportStream", true)
                    .toString(),
            )
            assertTrue("HLS 压力测试入队失败: $add", parseOk(add))
            val taskId = JSONObject(add).getJSONObject("data").getString("id")
            runId = startQueue(store, concurrency = 1, threadCount = 4)
            waitForTaskState(store, taskId, "finished", 60_000)
            waitForRunTerminal(runId, 60_000)
            val task = queueTask(RustCoreBridge.queueList(store.absolutePath), taskId)
            assertEquals(segmentCount.toLong() * segmentSize, task.optLong("downloaded_bytes"))
            assertEquals(segmentCount.toLong() * segmentSize, File(output, "long-hls.ts").length())
        } finally {
            runId?.let { forgetRunWhenTerminal(it) }
            server.close()
            root.deleteRecursively()
        }
    }

    @Test
    fun queueMarksTruncatedHttpResponseFailedWithoutFalseCompletion() {
        val payload = ByteArray(256 * 1024) { index -> (index % 223).toByte() }
        val server = TruncatedLoopbackHttpServer(payload, bytesToSend = payload.size / 3)
        val root = File(context.cacheDir, "rust-truncated-${UUID.randomUUID()}").apply { mkdirs() }
        val store = File(root, "queue.json")
        val output = File(root, "downloads").apply { mkdirs() }
        var runId: String? = null
        try {
            val add = RustCoreBridge.queueAdd(
                store.absolutePath,
                JSONObject()
                    .put("source", server.url)
                    .put("outputDir", output.absolutePath)
                    .put("fileName", "truncated.bin")
                    .toString(),
            )
            assertTrue("断流测试入队失败: $add", parseOk(add))
            val taskId = JSONObject(add).getJSONObject("data").getString("id")
            runId = startQueue(store, retryAttempts = 1)
            waitForRunTerminal(runId, 30_000)
            val finalTask = queueTask(RustCoreBridge.queueList(store.absolutePath), taskId)
            assertEquals("failed", finalTask.optString("state"))
            assertTrue("断流请求应至少到达服务端 count=${server.requestCount.get()} task=$finalTask", server.requestCount.get() >= 1)
            assertTrue(finalTask.optString("error").isNotBlank())
        } finally {
            runId?.let { forgetRunWhenTerminal(it) }
            server.close()
            root.deleteRecursively()
        }
    }

    @Test
    fun queueRecoversAfterMidTransferNetworkInterruptionThroughRust() {
        val payload = ByteArray(512 * 1024) { index -> (index * 13 % 251).toByte() }
        val server = RecoveringTruncatedLoopbackHttpServer(payload, bytesToSendBeforeRecovery = payload.size / 4)
        val root = File(context.cacheDir, "rust-network-recovery-${UUID.randomUUID()}").apply { mkdirs() }
        val store = File(root, "queue.json")
        val output = File(root, "downloads").apply { mkdirs() }
        var runId: String? = null
        try {
            val add = RustCoreBridge.queueAdd(
                store.absolutePath,
                JSONObject()
                    .put("source", server.url)
                    .put("outputDir", output.absolutePath)
                    .put("fileName", "network-recovery.bin")
                    .toString(),
            )
            assertTrue("网络中断恢复测试入队失败: $add", parseOk(add))
            val taskId = JSONObject(add).getJSONObject("data").getString("id")
            // 作者: long
            // 首次响应主动断开连接，第二次响应恢复完整内容；这里验证 Rust 将传输中断归类为可重试错误，
            // 而不是把部分文件误报为完成，也不是由 Kotlin UI 伪造成功状态。
            runId = startQueue(store, threadCount = 1, retryAttempts = 2)
            waitForRunTerminal(runId, 45_000)
            val finalTask = queueTask(RustCoreBridge.queueList(store.absolutePath), taskId)
            assertEquals(
                "传输中断恢复失败 count=${server.requestCount.get()} file=${File(output, "network-recovery.bin").length()} task=$finalTask",
                "finished",
                finalTask.optString("state"),
            )
            assertEquals(payload.size.toLong(), finalTask.optLong("downloaded_bytes"))
            assertEquals(payload.toList(), File(output, "network-recovery.bin").readBytes().toList())
            assertTrue("网络中断后应重新请求资源 count=${server.requestCount.get()}", server.requestCount.get() >= 2)
        } finally {
            runId?.let { forgetRunWhenTerminal(it) }
            server.close()
            root.deleteRecursively()
        }
    }

    @Test
    fun queueRecoversAfterWifiToggleThroughRust() {
        val arguments = InstrumentationRegistry.getArguments()
        val source = arguments.getString("networkFixtureUrl").orEmpty().trim()
        val expectedBytes = arguments.getString("networkFixtureBytes")?.toLongOrNull() ?: 0L
        // 作者: long
        // 系统 Wi-Fi 开关会改变真机网络状态，默认回归不主动执行；只有显式传入局域网夹具时才运行，
        // 避免把公网或未授权地址带入设备测试，也避免普通 connected suite 被网络环境拖慢。
        assumeTrue(
            "缺少 networkFixtureUrl/networkFixtureBytes，跳过 Wi-Fi 切换真机用例",
            source.startsWith("http://192.168.") && expectedBytes > 0L,
        )

        val root = File(context.cacheDir, "rust-wifi-toggle-${UUID.randomUUID()}").apply { mkdirs() }
        val store = File(root, "queue.json")
        val output = File(root, "downloads").apply { mkdirs() }
        var runId: String? = null
        try {
            val add = RustCoreBridge.queueAdd(
                store.absolutePath,
                JSONObject()
                    .put("source", source)
                    .put("outputDir", output.absolutePath)
                    .put("fileName", "wifi-toggle.bin")
                    .toString(),
            )
            assertTrue("Wi-Fi 切换测试入队失败: $add", parseOk(add))
            val taskId = JSONObject(add).getJSONObject("data").getString("id")
            runId = RustCoreBridge.queueRunQueued(
                store.absolutePath,
                JSONObject()
                    .put("concurrency", 1)
                    .put("threadCount", 1)
                    .put("retryAttempts", 6)
                    .put("speedLimitKbps", 512.0)
                    .toString(),
            ).let { envelope ->
                assertTrue("Wi-Fi 切换测试启动失败: $envelope", parseOk(envelope))
                JSONObject(envelope).getJSONObject("data").getString("runId")
            }
            waitForDownloadedBytes(store, taskId, minOf(expectedBytes / 4, 1024 * 1024L).coerceAtLeast(1L), 60_000)

            // 作者: long
            // 在已有真实进度后切断 Wi-Fi，再恢复网络；USB 调试链路仍保持可用，便于测试结束时恢复开关并读取队列。
            InstrumentationRegistry.getInstrumentation().uiAutomation
                .executeShellCommand("svc wifi disable")
                .close()
            Thread.sleep(1_000)
            InstrumentationRegistry.getInstrumentation().uiAutomation
                .executeShellCommand("svc wifi enable")
                .close()

            waitForRunTerminal(runId, 180_000)
            val finalTask = queueTask(RustCoreBridge.queueList(store.absolutePath), taskId)
            assertEquals("Wi-Fi 切换后任务未恢复: $finalTask", "finished", finalTask.optString("state"))
            assertEquals(expectedBytes, finalTask.optLong("downloaded_bytes"))
            assertEquals(expectedBytes, File(output, "wifi-toggle.bin").length())
        } finally {
            // 作者: long
            // 无论断言或设备网络路径如何失败，都把 Wi-Fi 恢复到开启状态，避免污染后续真机验收。
            InstrumentationRegistry.getInstrumentation().uiAutomation
                .executeShellCommand("svc wifi enable")
                .close()
            runId?.let { forgetRunWhenTerminal(it) }
            root.deleteRecursively()
        }
    }

    @Test
    fun queueMarksInvalidOutputPathFailed() {
        val root = File(context.cacheDir, "rust-storage-error-${UUID.randomUUID()}").apply { mkdirs() }
        val store = File(root, "queue.json")
        val outputParent = File(root, "downloads").apply { mkdirs() }
        val outputFile = File(outputParent, "not-a-directory").apply { writeText("occupied") }
        var runId: String? = null
        try {
            val add = RustCoreBridge.queueAdd(
                store.absolutePath,
                JSONObject()
                    .put("source", "http://127.0.0.1:9/storage-error.bin")
                    .put("outputDir", outputFile.absolutePath)
                    .put("fileName", "storage-error.bin")
                    .toString(),
            )
            assertTrue("存储异常测试入队失败: $add", parseOk(add))
            val taskId = JSONObject(add).getJSONObject("data").getString("id")
            runId = startQueue(store)
            waitForTaskState(store, taskId, "failed", 15_000)
            waitForRunTerminal(runId, 15_000)
            assertTrue(queueTask(RustCoreBridge.queueList(store.absolutePath), taskId).optString("error").isNotBlank())
        } finally {
            runId?.let { forgetRunWhenTerminal(it) }
            root.deleteRecursively()
        }
    }

    @Test
    fun queuePauseResumeThroughRustKeepsPartialProgress() {
        val payload = ByteArray(512 * 1024) { index -> (index % 251).toByte() }
        val server = SlowLoopbackHttpServer(payload, chunkSize = 8 * 1024, chunkDelayMs = 25)
        val root = File(context.cacheDir, "rust-pause-${UUID.randomUUID()}").apply { mkdirs() }
        val store = File(root, "queue.json")
        val output = File(root, "downloads").apply { mkdirs() }
        val file = File(output, "pause-resume.bin")
        var firstRunId: String? = null
        var secondRunId: String? = null
        try {
            val add = RustCoreBridge.queueAdd(
                store.absolutePath,
                JSONObject()
                    .put("source", server.url)
                    .put("outputDir", output.absolutePath)
                    .put("fileName", file.name)
                    .toString(),
            )
            assertTrue("暂停测试入队失败: $add", parseOk(add))
            val taskId = JSONObject(add).getJSONObject("data").getString("id")
            firstRunId = startQueue(store)
            waitForTaskState(store, taskId, "running", 10_000)
            waitForDownloadedBytes(store, taskId, 0L, 10_000)

            val paused = RustCoreBridge.queuePause(store.absolutePath, taskId)
            assertTrue("暂停调用失败: $paused", parseOk(paused))
            waitForTaskState(store, taskId, "paused", 10_000)
            val pausedTask = queueTask(RustCoreBridge.queueList(store.absolutePath), taskId)
            assertEquals("paused", pausedTask.optString("state"))
            val partialBytes = pausedTask.optLong("downloaded_bytes")
            assertTrue("暂停应保留已下载断点", partialBytes > 0L)

            waitForRunTerminal(firstRunId, 10_000)
            RustCoreBridge.queueRunForget(firstRunId)
            val resumed = RustCoreBridge.queueResume(store.absolutePath, taskId)
            assertTrue("继续调用失败: $resumed", parseOk(resumed))
            secondRunId = startQueue(store)
            waitForTaskState(store, taskId, "finished", 30_000)
            waitForRunTerminal(secondRunId, 30_000)
            assertEquals(payload.toList(), file.readBytes().toList())
            assertTrue("继续后应保留或增加断点", queueTask(RustCoreBridge.queueList(store.absolutePath), taskId).optLong("downloaded_bytes") >= partialBytes)
        } finally {
            firstRunId?.let { forgetRunWhenTerminal(it) }
            secondRunId?.let { forgetRunWhenTerminal(it) }
            server.close()
            root.deleteRecursively()
        }
    }

    @Test
    fun queueConcurrencyOneDoesNotRunTwoTasksAtOnce() {
        val payload = ByteArray(128 * 1024) { index -> (index % 199).toByte() }
        val server = SlowLoopbackHttpServer(payload, chunkSize = 8 * 1024, chunkDelayMs = 35)
        val root = File(context.cacheDir, "rust-concurrency-${UUID.randomUUID()}").apply { mkdirs() }
        val store = File(root, "queue.json")
        val output = File(root, "downloads").apply { mkdirs() }
        var runId: String? = null
        try {
            val taskIds = (1..2).map { index ->
                val add = RustCoreBridge.queueAdd(
                    store.absolutePath,
                    JSONObject()
                        .put("source", server.url)
                        .put("outputDir", output.absolutePath)
                        .put("fileName", "concurrency-$index.bin")
                        .toString(),
                )
                assertTrue("并发测试入队失败: $add", parseOk(add))
                JSONObject(add).getJSONObject("data").getString("id")
            }
            runId = startQueue(store, concurrency = 1)
            var sawQueuedWhileRunning = false
            var maxRunning = 0
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
            while (System.nanoTime() < deadline) {
                val tasks = taskIds.map { taskId -> queueTask(RustCoreBridge.queueList(store.absolutePath), taskId) }
                val running = tasks.count { it.optString("state") == "running" }
                maxRunning = maxOf(maxRunning, running)
                if (running == 1 && tasks.any { it.optString("state") == "queued" }) sawQueuedWhileRunning = true
                if (tasks.all { it.optString("state") == "finished" }) break
                Thread.sleep(25)
            }
            waitForRunTerminal(runId, 30_000)
            assertTrue("第二个任务应在首个任务运行时排队", sawQueuedWhileRunning)
            assertEquals("并发限制为 1 时不能同时运行两个任务", 1, maxRunning)
            taskIds.forEach { taskId -> assertEquals("finished", queueTask(RustCoreBridge.queueList(store.absolutePath), taskId).optString("state")) }
        } finally {
            runId?.let { forgetRunWhenTerminal(it) }
            server.close()
            root.deleteRecursively()
        }
    }

    @Test
    fun queueTorrentAndMagnetDuplicateSelectionDoNotCorruptSharedOutput() {
        val arguments = InstrumentationRegistry.getArguments()
        val torrentUrl = arguments.getString("p2pTorrentUrl").orEmpty().trim()
        val infoHash = arguments.getString("p2pInfoHash").orEmpty().trim()
        val trackerUrl = arguments.getString("p2pTrackerUrl").orEmpty().trim()
        val expectedSha256 = arguments.getString("p2pSelectedSha256").orEmpty().trim()
        val expectedBytes = arguments.getString("p2pSelectedBytes")?.toLongOrNull() ?: 0L
        val directoryName = arguments.getString("p2pDirectoryName")?.trim().orEmpty()
            .ifBlank { "kotlin-duplicate-bundle" }
        val selectedPath = arguments.getString("p2pSelectedPath")?.trim().orEmpty()
            .ifBlank { "$directoryName/selected.bin" }
        val skippedPath = arguments.getString("p2pSkippedPath")?.trim().orEmpty()
            .ifBlank { "$directoryName/skipped.bin" }

        // 作者: long
        // 真实 P2P fixture 由主机脚本提供；普通 connectedDebugAndroidTest 不传这些参数时跳过，
        // 避免把依赖局域网 Seeder 的长测试误当成基础回归的一部分。
        assumeTrue(
            "缺少 p2pTorrentUrl/p2pInfoHash/p2pTrackerUrl，跳过局域网 Torrent/Magnet 压力用例",
            torrentUrl.isNotBlank() && infoHash.isNotBlank() && trackerUrl.isNotBlank()
                && expectedSha256.matches(Regex("[0-9a-fA-F]{64}")) && expectedBytes > 0L,
        )

        val magnet = "magnet:?xt=urn:btih:$infoHash&dn=$directoryName&tr=" +
            java.net.URLEncoder.encode(trackerUrl, Charsets.UTF_8.name())
        runDuplicateP2pPair(
            source = torrentUrl,
            rootName = "torrent-duplicate",
            directoryName = directoryName,
            selectedPath = selectedPath,
            skippedPath = skippedPath,
            expectedSha256 = expectedSha256,
            expectedBytes = expectedBytes,
        )
        runDuplicateP2pPair(
            source = magnet,
            rootName = "magnet-duplicate",
            directoryName = directoryName,
            selectedPath = selectedPath,
            skippedPath = skippedPath,
            expectedSha256 = expectedSha256,
            expectedBytes = expectedBytes,
        )
    }

    private fun runDuplicateP2pPair(
        source: String,
        rootName: String,
        directoryName: String,
        selectedPath: String,
        skippedPath: String,
        expectedSha256: String,
        expectedBytes: Long,
    ) {
        val root = File(context.cacheDir, "rust-$rootName-${UUID.randomUUID()}").apply { mkdirs() }
        val store = File(root, "queue.json")
        val output = File(root, "downloads").apply { mkdirs() }
        var runId: String? = null
        try {
            val files = JSONArray()
                .put(
                    JSONObject()
                        .put("index", 0)
                        .put("path", selectedPath)
                        .put("name", File(selectedPath).name)
                        .put("size", expectedBytes)
                        .put("isStreamable", false),
                )
                .put(
                    JSONObject()
                        .put("index", 1)
                        .put("path", skippedPath)
                        .put("name", File(skippedPath).name)
                        .put("size", expectedBytes)
                        .put("isStreamable", false),
                )
            val taskIds = (1..2).map { copy ->
                val add = RustCoreBridge.queueAdd(
                    store.absolutePath,
                    JSONObject()
                        .put("source", source)
                        .put("outputDir", output.absolutePath)
                        .put("fileName", "$directoryName-$copy.torrent")
                        .put("torrentName", directoryName)
                        .put("torrentFileIndices", JSONArray().put(0))
                        .put("torrentFiles", files)
                        .toString(),
                )
                assertTrue("重复 $rootName 任务入队失败: $add", parseOk(add))
                JSONObject(add).getJSONObject("data").getString("id")
            }
            runId = startQueue(store, concurrency = 2, threadCount = 1)
            waitForTaskStates(store, taskIds, "finished", 90_000)
            waitForRunTerminal(runId, 90_000)

            val selected = File(output, selectedPath)
            val skipped = File(output, skippedPath)
            assertTrue("$rootName 选中文件未落盘: ${selected.absolutePath}", selected.isFile)
            assertEquals("$rootName 最终文件大小不一致", expectedBytes, selected.length())
            assertEquals("$rootName 重复下载后的文件摘要不一致", expectedSha256.lowercase(), sha256(selected.readBytes()))
            // 作者: long
            // librqbit 可能为未选择文件创建零字节占位路径；验收真正关心的是不能把未选文件完整落盘。
            assertTrue(
                "$rootName 未选文件不应被完整下载: ${skipped.length()} B",
                !skipped.exists() || skipped.length() < expectedBytes,
            )
            taskIds.forEach { taskId ->
                val task = queueTask(RustCoreBridge.queueList(store.absolutePath), taskId)
                assertEquals("$rootName 重复任务未完成", "finished", task.optString("state"))
                assertEquals("$rootName 重复任务统计大小错误", expectedBytes, task.optLong("downloaded_bytes"))
            }
        } finally {
            runId?.let { forgetRunWhenTerminal(it) }
            root.deleteRecursively()
        }
    }

    @Test
    fun queueResetAndRemoveThroughRustUpdatePersistentQueue() {
        val root = File(context.cacheDir, "rust-reset-remove-${UUID.randomUUID()}").apply { mkdirs() }
        val store = File(root, "queue.json")
        val output = File(root, "downloads").apply { mkdirs() }
        try {
            val add = RustCoreBridge.queueAdd(
                store.absolutePath,
                JSONObject()
                    .put("source", "http://127.0.0.1:9/reset.bin")
                    .put("outputDir", output.absolutePath)
                    .put("fileName", "reset.bin")
                    .toString(),
            )
            assertTrue("重置测试入队失败: $add", parseOk(add))
            val taskId = JSONObject(add).getJSONObject("data").getString("id")
            assertTrue("暂停调用失败", parseOk(RustCoreBridge.queuePause(store.absolutePath, taskId)))
            assertEquals("paused", queueTask(RustCoreBridge.queueList(store.absolutePath), taskId).optString("state"))
            assertTrue("重置调用失败", parseOk(RustCoreBridge.queueReset(store.absolutePath, taskId)))
            assertEquals("queued", queueTask(RustCoreBridge.queueList(store.absolutePath), taskId).optString("state"))
            assertTrue("删除调用失败", parseOk(RustCoreBridge.queueRemove(store.absolutePath, taskId)))
            assertEquals(0, JSONObject(RustCoreBridge.queueList(store.absolutePath)).optJSONArray("data")?.length() ?: 0)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun foregroundServiceRecoversInterruptedRunningTask() {
        val payload = "recovered-after-process-restart".toByteArray()
        val server = LoopbackHttpServer(payload, rejectFirstRange = false)
        val root = File(context.cacheDir, "rust-service-recovery-${UUID.randomUUID()}").apply { mkdirs() }
        val store = File(root, "queue.json")
        val output = File(root, "downloads").apply { mkdirs() }
        val file = File(output, "recovered.bin")
        val settings = context.getSharedPreferences("fluxdown.kotlin.settings", 0)
        val previousThreads = settings.getString("threads", null)
        val previousConcurrency = settings.getString("concurrency", null)
        val previousRetries = settings.getString("retries", null)
        try {
            settings.edit().putString("threads", "1").putString("concurrency", "1").putString("retries", "0").commit()
            val add = RustCoreBridge.queueAdd(
                store.absolutePath,
                JSONObject()
                    .put("source", server.url)
                    .put("outputDir", output.absolutePath)
                    .put("fileName", file.name)
                    .toString(),
            )
            assertTrue("恢复测试入队失败: $add", parseOk(add))
            val taskId = JSONObject(add).getJSONObject("data").getString("id")
            markPersistedTaskRunning(store, taskId)

            val serviceIntent = Intent(context, DownloadForegroundService::class.java).apply {
                action = DownloadForegroundService.ACTION_START
                putExtra(DownloadForegroundService.EXTRA_STORE_PATH, store.absolutePath)
            }
            ContextCompat.startForegroundService(context, serviceIntent)
            waitForTaskState(store, taskId, "finished", 30_000)
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

    @Test
    fun foregroundServiceCompletesWhenActivityMovesToBackground() {
        val payload = ByteArray(16 * 1024 * 1024) { index -> (index * 17 % 251).toByte() }
        val server = SlowLoopbackHttpServer(payload, chunkSize = 8 * 1024, chunkDelayMs = 15)
        val root = File(context.cacheDir, "rust-service-background-${UUID.randomUUID()}").apply { mkdirs() }
        val store = File(root, "queue.json")
        val output = File(root, "downloads").apply { mkdirs() }
        val file = File(output, "background.bin")
        val settings = context.getSharedPreferences("fluxdown.kotlin.settings", 0)
        val previousThreads = settings.getString("threads", null)
        val previousConcurrency = settings.getString("concurrency", null)
        val previousRetries = settings.getString("retries", null)
        var serviceStarted = false
        try {
            // 作者: long
            // 先真实拉起 Kotlin 主页面，再把 Activity 送入后台；下载仍由前台服务持有 Rust 队列句柄。
            context.startActivity(
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            Thread.sleep(500)
            // 作者: long
            // 夹具只提供单连接响应；固定线程数后，测试观察的是 Activity 退后台期间服务是否持续工作，
            // 不把 Range 分片能力混入本用例的失败原因。
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
            assertTrue("后台服务测试入队失败: $add", parseOk(add))
            val taskId = JSONObject(add).getJSONObject("data").getString("id")
            val serviceIntent = Intent(context, DownloadForegroundService::class.java).apply {
                action = DownloadForegroundService.ACTION_START
                putExtra(DownloadForegroundService.EXTRA_STORE_PATH, store.absolutePath)
            }
            ContextCompat.startForegroundService(context, serviceIntent)
            serviceStarted = true
            waitForTaskState(store, taskId, "running", 10_000)
            waitForDownloadedBytes(store, taskId, 0L, 10_000)

            // 作者: long
            // 这里模拟用户按 Home 离开应用；不是 force-stop，服务和 Rust runner 应继续完成当前任务。
            InstrumentationRegistry.getInstrumentation()
                .uiAutomation
                .executeShellCommand("input keyevent KEYCODE_HOME")
                .close()
            waitForTaskState(store, taskId, "finished", 75_000)
            assertEquals(payload.toList(), file.readBytes().toList())
        } finally {
            if (serviceStarted) {
                context.stopService(Intent(context, DownloadForegroundService::class.java))
            }
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

    private fun startQueue(
        store: File,
        concurrency: Int = 1,
        threadCount: Int = 1,
        retryAttempts: Int = 0,
    ): String {
        val run = RustCoreBridge.queueRunQueued(
            store.absolutePath,
            JSONObject()
                .put("concurrency", concurrency)
                .put("threadCount", threadCount)
                .put("retryAttempts", retryAttempts)
                .toString(),
        )
        assertTrue("启动 Rust 队列失败: $run", parseOk(run))
        return JSONObject(run).getJSONObject("data").getString("runId")
    }

    private fun waitForTaskState(store: File, taskId: String, expected: String, timeoutMs: Long) {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        var task = queueTask(RustCoreBridge.queueList(store.absolutePath), taskId)
        while (System.nanoTime() < deadline && task.optString("state") != expected) {
            Thread.sleep(100)
            task = queueTask(RustCoreBridge.queueList(store.absolutePath), taskId)
        }
        assertEquals("任务未在 ${timeoutMs}ms 内进入 $expected: $task", expected, task.optString("state"))
    }

    private fun waitForTaskStates(store: File, taskIds: List<String>, expected: String, timeoutMs: Long) {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        var tasks = taskIds.map { taskId -> queueTask(RustCoreBridge.queueList(store.absolutePath), taskId) }
        while (System.nanoTime() < deadline && tasks.any { it.optString("state") != expected }) {
            Thread.sleep(200)
            tasks = taskIds.map { taskId -> queueTask(RustCoreBridge.queueList(store.absolutePath), taskId) }
            if (tasks.any { it.optString("state") == "failed" }) break
        }
        tasks.forEach { task ->
            assertEquals("任务未在 ${timeoutMs}ms 内进入 $expected: $task", expected, task.optString("state"))
        }
    }

    private fun waitForDownloadedBytes(store: File, taskId: String, minimum: Long, timeoutMs: Long) {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        var downloaded = queueTask(RustCoreBridge.queueList(store.absolutePath), taskId).optLong("downloaded_bytes")
        while (System.nanoTime() < deadline && downloaded <= minimum) {
            Thread.sleep(100)
            downloaded = queueTask(RustCoreBridge.queueList(store.absolutePath), taskId).optLong("downloaded_bytes")
        }
        assertTrue("任务未在 ${timeoutMs}ms 内产生进度: $downloaded", downloaded > minimum)
    }

    private fun waitForRunTerminal(runId: String, timeoutMs: Long) {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        var state = parseState(RustCoreBridge.queueRunStatus(runId))
        while (System.nanoTime() < deadline && state == "running") {
            Thread.sleep(100)
            state = parseState(RustCoreBridge.queueRunStatus(runId))
        }
        assertTrue("异步队列句柄未结束: $runId", state == "finished" || state == "failed")
    }

    private fun forgetRunWhenTerminal(runId: String) {
        runCatching {
            waitForRunTerminal(runId, 5_000)
            RustCoreBridge.queueRunForget(runId)
        }
    }

    private fun markPersistedTaskRunning(store: File, taskId: String) {
        val root = JSONObject(store.readText())
        val tasks = root.optJSONArray("tasks") ?: error("队列文件没有 tasks")
        val task = (0 until tasks.length())
            .mapNotNull { tasks.optJSONObject(it) }
            .firstOrNull { it.optString("id") == taskId }
            ?: error("队列文件找不到任务 $taskId")
        task.put("state", "running")
        task.put("updated_at_ms", System.currentTimeMillis())
        root.put("tasks", tasks)
        store.writeText(root.toString())
    }

    private fun parseOk(envelope: String): Boolean = JSONObject(envelope).optBoolean("ok", false)

    private fun parseState(envelope: String): String =
        JSONObject(envelope).optJSONObject("data")?.optString("state").orEmpty()

    private fun sha256(bytes: ByteArray): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
        return digest.joinToString("") { byte -> "%02x".format(byte) }
    }

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

    private class SlowLoopbackHttpServer(
        private val payload: ByteArray,
        private val chunkSize: Int,
        private val chunkDelayMs: Long,
    ) : AutoCloseable {
        private val server = ServerSocket(0, 4, java.net.InetAddress.getByName("127.0.0.1"))
        private val thread = Thread(::serve, "fluxdown-android-test-slow-http")
        val url = "http://127.0.0.1:${server.localPort}/slow.bin"

        init { thread.start() }

        private fun serve() {
            while (!server.isClosed) {
                runCatching { server.accept() }.getOrNull()?.let { socket ->
                    Thread({ respond(socket) }, "fluxdown-android-test-slow-http-client").start()
                }
            }
        }

        private fun respond(socket: Socket) {
            socket.use { client ->
                val request = BufferedInputStream(client.getInputStream())
                readHeaders(request)
                runCatching {
                    val writer = client.getOutputStream().bufferedWriter()
                    writer.write("HTTP/1.1 200 OK\r\nContent-Length: ${payload.size}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n")
                    writer.flush()
                    var offset = 0
                    while (offset < payload.size) {
                        val end = (offset + chunkSize).coerceAtMost(payload.size)
                        client.getOutputStream().write(payload, offset, end - offset)
                        client.getOutputStream().flush()
                        offset = end
                        Thread.sleep(chunkDelayMs)
                    }
                }
            }
        }

        override fun close() {
            server.close()
            thread.join(2_000)
        }
    }

    private class HlsLoopbackHttpServer(
        segmentCount: Int,
        segmentSize: Int,
        private val chunkDelayMs: Long,
    ) : AutoCloseable {
        private val server = ServerSocket(0, 8, java.net.InetAddress.getByName("127.0.0.1"))
        private val thread = Thread(::serve, "fluxdown-android-test-hls-http")
        private val segments = List(segmentCount) { index ->
            ByteArray(segmentSize) { offset -> ((index * 17 + offset) % 251).toByte() }
        }
        private val playlist = buildString {
            append("#EXTM3U\n")
            append("#EXT-X-TARGETDURATION:1\n")
            append("#EXT-X-VERSION:3\n")
            append("#EXT-X-MEDIA-SEQUENCE:0\n")
            segments.indices.forEach { index ->
                append("#EXTINF:1.0,\nsegment-$index.ts\n")
            }
            append("#EXT-X-ENDLIST\n")
        }.toByteArray(Charsets.US_ASCII)
        val playlistUrl = "http://127.0.0.1:${server.localPort}/playlist.m3u8"

        init { thread.start() }

        private fun serve() {
            while (!server.isClosed) {
                runCatching { server.accept() }.getOrNull()?.let { socket ->
                    Thread({ respond(socket) }, "fluxdown-android-test-hls-http-client").start()
                }
            }
        }

        private fun respond(socket: Socket) {
            socket.use { client ->
                val request = BufferedInputStream(client.getInputStream())
                val requestLine = readHeaders(request)
                val path = requestLine.split(' ').getOrNull(1)?.substringBefore('?') ?: "/"
                val body = when {
                    path == "/playlist.m3u8" -> playlist
                    path.startsWith("/segment-") && path.endsWith(".ts") -> {
                        path.removePrefix("/segment-").removeSuffix(".ts").toIntOrNull()
                            ?.let { segments.getOrNull(it) }
                    }
                    else -> null
                }
                if (body == null) {
                    client.getOutputStream().bufferedWriter().use { writer ->
                        writer.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                        writer.flush()
                    }
                    return
                }
                runCatching {
                    val writer = client.getOutputStream().bufferedWriter()
                    writer.write("HTTP/1.1 200 OK\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n")
                    writer.flush()
                    var offset = 0
                    while (offset < body.size) {
                        val end = (offset + 32 * 1024).coerceAtMost(body.size)
                        client.getOutputStream().write(body, offset, end - offset)
                        client.getOutputStream().flush()
                        offset = end
                        if (chunkDelayMs > 0) Thread.sleep(chunkDelayMs)
                    }
                }
            }
        }

        override fun close() {
            server.close()
            thread.join(2_000)
        }
    }

    private class TruncatedLoopbackHttpServer(
        private val payload: ByteArray,
        private val bytesToSend: Int,
    ) : AutoCloseable {
        private val server = ServerSocket(0, 4, java.net.InetAddress.getByName("127.0.0.1"))
        private val thread = Thread(::serve, "fluxdown-android-test-truncated-http")
        val url = "http://127.0.0.1:${server.localPort}/truncated.bin"
        val requestCount = AtomicInteger(0)

        init { thread.start() }

        private fun serve() {
            while (!server.isClosed) {
                runCatching { server.accept() }.getOrNull()?.let { socket ->
                    Thread({ respond(socket) }, "fluxdown-android-test-truncated-http-client").start()
                }
            }
        }

        private fun respond(socket: Socket) {
            socket.use { client ->
                val request = BufferedInputStream(client.getInputStream())
                readHeaders(request)
                requestCount.incrementAndGet()
                runCatching {
                    val writer = client.getOutputStream().bufferedWriter()
                    writer.write("HTTP/1.1 200 OK\r\nContent-Length: ${payload.size}\r\nConnection: close\r\n\r\n")
                    writer.flush()
                    client.getOutputStream().write(payload, 0, bytesToSend.coerceAtMost(payload.size))
                    client.getOutputStream().flush()
                    // 作者: long
                    // 主动关闭连接，模拟 CDN/网络在响应体未完成时断开；客户端应将其判为失败并按配置重试。
                }
            }
        }

        override fun close() {
            server.close()
            thread.join(2_000)
        }
    }

    private class RecoveringTruncatedLoopbackHttpServer(
        private val payload: ByteArray,
        private val bytesToSendBeforeRecovery: Int,
    ) : AutoCloseable {
        private val server = ServerSocket(0, 4, java.net.InetAddress.getByName("127.0.0.1"))
        private val thread = Thread(::serve, "fluxdown-android-test-network-recovery-http")
        val url = "http://127.0.0.1:${server.localPort}/network-recovery.bin"
        val requestCount = AtomicInteger(0)

        init { thread.start() }

        private fun serve() {
            while (!server.isClosed) {
                runCatching { server.accept() }.getOrNull()?.let { socket ->
                    Thread({ respond(socket) }, "fluxdown-android-test-network-recovery-client").start()
                }
            }
        }

        private fun respond(socket: Socket) {
            socket.use { client ->
                val request = BufferedInputStream(client.getInputStream())
                readHeaders(request)
                val attempt = requestCount.incrementAndGet()
                runCatching {
                    val writer = client.getOutputStream().bufferedWriter()
                    writer.write("HTTP/1.1 200 OK\r\nContent-Length: ${payload.size}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n")
                    writer.flush()
                    val bytesToSend = if (attempt == 1) {
                        bytesToSendBeforeRecovery.coerceAtMost(payload.size)
                    } else {
                        payload.size
                    }
                    client.getOutputStream().write(payload, 0, bytesToSend)
                    client.getOutputStream().flush()
                    // 作者: long
                    // 首次响应在声明的 Content-Length 之前断开，模拟 Wi-Fi/蜂窝网络切换造成的传输中断；
                    // 后续请求返回完整资源，验证 runner 的瞬态重试和文件恢复边界。
                }
            }
        }

        override fun close() {
            server.close()
            thread.join(2_000)
        }
    }

    private companion object {
        private fun readHeaders(input: BufferedInputStream): String {
            var window = ""
            var firstLine = ""
            var line = StringBuilder()
            var current: Int
            while (input.read().also { current = it } >= 0) {
                if (current == '\n'.code) {
                    if (firstLine.isEmpty()) firstLine = line.toString().trimEnd('\r')
                    line = StringBuilder()
                } else {
                    line.append(current.toChar())
                }
                window = (window + current.toChar()).takeLast(4)
                if (window == "\r\n\r\n") return firstLine
            }
            return firstLine
        }
    }
}
