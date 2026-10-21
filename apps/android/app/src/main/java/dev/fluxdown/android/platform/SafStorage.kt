package dev.fluxdown.android.platform

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import dev.fluxdown.android.data.QueueTask
import java.io.File
import java.io.FileInputStream
import java.net.URLConnection
import java.util.UUID
import dev.fluxdown.android.ui.i18n.Str
import dev.fluxdown.android.ui.i18n.trApp

/**
 * 作者: long
 * SAF（Storage Access Framework）落地层。Rust 只能写 POSIX 路径，因此授权目录的下载先落到
 * 应用私有暂存目录，完成后再由这里复制到用户选择的系统目录。
 */
internal class SafStorage(
    private val context: Context,
    private val stagingRoot: File,
) {
    /** 申请持久化读写权限；返回可写的目标目录，失败返回 null 由调用方提示。 */
    fun persistTree(uri: Uri): DocumentFile? = runCatching {
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        context.contentResolver.takePersistableUriPermission(uri, flags)
        DocumentFile.fromTreeUri(context, uri)?.takeIf { it.isDirectory && it.canWrite() }
    }.getOrNull()

    fun isTreeUri(path: String): Boolean = path.trim().startsWith("content://")

    /** 授权目录的任务需要独立的暂存目录，避免多个任务写进同一个 POSIX 目录。 */
    fun newTaskId(outputPath: String): String? =
        outputPath.takeIf(::isTreeUri)?.let { "android-${UUID.randomUUID()}" }

    fun stagingPath(taskId: String): String =
        File(stagingRoot, taskId).apply { mkdirs() }.absolutePath

    fun forget(taskId: String) {
        runCatching { File(stagingRoot, taskId).deleteRecursively() }
    }

    /**
     * 复制暂存目录到 SAF 目标，返回复制成功的相对路径。
     * 跳过 `.part` 未完成分片和点文件，避免把临时产物当成交付内容。
     */
    fun copy(task: QueueTask, target: String): List<String> {
        val sourceRoot = File(task.outputDir)
        require(sourceRoot.isDirectory) { trApp(Str.StagingMissing) }
        val destinationRoot = DocumentFile.fromTreeUri(context, Uri.parse(target))
        require(destinationRoot?.isDirectory == true && destinationRoot.canWrite()) { trApp(Str.PermissionRevoked) }
        val files = sourceRoot.walkTopDown()
            .filter { file ->
                file.isFile &&
                    !file.name.endsWith(".part") &&
                    !file.path.split(File.separatorChar).any { it.startsWith(".") }
            }
            .toList()
        require(files.isNotEmpty()) { trApp(Str.StagingEmpty) }
        return files.map { source -> copyFile(source, sourceRoot, destinationRoot) }
    }

    private fun copyFile(source: File, sourceRoot: File, destinationRoot: DocumentFile): String {
        val relative = source.relativeTo(sourceRoot).invariantSeparatorsPath
        val components = relative.split('/').filter { it.isNotBlank() }
        require(components.isNotEmpty()) { trApp(Str.FileNameInvalid) }
        val parent = components.dropLast(1).fold(destinationRoot) { current, name ->
            current.findFile(name)?.takeIf { it.isDirectory }
                ?: current.createDirectory(name)
                ?: error(trApp(Str.CannotCreateDir, name))
        }
        val name = components.last()
        parent.findFile(name)?.delete()
        val mime = URLConnection.guessContentTypeFromName(name) ?: "application/octet-stream"
        val destination = parent.createFile(mime, name) ?: error(trApp(Str.CannotCreateFile, name))
        context.contentResolver.openOutputStream(destination.uri, "wt")?.use { output ->
            FileInputStream(source).use { input -> input.copyTo(output) }
        } ?: error(trApp(Str.CannotOpenTarget, name))
        return relative
    }
}
