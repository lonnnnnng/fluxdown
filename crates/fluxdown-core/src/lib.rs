mod downloader;
mod protocol;
mod runner;
mod store;
mod task;
pub mod torrent_details;

// 作者: long
// 三端使用同一组下载策略默认值，避免 CLI、桌面后端和移动 FFI 在调用方未传配置时出现不同的调度行为。
pub const DEFAULT_QUEUE_CONCURRENCY: usize = 5;
pub const DEFAULT_DOWNLOAD_THREAD_COUNT: usize = 16;
pub const DEFAULT_RETRY_ATTEMPTS: usize = 3;

pub use downloader::{
    CancelToken, DownloadEngine, DownloadError, DownloadOptions, DownloadProgress, DownloadSummary,
    HlsVariantInfo, hls_variants,
};
pub use protocol::{
    Backend, BackendAvailability, DoctorReport, Protocol, RuntimeSupportStatus, SupportStatus,
    backend_availability, detect_protocol, doctor_report, runtime_support_status, support_status,
};
pub use runner::{
    QueueRunReport, QueueRunner, QueueRunnerError, QueueRunnerOptions, TaskRunReport,
};
pub use store::{TaskStore, TaskStoreError, default_store_path};
pub use task::{
    DownloadRequest, DownloadState, DownloadTask, TorrentFileMetadata, normalize_sha256_text,
    normalize_torrent_file_metadata, normalize_torrent_name, redact_url_credentials,
    redact_url_credentials_in_text, sanitize_download_file_name, suggested_download_file_name,
    validate_sha256_text,
};
pub use torrent_details::{
    TorrentDetails, TorrentDetailsFile, TorrentPeerSummary, torrent_details,
};

#[cfg(test)]
mod default_tests {
    use super::*;

    #[test]
    fn shared_download_defaults_match_product_settings() {
        let runner = QueueRunnerOptions::default();

        assert_eq!(DEFAULT_QUEUE_CONCURRENCY, 5);
        assert_eq!(DEFAULT_DOWNLOAD_THREAD_COUNT, 16);
        assert_eq!(DEFAULT_RETRY_ATTEMPTS, 3);
        assert_eq!(runner.retry_attempts, DEFAULT_RETRY_ATTEMPTS);
        assert_eq!(runner.download.thread_count, DEFAULT_DOWNLOAD_THREAD_COUNT);
    }
}
