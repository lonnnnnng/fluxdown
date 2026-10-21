package dev.fluxdown.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.fluxdown.android.core.RustCoreBridge
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Kotlin Android 端 12 类协议真机矩阵。
 *
 * 作者: long
 * 这份用例不模拟协议，而是走 Kotlin 端真实使用的同一套 Rust 队列入口
 * （`RustCoreBridge.queueAdd` + `queueRunQueued`），对 `scripts/android-kotlin-protocol-fixtures.sh`
 * 起在回环地址、再经 `adb reverse` 映射到设备的夹具做真实下载，并逐条记录
 * 队列终态、下载字节数与落盘文件 SHA-256，供 `docs/android-kotlin-protocol-report-*.md` 引用。
 *
 * 夹具清单由 `adb shell run-as <pkg> sh -c 'cat > files/protocol-manifest.json'` 推入，
 * 结构见夹具脚本 `write_manifest`：{fixtures: [{name,url,expect:{bytes,sha256},boundary?}]}。
 */
@RunWith(AndroidJUnit4::class)
class ProtocolMatrixTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val manifestFile = File(
        context.getExternalFilesDir(null) ?: context.filesDir,
        "protocol-manifest.json",
    )
    private val resultsFile = File(
        context.getExternalFilesDir(null) ?: context.filesDir,
        "protocol-matrix-results.json",
    )

    @Test
    fun protocolMatrixDownloadsEveryBuiltInProtocol() {
        // 作者: long
        // 矩阵依赖外部夹具与 adb reverse，默认套件里必须跳过：
        // 否则 `connectedDebugAndroidTest` 会在没有夹具时把 11 条协议全部判失败。
        assumeTrue(
            "协议矩阵需由 scripts/verify-android-kotlin-protocols.sh 显式启用（-e protocolMatrix true）",
            InstrumentationRegistry.getArguments().getString("protocolMatrix") == "true",
        )
        assertTrue("缺少夹具清单：${manifestFile.absolutePath}", manifestFile.isFile)
        val manifest = JSONObject(manifestFile.readText())
        val fixtures = manifest.getJSONArray("fixtures")
        // 调试用：`-e protocols torrent,magnet` 只跑指定协议，避免每次都等完整个矩阵。
        val only = InstrumentationRegistry.getArguments().getString("protocols")
            ?.split(',')
            ?.map { it.trim() }
            ?.filter { it.isNotEmpty() }
            ?.toSet()
            ?.takeIf { it.isNotEmpty() }
        val root = File(context.cacheDir, "protocol-matrix").apply { deleteRecursively(); mkdirs() }
        val results = JSONArray()
        val failures = mutableListOf<String>()

        for (index in 0 until fixtures.length()) {
            val fixture = fixtures.optJSONObject(index) ?: continue
            val name = fixture.optString("name")
            if (only != null && name !in only) continue
            val url = fixture.optString("url")
            val expect = fixture.optJSONObject("expect")
            val boundary = fixture.optBoolean("boundary", false)
            val timeoutSeconds = if (name == "torrent" || name == "magnet") 240L else 120L

            val entryRoot = File(root, name).apply { mkdirs() }
            val store = File(entryRoot, "queue.json")
            val output = File(entryRoot, "downloads").apply { mkdirs() }

            val add = RustCoreBridge.queueAdd(
                store.absolutePath,
                JSONObject()
                    .put("source", url)
                    .put("outputDir", output.absolutePath)
                    .toString(),
            )
            val addOk = JSONObject(add).optBoolean("ok", false)
            if (!addOk) {
                results.put(
                    JSONObject()
                        .put("name", name)
                        .put("url", url)
                        .put("state", "rejected")
                        .put("boundary", boundary)
                        .put("error", JSONObject(add).optString("error", "queue_add failed"))
                        .put("fixture", fixture.optString("fixture")),
                )
                if (!boundary) failures += "$name: 入队被拒绝"
                continue
            }
            val taskId = JSONObject(add).getJSONObject("data").optString("id")
            val run = RustCoreBridge.queueRunQueued(
                store.absolutePath,
                JSONObject()
                    .put("concurrency", 1)
                    .put("threadCount", 4)
                    .put("retryAttempts", 0)
                    .toString(),
            )
            val runId = JSONObject(run).optJSONObject("data")?.optString("runId").orEmpty()

            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(timeoutSeconds)
            var task = JSONObject()
            while (System.nanoTime() < deadline) {
                task = findTask(RustCoreBridge.queueList(store.absolutePath), taskId)
                val state = task.optString("state", "unknown")
                if (state != "running" && state != "queued") break
                Thread.sleep(200)
            }
            if (runId.isNotEmpty()) {
                while (System.nanoTime() < deadline &&
                    JSONObject(RustCoreBridge.queueRunStatus(runId)).optJSONObject("data")?.optString("state") == "running"
                ) {
                    Thread.sleep(200)
                }
                RustCoreBridge.queueRunForget(runId)
            }
            task = findTask(RustCoreBridge.queueList(store.absolutePath), taskId)
            val state = task.optString("state", "unknown")
            val downloadedBytes = task.optLong("downloaded_bytes")
            val error = task.optString("error", "")

            val producedFiles = collectOutputFiles(output)
            val actualSha = sha256OfFiles(producedFiles)
            val actualBytes = producedFiles.sumOf { it.length() }
            val expectedSha = expect?.optString("sha256").orEmpty()
            val expectedBytes = expect?.optLong("bytes", -1) ?: -1

            val entry = JSONObject()
                .put("name", name)
                .put("url", url)
                .put("state", state)
                .put("boundary", boundary)
                .put("downloadedBytes", downloadedBytes)
                .put("outputBytes", actualBytes)
                .put("sha256", actualSha)
                .put("expectedSha256", expectedSha)
                .put("expectedBytes", expectedBytes)
                .put("outputPath", output.absolutePath)
                .put("files", JSONArray(producedFiles.map { it.name }))
                .put("fixture", fixture.optString("fixture"))
                .put("error", error)
            results.put(entry)

            if (boundary) continue
            when {
                state != "finished" -> failures += "$name: 终态 $state（${error.ifEmpty { "无错误信息" }}）"
                expectedSha.isNotEmpty() && actualSha != expectedSha -> failures += "$name: SHA-256 不一致"
                expectedBytes >= 0 && actualBytes.toLong() != expectedBytes -> failures += "$name: 字节数 $actualBytes != $expectedBytes"
            }
        }

        val payload = JSONObject()
            .put("generatedAt", java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss", java.util.Locale.US).format(java.util.Date()))
            .put("device", android.os.Build.MODEL + " / API " + android.os.Build.VERSION.SDK_INT)
            .put("results", results)
        resultsFile.parentFile?.mkdirs()
        resultsFile.writeText(payload.toString(2))

        assertTrue("协议矩阵失败项：${failures.joinToString("; ")}", failures.isEmpty())
    }

    private fun findTask(envelope: String, taskId: String): JSONObject {
        val tasks = JSONObject(envelope).optJSONArray("data") ?: JSONArray()
        for (index in 0 until tasks.length()) {
            val task = tasks.optJSONObject(index) ?: continue
            if (task.optString("id") == taskId) return task
        }
        return JSONObject()
    }

    /** 收集产物文件：跳过 HLS 分片缓存目录、`.part` 临时文件与点文件。 */
    private fun collectOutputFiles(directory: File): List<File> =
        directory.walkTopDown()
            .filter { it.isFile }
            .filter { !it.name.startsWith(".") && !it.name.endsWith(".part") }
            .filter { !it.absolutePath.contains(".hls-cache") && !it.absolutePath.contains("hls_cache") }
            .sortedBy { it.relativeTo(directory).path }
            .toList()

    /** 对全部产物按相对路径顺序做流式 SHA-256，单文件场景等价于文件自身摘要。 */
    private fun sha256OfFiles(files: List<File>): String {
        val digest = MessageDigest.getInstance("SHA-256")
        files.forEach { file ->
            file.inputStream().use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    digest.update(buffer, 0, read)
                }
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
