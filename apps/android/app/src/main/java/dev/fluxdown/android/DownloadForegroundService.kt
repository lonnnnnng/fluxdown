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
import androidx.core.app.NotificationCompat
import dev.fluxdown.android.core.RustCoreBridge
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

/**
 * 为 Kotlin 预览宿主保持进程优先级并发布 Rust 队列状态。
 * 作者: long
 * 下载执行仍由 MainActivity 的唯一 Rust 队列句柄负责，服务不再启动第二个 runner，避免同一队列重复运行。
 */
class DownloadForegroundService : Service() {
    companion object {
        const val ACTION_START = "dev.fluxdown.android.action.START_DOWNLOAD"
        const val ACTION_UPDATE = "dev.fluxdown.android.action.UPDATE_DOWNLOAD"
        const val ACTION_STOP = "dev.fluxdown.android.action.STOP_DOWNLOAD"
        const val EXTRA_STORE_PATH = "storePath"
        private const val CHANNEL_ID = "fluxdown.kotlin.downloads"
        private const val NOTIFICATION_ID = 4201
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var monitorJob: Job? = null
    private var storePath: String? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startInForeground(buildNotification(0, 0, 0, 0))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START, ACTION_UPDATE -> {
                storePath = intent.getStringExtra(EXTRA_STORE_PATH) ?: storePath
                ensureMonitor()
            }
        }
        // 作者: long
        // Rust 运行句柄只存在当前进程，进程被杀后不能仅靠重启通知服务假装下载仍在继续。
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun ensureMonitor() {
        if (monitorJob?.isActive == true) return
        monitorJob = scope.launch {
            while (isActive) {
                val path = storePath
                if (path == null) {
                    delay(700)
                    continue
                }
                val summary = readSummary(path)
                getSystemService(NotificationManager::class.java).notify(
                    NOTIFICATION_ID,
                    buildNotification(summary.running, summary.finished, summary.total, summary.progressPercent),
                )
                if (summary.total > 0 && summary.running == 0 && summary.queued == 0) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                    break
                }
                delay(900)
            }
        }
    }

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
            val state = task.optString("state")
            if (state == "running") running++
            if (state == "queued") queued++
            if (state == "finished") finished++
            total++
            downloaded += task.optLong("downloaded_bytes", task.optLong("downloadedBytes", 0L))
            val size = task.optLong("total_bytes", task.optLong("totalBytes", 0L))
            if (size > 0) totalBytes += size
        }
        QueueSummary(running, queued, finished, total, if (totalBytes > 0) ((downloaded * 100) / totalBytes).toInt() else 0)
    }.getOrDefault(QueueSummary(0, 0, 0, 0, 0))

    private fun startInForeground(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "下载任务", NotificationManager.IMPORTANCE_LOW).apply {
                description = "FluxDown Kotlin 下载进度"
            },
        )
    }

    private fun buildNotification(running: Int, finished: Int, total: Int, progress: Int): Notification {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            NOTIFICATION_ID,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val text = if (total > 0) "进行中 $running · 已完成 $finished/$total" else "下载队列正在运行"
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("FluxDown Kotlin")
            .setContentText(text)
            .setContentIntent(pendingIntent)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
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
