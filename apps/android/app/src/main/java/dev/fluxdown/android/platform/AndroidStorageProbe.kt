package dev.fluxdown.android.platform

import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.os.storage.StorageManager

/**
 * 作者: long
 * 存储容量探测。SAF 的 content:// 目录无法直接传给 StatFs，因此统一换算成所属存储卷的
 * 真实路径再统计；统计失败只返回 null，不影响下载本身。
 */
internal object AndroidStorageProbe {
    fun read(context: Context, path: String): AndroidStorageStats? = runCatching {
        val resolvedPath = if (path.startsWith("content://")) {
            val volumePath = runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    context.getSystemService(StorageManager::class.java)
                        ?.getStorageVolume(Uri.parse(path))
                        ?.directory
                        ?.absolutePath
                } else {
                    null
                }
            }.getOrNull()
            volumePath ?: Environment.getExternalStorageDirectory().absolutePath
        } else {
            path.takeIf { it.isNotBlank() }
        } ?: context.filesDir.absolutePath
        val stat = StatFs(resolvedPath)
        val total = stat.blockCountLong * stat.blockSizeLong
        val free = stat.availableBlocksLong * stat.blockSizeLong
        AndroidStorageStats(total, free.coerceIn(0L, total))
    }.getOrNull()?.takeIf { it.totalBytes > 0L }
}
