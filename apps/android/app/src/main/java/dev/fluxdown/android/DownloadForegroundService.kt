package dev.fluxdown.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import dev.fluxdown.android.core.RustCoreBridge
import dev.fluxdown.android.platform.AndroidCredentialVault
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import dev.fluxdown.android.ui.i18n.Str
import dev.fluxdown.android.ui.i18n.trOff

/**
 * Android 下载前台服务。
 * 作者: long
 * Rust runner 必须跟随前台服务而不是 Activity 存活，进程被系统回收后服务重建即可重新恢复
 * interrupted 任务；Activity 只负责展示队列和发送暂停/继续等用户操作。
 */
class DownloadForegroundService : Service() {
    companion object {
        const val ACTION_START = "dev.fluxdown.android.action.START_DOWNLOAD"
        const val ACTION_UPDATE = "dev.fluxdown.android.action.UPDATE_DOWNLOAD"
        const val ACTION_STOP = "dev.fluxdown.android.action.STOP_DOWNLOAD"
        const val EXTRA_STORE_PATH = "storePath"
        private const val CHANNEL_ID = "fluxdown.kotlin.downloads"
        private const val CHANNEL_ID_COMPLETED = "fluxdown.kotlin.completed"
        private const val NOTIFICATION_ID = 4201
        private const val COMPLETION_NOTIFICATION_ID = 4202
        private const val SETTINGS = "fluxdown.kotlin.settings"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var runnerJob: Job? = null
    private var storePath: String? = null
    private var recoveryHandled = false

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startInForeground(buildNotification(0, 0, 0, 0, null))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            runnerJob?.cancel()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        storePath = intent?.getStringExtra(EXTRA_STORE_PATH)?.takeIf { it.isNotBlank() } ?: defaultStorePath()
        Log.i("FluxDownService", "onStartCommand action=${intent?.action} storePath=$storePath")
        ensureRunner()
        // 作者: long
        // START_STICKY 让系统在后台回收后重建服务；重建时从持久化 Rust 队列恢复，而不是依赖 Activity 再次打开。
        return START_STICKY
    }

