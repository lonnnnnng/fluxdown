package dev.fluxdown.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 提升下载进程的系统存活优先级，并把队列进度暴露给用户。
 *
 * 下载本身仍由 Flutter/Rust 队列执行；服务只负责生命周期和通知，不在第二处复制队列状态。
 */
class DownloadForegroundService : Service() {
    companion object {
        const val ACTION_START = "dev.fluxdown.mobile.action.START_DOWNLOAD"
        const val ACTION_UPDATE = "dev.fluxdown.mobile.action.UPDATE_DOWNLOAD"
        const val ACTION_STOP = "dev.fluxdown.mobile.action.STOP_DOWNLOAD"
        const val EXTRA_RUNNING_TASKS = "runningTasks"
        const val EXTRA_FINISHED_TASKS = "finishedTasks"
        const val EXTRA_TOTAL_TASKS = "totalTasks"
        const val EXTRA_PROGRESS = "progressPercent"

        private const val CHANNEL_ID = "fluxdown_downloads"
        private const val NOTIFICATION_ID = 4101
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        val notification = buildNotification(0, 0, 0, 0)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }

            ACTION_UPDATE, ACTION_START -> {
                updateNotification(
                    intent?.getIntExtra(EXTRA_RUNNING_TASKS, 0) ?: 0,
                    intent?.getIntExtra(EXTRA_FINISHED_TASKS, 0) ?: 0,
                    intent?.getIntExtra(EXTRA_TOTAL_TASKS, 0) ?: 0,
                    intent?.getIntExtra(EXTRA_PROGRESS, 0) ?: 0,
                )
            }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun updateNotification(
        runningTasks: Int,
        finishedTasks: Int,
        totalTasks: Int,
        progressPercent: Int,
    ) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(
            NOTIFICATION_ID,
            buildNotification(runningTasks, finishedTasks, totalTasks, progressPercent),
        )
    }

    private fun buildNotification(
        runningTasks: Int,
        finishedTasks: Int,
        totalTasks: Int,
        progressPercent: Int,
    ): Notification {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            4102,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val title = if (runningTasks > 0) "FluxDown 正在下载" else "FluxDown 下载队列"
        val text = if (totalTasks > 0) {
            "进行中 $runningTasks · 已完成 $finishedTasks/$totalTasks"
        } else {
            "下载队列正在运行"
        }
        val progress = progressPercent.coerceIn(0, 100)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(100, progress, totalTasks <= 0)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "下载任务",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "显示 FluxDown 下载队列的运行状态和进度"
                setShowBadge(false)
            },
        )
    }
}
