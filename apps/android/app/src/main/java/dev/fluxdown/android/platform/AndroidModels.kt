package dev.fluxdown.android.platform

/**
 * 作者: long
 * 平台层对外暴露的只读模型：凭据内容、存储统计和更新检查结果。
 * 这些类型只描述 Android 侧的事实，不参与 Rust 队列协议。
 */

internal data class StoredAndroidCredential(
    val username: String,
    val password: String = "",
    val privateKeyPem: String? = null,
    val passphrase: String? = null,
) {
    val usesPrivateKey: Boolean
        get() = !privateKeyPem.isNullOrBlank()
}

internal data class AndroidStorageStats(
    val totalBytes: Long,
    val freeBytes: Long,
) {
    val usedBytes: Long
        get() = (totalBytes - freeBytes).coerceIn(0L, totalBytes)
}

internal data class AndroidUpdateReport(
    val currentVersion: String,
    val latestVersion: String,
    val hasUpdate: Boolean,
    val releaseUrl: String,
    val downloadUrl: String?,
    val releaseNotes: String?,
)
