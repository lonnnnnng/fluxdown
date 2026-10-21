package dev.fluxdown.android.platform

import android.content.ClipboardManager
import android.content.Context

/**
 * 作者: long
 * 剪贴板读取入口。Android 10 起剪贴板只在应用处于前台时可读，Android 13 起读取会由系统弹出
 * "已粘贴自…"提示——这是系统行为，无法也不应绕过；因此这里只在启动/回前台时读一次，
 * 并且由设置开关（S5）和"同一链接不重复提示"共同限制读取频率。
 */
internal object ClipboardSourceReader {
    fun read(context: Context): String? {
        val manager = context.getSystemService(ClipboardManager::class.java) ?: return null
        if (!manager.hasPrimaryClip()) return null
        val clip = manager.primaryClip ?: return null
        if (clip.description?.mimeTypeCount == 0) return null
        val text = runCatching { clip.getItemAt(0)?.coerceToText(context)?.toString() }.getOrNull() ?: return null
        return text.takeIf { it.isNotBlank() }
    }
}
