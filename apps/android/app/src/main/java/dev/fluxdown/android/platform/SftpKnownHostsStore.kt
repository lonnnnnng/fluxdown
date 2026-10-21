package dev.fluxdown.android.platform

import android.content.Context
import android.net.Uri
import dev.fluxdown.android.data.hasUsableKnownHostEntry
import java.io.File
import java.io.InputStream
import dev.fluxdown.android.ui.i18n.Str
import dev.fluxdown.android.ui.i18n.trApp

/**
 * 作者: long
 * SAF 返回的是 content URI，而 Rust 只能读取 POSIX 文件；因此把 known_hosts 复制到应用私有目录，
 * 只把私有副本路径传给 Rust，避免授权失效或外部文件被替换造成主机密钥策略漂移。
 */
internal class SftpKnownHostsStore(
    private val context: Context,
    private val root: File,
) {
    /** 导入并返回私有副本的绝对路径；内容不合法时抛出带中文说明的异常。 */
    fun import(uri: Uri): String {
        val content = context.contentResolver.openInputStream(uri)?.use(InputStream::readBytes)
            ?.toString(Charsets.UTF_8)?.trim()
            ?: error(trApp(Str.KnownHostsReadFailed))
        require(hasUsableKnownHostEntry(content)) { trApp(Str.KnownHostsNoEntries) }
        val target = File(root, "known_hosts")
        target.writeText(content, Charsets.UTF_8)
        return target.absolutePath
    }

    fun clear(path: String) {
        if (path.isNotBlank()) runCatching { File(path).delete() }
    }
}
