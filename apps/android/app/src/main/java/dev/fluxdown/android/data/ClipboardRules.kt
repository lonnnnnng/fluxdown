package dev.fluxdown.android.data

/**
 * 作者: long
 * 剪贴板链接识别规则。剪贴板里经常混着标题、说明和换行，这里只做"切分出候选 + 交给协议识别器判定"
 * 两件事，保持纯函数以便在 JVM 单测里覆盖，不依赖 Android ClipboardManager。
 */
internal fun clipboardDownloadSource(raw: String?, detectProtocol: (String) -> String?): String? {
    val text = raw?.trim()?.takeIf { it.isNotEmpty() && it.length <= MAX_CLIPBOARD_LENGTH } ?: return null
    val candidates = text
        .lineSequence()
        .flatMap { line -> line.split(' ', '\t', '\r', '，', '。').asSequence() }
        .map { it.trim().trim('"', '\'', '<', '>', '(', ')', '[', ']', '“', '”', '《', '》') }
        .filter { it.length in MIN_CANDIDATE_LENGTH..MAX_CANDIDATE_LENGTH }
    for (candidate in candidates) {
        // 作者: long
        // 只认协议识别器能识别的片段：普通文本（例如一段中文说明）不会被当成下载源，
        // 也避免把 "file://" 之类的本地路径误判为可下载链接。
        if (detectProtocol(candidate)?.let { it != "unknown" } == true) return candidate
    }
    return null
}

private const val MAX_CLIPBOARD_LENGTH = 8_192
private const val MIN_CANDIDATE_LENGTH = 8
private const val MAX_CANDIDATE_LENGTH = 4_096
