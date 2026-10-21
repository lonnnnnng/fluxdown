package dev.fluxdown.android.platform

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import dev.fluxdown.android.data.QueueTask
import dev.fluxdown.android.ui.i18n.Str
import dev.fluxdown.android.ui.i18n.trApp

/**
 * 作者: long
 * 完成任务的真实产物可能在应用私有目录，也可能已被复制到 SAF 目录；统一解析成可授权的 content URI，
 * 避免把私有路径直接交给其他应用，也避免 SAF 目录被误当作 POSIX 文件路径。
 */
internal class TaskFileDispatcher(
    private val context: Context,
    private val fileResolver: TaskFileResolver,
) {
    /** 返回 null 表示已成功交给系统；非空字符串是需要展示给用户的失败提示。 */
    suspend fun dispatch(task: QueueTask, action: String, relativePath: String? = null): String? {
        val resolved = runCatching { fileResolver.resolve(task, relativePath) }.getOrNull()
            ?: return trApp(Str.FileNotFound)
        val intent = Intent(action).apply {
            setDataAndType(resolved.uri, resolved.mimeType)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            if (action == Intent.ACTION_SEND) {
                putExtra(Intent.EXTRA_STREAM, resolved.uri)
            }
        }
        return try {
            context.startActivity(
                Intent.createChooser(intent, if (action == Intent.ACTION_SEND) trApp(Str.ShareFile) else trApp(Str.OpenFile))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            null
        } catch (_: ActivityNotFoundException) {
            trApp(Str.NoAppForFileType)
        } catch (error: RuntimeException) {
            trApp(Str.CannotActOnFile, if (action == Intent.ACTION_SEND) trApp(Str.ActionShare) else trApp(Str.ActionOpen), error.message ?: trApp(Str.UnknownError))
        }
    }

    /** ed2k 由外部客户端接管，这里只负责构造交给系统的意图。 */
    fun ed2kIntent(source: String): Intent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(source)).apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    /** 系统里是否有能接收 ed2k 链接的应用；没有时不应写入队列。 */
    fun canHandoffEd2k(source: String): Boolean =
        ed2kIntent(source).resolveActivity(context.packageManager) != null

    /** 把 ed2k 链接交给外部客户端；返回是否成功唤起。 */
    fun handoffEd2k(source: String): Boolean =
        runCatching { context.startActivity(ed2kIntent(source)) }.isSuccess
}