    override fun onDestroy() {
        runnerJob?.cancel()
        scope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun ensureRunner() {
        if (runnerJob?.isActive == true) return
        val path = storePath ?: defaultStorePath()
        runnerJob = scope.launch { runQueueLoop(path) }
    }

    private suspend fun runQueueLoop(path: String) {
        Log.i("FluxDownService", "runner started")
        recoverInterrupted(path)
        while (scope.isActive) {
            val summary = readSummary(path)
            updateNotification(summary, null)
            if (summary.running == 0 && summary.queued == 0) {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }

            val start = RustCoreBridge.queueRunQueued(path, buildQueueOptions(path))
            val runId = parseDataString(start, "runId")
            if (runId == null) {
                val error = parseError(start) ?: trOff(this, Str.SvcQueueStartFailed)
                Log.w("FluxDownService", "queue runner start failed: $error")
                updateNotification(summary, error)
                delay(2_000)
                continue
            }

            var terminalState: String? = null
            var terminalError: String? = null
            while (scope.isActive && terminalState == null) {
                val status = RustCoreBridge.queueRunStatus(runId)
                val state = parseDataString(status, "state")
                if (state == "finished" || state == "failed") {
                    terminalState = state
                    terminalError = parseDataString(status, "error") ?: parseError(status)
                } else {
                    updateNotification(readSummary(path), null)
                    delay(900)
                }
            }
            RustCoreBridge.queueRunForget(runId)
            Log.i("FluxDownService", "runner terminal state=$terminalState error=$terminalError")
            if (!scope.isActive) return
            val finalSummary = readSummary(path)
            updateNotification(finalSummary, terminalError.takeIf { terminalState == "failed" })
            if (finalSummary.running == 0 && finalSummary.queued == 0) {
                // 作者: long
                // S2 完成通知：前台进度通知随服务停止而消失，所以“下载完成”必须单独发一条，
                // 由设置开关 notifyOnComplete 控制（默认开）。
                notifyCompletion(finalSummary, terminalError.takeIf { terminalState == "failed" })
                delay(600)
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }
            // Rust runner 正常收尾后，队列中仍可能有排队任务；下一轮使用当前设置启动新的 runner。
            delay(250)
        }
    }

    private suspend fun recoverInterrupted(path: String) {
        if (recoveryHandled) return
        recoveryHandled = true
        val recovery = RustCoreBridge.queueRecoverInterrupted(path)
        if (parseError(recovery) != null) return
        val ids = runCatching {
            val data = JSONObject(recovery).optJSONObject("data") ?: JSONObject()
            val taskIds = data.optJSONArray("taskIds") ?: JSONArray()
            buildList {
                for (index in 0 until taskIds.length()) {
                    taskIds.optString(index).trim().takeIf { it.isNotEmpty() }?.let(::add)
                }
            }
        }.getOrDefault(emptyList())
        ids.forEach { id -> RustCoreBridge.queueResume(path, id) }
    }

    private fun buildQueueOptions(path: String): String {
        val prefs = getSharedPreferences(SETTINGS, MODE_PRIVATE)
        val options = JSONObject()
            .put("concurrency", prefs.getString("concurrency", "5")?.toIntOrNull()?.coerceIn(1, 30) ?: 5)
            .put("threadCount", prefs.getString("threads", "16")?.toIntOrNull()?.coerceIn(1, 32) ?: 16)
            .put("retryAttempts", prefs.getString("retries", "3")?.toIntOrNull()?.coerceIn(0, 10) ?: 3)

        prefs.getString("sftpKnownHostsPath", "")
            ?.trim()
            ?.takeIf { it.isNotEmpty() && File(it).isFile }
            ?.let { options.put("sftpKnownHosts", it) }
        prefs.getString("speedLimit", "")
            ?.toDoubleOrNull()
            ?.takeIf { it > 0.0 }
            ?.let { options.put("speedLimitKbps", it * 1024.0) }

        val runtimeCredentials = JSONObject()
        val tasks = runCatching { JSONObject(RustCoreBridge.queueList(path)).optJSONArray("data") ?: JSONArray() }
            .getOrDefault(JSONArray())
        val vault = AndroidCredentialVault(this)
        for (index in 0 until tasks.length()) {
            val task = tasks.optJSONObject(index) ?: continue
            val state = task.optString("state")
            if (state != "queued" && state != "running") continue
            val reference = task.optString("credential_ref", task.optString("credentialRef")).trim()
            if (reference.isEmpty()) continue
            vault.get(reference)?.let { credential ->
                val value = JSONObject().put("username", credential.username)
                if (credential.usesPrivateKey) {
                    value.put("authType", "privateKey")
                    value.put("privateKeyPem", credential.privateKeyPem)
                    credential.passphrase?.let { value.put("passphrase", it) }
                } else {
                    value.put("password", credential.password)
                }
                runtimeCredentials.put(task.optString("id"), value)
            }
        }
        if (runtimeCredentials.length() > 0) options.put("runtimeCredentials", runtimeCredentials)
        return options.toString()
    }

    private fun defaultStorePath(): String = File(filesDir, "fluxdown/rust-queue.json").absolutePath

    private fun readSummary(path: String): QueueSummary = runCatching {
        val root = JSONObject(RustCoreBridge.queueList(path))
        val tasks = root.optJSONArray("data") ?: JSONArray()
        var running = 0
        var queued = 0
        var finished = 0
        var total = 0
        var downloaded = 0L
        var totalBytes = 0L
        for (index in 0 until tasks.length()) {
            val task = tasks.optJSONObject(index) ?: continue
            when (task.optString("state")) {
                "running" -> running++
                "queued" -> queued++
                "finished" -> finished++
            }
            total++
            downloaded += task.optLong("downloaded_bytes", task.optLong("downloadedBytes", 0L))
            val size = task.optLong("total_bytes", task.optLong("totalBytes", 0L))
            if (size > 0) totalBytes += size
        }
        QueueSummary(running, queued, finished, total, if (totalBytes > 0) ((downloaded * 100) / totalBytes).toInt() else 0)
    }.onFailure { error ->
        Log.w("FluxDownService", "queueList failed for $path", error)
    }.getOrDefault(QueueSummary(0, 0, 0, 0, 0))

    private fun parseDataString(envelope: String, key: String): String? = runCatching {
        JSONObject(envelope).optJSONObject("data")?.optString(key)?.trim()?.takeIf { it.isNotEmpty() }
    }.getOrNull()

    private fun parseError(envelope: String): String? = runCatching {
        val root = JSONObject(envelope)
        if (root.optBoolean("ok", false)) null else root.optString("error").ifBlank { trOff(this, Str.RustUnknownError) }
    }.getOrNull()

    private fun updateNotification(summary: QueueSummary, error: String?) {
        getSystemService(NotificationManager::class.java).notify(
            NOTIFICATION_ID,
            buildNotification(summary.running, summary.finished, summary.total, summary.progressPercent, error),
        )
    }

    /**
     * 作者: long
     * 完成通知独立于前台服务通知：服务停止会移除进度通知，用户看不到“已下载完”的结果，
     * 这条通知可单独关闭（S2），失败时也能把失败原因带出去。
     */
    private fun notifyCompletion(summary: QueueSummary, error: String?) {
        val enabled = getSharedPreferences(SETTINGS, MODE_PRIVATE).getBoolean("notifyOnComplete", true)
        if (!enabled) return
        if (summary.total == 0 && error == null) return
        val text = when {
            error != null -> trOff(this, Str.DownloadFailedWith, error)
            summary.finished > 0 -> trOff(this, Str.CompletedTasksCount, summary.finished)
            else -> trOff(this, Str.QueueEnded)
        }
        runCatching {
            getSystemService(NotificationManager::class.java).notify(
                COMPLETION_NOTIFICATION_ID,
                NotificationCompat.Builder(this, CHANNEL_ID_COMPLETED)
                    .setSmallIcon(android.R.drawable.stat_sys_download_done)
                    .setContentTitle(trOff(applicationContext, Str.ChannelDone))
                    .setContentText(text)
                    .setContentIntent(contentIntent())
                    .setAutoCancel(true)
                    .build(),
            )
        }
    }

    private fun contentIntent(): PendingIntent {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(
            this,
            NOTIFICATION_ID,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun startInForeground(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, trOff(applicationContext, Str.ChannelProgress), NotificationManager.IMPORTANCE_LOW).apply {
                description = trOff(applicationContext, Str.ChannelProgressDesc)
            },
        )
        // 完成通知用 DEFAULT 重要性，才能有声音/横幅提示，和常驻的进度通知区分开。
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID_COMPLETED, trOff(applicationContext, Str.ChannelDone), NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = trOff(applicationContext, Str.ChannelDoneDesc)
            },
        )
    }

    private fun buildNotification(running: Int, finished: Int, total: Int, progress: Int, error: String?): Notification {
        val pendingIntent = contentIntent()
        val text = when {
            error != null -> trOff(this, Str.DownloadFailedWith, error)
            total > 0 -> trOff(this, Str.QueueProgressSummary, running, finished, total)
            else -> trOff(this, Str.QueueRunning)
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("FluxDown")
            .setContentText(text)
            .setContentIntent(pendingIntent)
            .setOnlyAlertOnce(true)
            .setOngoing(error == null)
            .setProgress(100, progress.coerceIn(0, 100), total == 0)
            .build()
    }

    private data class QueueSummary(
        val running: Int,
        val queued: Int,
        val finished: Int,
        val total: Int,
        val progressPercent: Int,
    )
}
