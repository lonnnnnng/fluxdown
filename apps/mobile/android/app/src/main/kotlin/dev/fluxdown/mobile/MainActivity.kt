package dev.fluxdown.mobile

import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.fluxdown.mobile/storage"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getStorageStats" -> {
                    val requestedPath = call.argument<String>("path") ?: filesDir.absolutePath
                    val target = resolveExistingPath(File(requestedPath))
                    try {
                        val stat = StatFs(target.absolutePath)
                        val totalBytes = stat.blockCountLong * stat.blockSizeLong
                        val freeBytes = stat.availableBlocksLong * stat.blockSizeLong
                        result.success(
                            mapOf(
                                "totalBytes" to totalBytes,
                                "freeBytes" to freeBytes
                            )
                        )
                    } catch (error: Exception) {
                        result.error("storage_stats_failed", error.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun resolveExistingPath(file: File): File {
        var current: File? = file
        while (current != null && !current.exists()) {
            current = current.parentFile
        }
        return current ?: filesDir
    }
}
