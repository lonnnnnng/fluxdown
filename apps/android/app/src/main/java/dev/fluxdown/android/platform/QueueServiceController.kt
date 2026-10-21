package dev.fluxdown.android.platform

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import dev.fluxdown.android.DownloadForegroundService

/**
 * 作者: long
 * 前台下载服务的启动入口。真正的队列推进由 Rust core 负责，这里只负责把服务拉起来，
 * 并告诉调用方是否需要先申请通知权限。
 */
internal class QueueServiceController(
    private val context: Context,
    private val storePath: String,
) {
    /** Android 13 起前台服务通知需要运行时授权；未授权时返回 true 让 UI 发起请求。 */
    fun needsNotificationPermission(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED

    fun start(action: String) {
        val intent = Intent(context, DownloadForegroundService::class.java).apply {
            this.action = action
            putExtra(DownloadForegroundService.EXTRA_STORE_PATH, storePath)
        }
        runCatching { ContextCompat.startForegroundService(context, intent) }
    }
}
