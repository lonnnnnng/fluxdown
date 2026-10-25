package dev.fluxdown.android.ui.i18n

import androidx.compose.runtime.Composable

/**
 * 作者: long
 * Rust 队列里的 `error_code` 是跨端契约，界面据此本地化；`error` 文案只作为
 * 未知错误码（旧队列、未来新增变体）的兜底，避免把中文原文当成唯一展示来源。
 *
 * 新增 Rust 变体时同步在 [errorTextKey] 里登记，`ErrorTextTest` 会校验两边一致。
 */
internal fun errorTextKey(code: String?): Str? = when (code) {
    "http_auth" -> Str.ErrHttpAuth
    "http_not_found" -> Str.ErrHttpNotFound
    "http_timeout" -> Str.ErrHttpTimeout
    "http_rate_limited" -> Str.ErrHttpRateLimited
    "http_server_error" -> Str.ErrHttpServerError
    "http_status" -> Str.ErrHttpStatus
    "network_timeout" -> Str.ErrNetworkTimeout
    "network_error" -> Str.ErrNetworkError
    "http_range" -> Str.ErrHttpRange
    "incomplete_transfer" -> Str.ErrIncompleteTransfer
    "local_size_anomaly" -> Str.ErrLocalSizeAnomaly
    "disk_full" -> Str.ErrDiskFull
    "storage_permission" -> Str.ErrStoragePermission
    "invalid_output_path" -> Str.ErrInvalidOutputPath
    "network_interrupted" -> Str.ErrNetworkInterrupted
    "io_error" -> Str.ErrIo
    "invalid_url" -> Str.ErrInvalidUrl
    "unsupported_protocol" -> Str.ErrUnsupportedProtocol
    "missing_backend" -> Str.ErrMissingBackend
    "external_backend_failed" -> Str.ErrExternalBackendFailed
    "handoff_failed" -> Str.ErrHandoffFailed
    "missing_file_name" -> Str.ErrMissingFileName
    "invalid_playlist" -> Str.ErrInvalidPlaylist
    "hls_unsupported_encryption" -> Str.ErrHlsEncryption
    "hls_key_invalid" -> Str.ErrHlsKeyInvalid
    "hls_range_invalid" -> Str.ErrHlsRangeInvalid
    "hls_remux_failed" -> Str.ErrHlsRemuxFailed
    "hls_variant_out_of_range" -> Str.ErrHlsVariantOutOfRange
    "ftp_auth" -> Str.ErrFtpAuth
    "ftp_not_found" -> Str.ErrFtpNotFound
    "ftps_tls" -> Str.ErrFtpsTls
    "ftps_session_reuse" -> Str.ErrFtpsSessionReuse
    "ftp_interrupted" -> Str.ErrFtpInterrupted
    "ftp_failed" -> Str.ErrFtpFailed
    "sftp_auth" -> Str.ErrSftpAuth
    "sftp_not_found" -> Str.ErrSftpNotFound
    "sftp_interrupted" -> Str.ErrSftpInterrupted
    "sftp_failed" -> Str.ErrSftpFailed
    "sftp_host_key" -> Str.ErrSftpHostKey
    "smb_auth" -> Str.ErrSmbAuth
    "smb_access_denied" -> Str.ErrSmbAccessDenied
    "smb_not_found" -> Str.ErrSmbNotFound
    "smb_disk_full" -> Str.ErrSmbDiskFull
    "smb_interrupted" -> Str.ErrSmbInterrupted
    "smb_failed" -> Str.ErrSmbFailed
    "torrent_stalled" -> Str.ErrTorrentStalled
    "torrent_failed" -> Str.ErrTorrentFailed
    "torrent_source_unreadable" -> Str.ErrTorrentSourceUnreadable
    "credential_unavailable" -> Str.ErrCredentialUnavailable
    "credential_conflict" -> Str.ErrCredentialConflict
    "credential_unsupported_protocol" -> Str.ErrCredentialUnsupported
    "interrupted" -> Str.ErrInterrupted
    "sha256_invalid" -> Str.ErrSha256Invalid
    "sha256_unsupported_output" -> Str.ErrSha256UnsupportedOutput
    "sha256_mismatch" -> Str.ErrSha256Mismatch
    "paused" -> Str.ErrPaused
    else -> null
}

/** 界面取错误文案：已知错误码按当前语言渲染，未知码回退 Rust 写入的原文。 */
@Composable
internal fun localizedError(code: String?, raw: String?): String? {
    val key = errorTextKey(code)
    if (key != null) return tr(key)
    return raw?.takeIf { it.isNotBlank() }
}

/** 非 Composable 场景（通知、前台服务）取错误文案。 */
internal fun localizedErrorIn(language: String, code: String?, raw: String?): String? {
    val key = errorTextKey(code)
    if (key != null) return trIn(language, key)
    return raw?.takeIf { it.isNotBlank() }
}
