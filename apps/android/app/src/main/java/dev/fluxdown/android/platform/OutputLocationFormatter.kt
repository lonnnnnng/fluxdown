package dev.fluxdown.android.platform

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import dev.fluxdown.android.ui.i18n.Str
import dev.fluxdown.android.ui.i18n.trApp

/**
 * 作者: long
 * 把保存位置转换成用户能读懂的名字。content:// 目录只能通过 SAF 拿到显示名，
 * 解析失败时回退到固定文案而不是把原始 URI 直接抛给用户。
 */
internal fun formatOutputLocation(context: Context, value: String): String {
    if (!value.startsWith("content://")) return value.ifBlank { trApp(Str.OutputPrivateDirLabel) }
    return runCatching {
        DocumentFile.fromTreeUri(context, Uri.parse(value))?.name ?: trApp(Str.OutputChosenDirLabel)
    }.getOrDefault(trApp(Str.OutputChosenDirLabel))
}
