package dev.fluxdown.android.platform

import android.content.Context
import android.net.Uri
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import androidx.documentfile.provider.DocumentFile
import dev.fluxdown.android.data.QueueTask
import org.json.JSONArray
import java.io.File

/** 解析结果统一成 content URI，跨应用打开/分享时才能安全授权。 */
internal data class ResolvedTaskFile(
    val uri: Uri,
    val mimeType: String,
)

/**
 * 作者: long
 * 完成任务的文件定位。真实产物可能在应用私有目录，也可能已被复制到用户授权的 SAF 目录；
 * 这里把两种来源统一解析成可授权的 content URI，避免把私有路径直接交给其他应用。
 */
internal class TaskFileResolver(
    private val context: Context,
    private val settingsStore: AndroidSettingsStore,
) {
    fun resolve(task: QueueTask, relativePath: String?): ResolvedTaskFile? {
        val safTarget = settingsStore.safTarget(task.id)
        return if (safTarget != null) {
            resolveSaf(task, safTarget, relativePath)
        } else {
            resolveLocal(task, relativePath)
        }
    }

    private fun resolveLocal(task: QueueTask, relativePath: String?): ResolvedTaskFile? {
        val root = File(task.outputDir)
        if (!root.isDirectory) return null
        val file = taskOutputPaths(task, relativePath)
            .mapNotNull { safeChild(root, it) }
            .firstOrNull { it.isFile }
            ?: return null
        val uri = runCatching {
            FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        }.getOrNull() ?: return null
        return ResolvedTaskFile(uri, mimeTypeFor(file.name))
    }

    private fun resolveSaf(task: QueueTask, target: String, relativePath: String?): ResolvedTaskFile? {
        if (!settingsStore.isSafCopied(task.id)) return null
        val root = DocumentFile.fromTreeUri(context, Uri.parse(target)) ?: return null
        val recorded = settingsStore.safFiles(task.id)?.let { raw ->
            runCatching {
                val array = JSONArray(raw)
                (0 until array.length()).mapNotNull { array.optString(it).takeIf(String::isNotBlank) }
            }.getOrNull()
        }.orEmpty()
        val paths = ((if (relativePath == null) recorded else emptyList()) + taskOutputPaths(task, relativePath)).distinct()
        val document = paths.asSequence()
            .mapNotNull { findSafFile(root, it) }
            .firstOrNull { it.isFile }
            ?: return null
        return ResolvedTaskFile(
            document.uri,
            document.type ?: mimeTypeFor(document.name ?: ""),
        )
    }

    /** 防止 `..` 逃出下载根目录；canonicalFile 会把符号链接一并解析掉。 */
    private fun safeChild(root: File, relativePath: String): File? {
        val candidate = runCatching { File(root, relativePath).canonicalFile }.getOrNull() ?: return null
        val canonicalRoot = runCatching { root.canonicalFile }.getOrNull() ?: return null
        val rootPrefix = canonicalRoot.path + File.separator
        return candidate.takeIf { it.path == canonicalRoot.path || it.path.startsWith(rootPrefix) }
    }

    private fun findSafFile(root: DocumentFile, relativePath: String): DocumentFile? {
        val components = relativePath.replace('\\', '/').split('/')
        if (components.isEmpty() || components.any { it.isBlank() || it == "." || it == ".." }) return null
        var current = root
        for (component in components) {
            current = current.findFile(component) ?: return null
        }
        return current
    }

    /**
     * 完成任务的候选相对路径：多文件种子先按种子内路径匹配，再按"种子目录/路径"匹配；
     * 单文件任务额外尝试 HLS 转封装后的 mp4/ts 名字。
     */
    private fun taskOutputPaths(task: QueueTask, relativePath: String?): List<String> = buildList {
        task.torrentFiles
            .filter {
                (task.torrentFileIndices.isEmpty() || it.index in task.torrentFileIndices) &&
                    (relativePath == null || it.path == relativePath)
            }
            .forEach { file ->
                add(file.path)
                task.torrentName?.takeIf { it.isNotBlank() }?.let { add("$it/${file.path}") }
            }
        if (relativePath != null) return@buildList
        add(task.name)
        if (task.source.substringBefore('?').endsWith(".m3u8", ignoreCase = true)) {
            val stem = task.name.substringBeforeLast('.', task.name)
            add("$stem.mp4")
            add("$stem.ts")
        }
    }.distinct()

    private fun mimeTypeFor(name: String): String {
        val extension = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "application/octet-stream"
    }
}
