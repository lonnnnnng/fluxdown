use crate::{
    Backend, CredentialStoreError, DEFAULT_DOWNLOAD_THREAD_COUNT, DownloadRequest, Protocol,
    StoredCredential, backend_availability, get_credential, sanitize_download_file_name,
    suggested_download_file_name, validate_credential_ref, validate_sha256_text,
};
use aes::cipher::{BlockDecryptMut, KeyIvInit, block_padding::Pkcs7};
use futures_util::{StreamExt, stream};
use librqbit::{
    AddTorrent, AddTorrentOptions, Session, SessionOptions, TorrentStatsState, limits::LimitsConfig,
};
use m3u8_rs::{Key, KeyMethod};
use percent_encoding::percent_decode_str;
use reqwest::Client;
use reqwest::StatusCode;
use reqwest::header::{ACCEPT_RANGES, CONTENT_LENGTH, CONTENT_RANGE, RANGE};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use smb2::{ClientConfig, ErrorKind as SmbErrorKind, SmbClient};
use ssh2::{CheckResult, KnownHostFileKind, Session as SshSession};
use std::collections::HashMap;
use std::io::{Read, Seek, Write};
use std::net::{IpAddr, Shutdown, TcpListener, TcpStream};
use std::num::NonZeroU32;
use std::path::{Path, PathBuf};
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64, Ordering},
    mpsc,
};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};
use suppaftp::{
    Mode,
    tokio::{
        AsyncFtpStream, AsyncRustlsConnector, AsyncRustlsFtpStream, ImplAsyncFtpStream,
        TokioTlsStream,
    },
    tokio_rustls,
    types::FileType,
};
use thiserror::Error;
use tokio::fs::{self, File, OpenOptions};
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use tokio::process::Command;
use tokio::sync::Mutex;
use url::Url;

type Aes128CbcDec = cbc::Decryptor<aes::Aes128>;
const HLS_SEGMENT_ATTEMPTS: usize = 3;
const TORRENT_STALL_TIMEOUT: Duration = Duration::from_secs(10 * 60);
const TORRENT_LISTEN_PORT_START: u16 = 49152;
const TORRENT_LISTEN_PORT_END: u16 = 65535;

#[derive(Debug, Error)]
pub enum DownloadError {
    #[error("protocol {0:?} is recognized but not implemented yet")]
    UnsupportedProtocol(Protocol),
    #[error(
        "external backend {backend:?} is required for {protocol:?}; missing command `{command}`"
    )]
    MissingBackend {
        protocol: Protocol,
        backend: Backend,
        command: String,
    },
    #[error(
        "external backend {backend:?} failed for {protocol:?} with exit status {status}: {stderr}"
    )]
    ExternalBackendFailed {
        protocol: Protocol,
        backend: Backend,
        status: String,
        stderr: String,
    },
    #[error("system handoff failed for {protocol:?}: {message}")]
    HandoffFailed { protocol: Protocol, message: String },
    #[error("cannot infer a filename for {0}")]
    MissingFileName(String),
    #[error("invalid url: {0}")]
    InvalidUrl(String),
    #[error(transparent)]
    Http(#[from] reqwest::Error),
    #[error("http range download failed: {0}")]
    HttpRange(String),
    #[error(
        "incomplete {protocol:?} transfer: expected {expected_bytes} bytes, got {actual_bytes}"
    )]
    IncompleteTransfer {
        protocol: Protocol,
        expected_bytes: u64,
        actual_bytes: u64,
    },
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error("invalid m3u8 playlist")]
    InvalidM3u8,
    #[error("unsupported HLS key method: {0}")]
    UnsupportedHlsKeyMethod(String),
    #[error("invalid HLS key: {0}")]
    InvalidHlsKey(String),
    #[error("invalid HLS byte range: {0}")]
    InvalidHlsByteRange(String),
    #[error("HLS segment decryption failed: {0}")]
    HlsDecrypt(String),
    #[error("HLS MP4 remux failed: {0}")]
    HlsRemux(String),
    #[error(
        "torrent made no download progress for {elapsed_secs}s ({downloaded_bytes}/{total_bytes} bytes); check tracker and peers"
    )]
    TorrentStalled {
        downloaded_bytes: u64,
        total_bytes: u64,
        elapsed_secs: u64,
    },
    #[error("invalid ftp url: {0}")]
    InvalidFtpUrl(String),
    #[error("HLS variant index {index} is out of range; {available} variants available")]
    HlsVariantOutOfRange { index: usize, available: usize },
    #[error("torrent source unreadable: {0}")]
    TorrentSourceUnreadable(String),
    #[error("invalid sftp url: {0}")]
    InvalidSftpUrl(String),
    #[error("invalid smb url: {0}")]
    InvalidSmbUrl(String),
    #[error(transparent)]
    Ftp(#[from] suppaftp::FtpError),
    #[error(
        "FTPS data connection failed: {source}; this server likely requires TLS session reuse on the data connection (e.g. vsftpd require_ssl_reuse=YES, Rebex test server), which the FTPS engine does not support yet (upstream suppaftp issue #93)"
    )]
    FtpsDataTls { source: suppaftp::FtpError },
    #[error(transparent)]
    Sftp(#[from] ssh2::Error),
    #[error("SFTP 主机身份校验失败: {message}")]
    SftpHostKeyVerification { message: String },
    #[error("credential reference `{reference}` is unavailable: {reason}")]
    CredentialUnavailable { reference: String, reason: String },
    #[error("credential reference cannot be combined with credentials in the download URL")]
    CredentialConflict,
    #[error("credential reference is not supported for protocol {0:?}")]
    CredentialUnsupportedProtocol(Protocol),
    #[error(transparent)]
    Smb(#[from] smb2::Error),
    #[error(transparent)]
    Torrent(#[from] anyhow::Error),
    #[error("download was paused")]
    Paused,
    #[error("invalid SHA-256 checksum `{value}`; expected 64 hex characters")]
    InvalidSha256 { value: String },
    #[error("SHA-256 checksum only supports file outputs: {path}")]
    Sha256UnsupportedOutput { path: String },
    #[error("SHA-256 mismatch for {path}: expected {expected}, got {actual}")]
    Sha256Mismatch {
        expected: String,
        actual: String,
        path: String,
    },
}

impl DownloadError {
    pub fn is_retryable(&self) -> bool {
        match self {
            Self::Http(error) => http_error_is_retryable(error),
            Self::Io(error) => io_error_is_retryable(error),
            Self::IncompleteTransfer {
                expected_bytes,
                actual_bytes,
                ..
            } => actual_bytes < expected_bytes,
            Self::Ftp(error) => ftp_error_is_retryable(error),
            Self::Sftp(error) => protocol_error_is_retryable(error.message()),
            Self::Smb(error) => {
                error.is_retryable() || matches!(error.kind(), SmbErrorKind::SessionExpired)
            }
            Self::Torrent(error) => protocol_error_is_retryable(&error.to_string()),
            // 作者: long
            // Peer 和 Tracker 属于瞬时网络发现条件，释放旧会话后重建 DHT/Tracker 连接有机会恢复，应纳入用户配置的自动重试。
            Self::TorrentStalled { .. } => true,
            Self::Paused
            | Self::UnsupportedProtocol(_)
            | Self::MissingBackend { .. }
            | Self::ExternalBackendFailed { .. }
            | Self::HandoffFailed { .. }
            | Self::MissingFileName(_)
            | Self::InvalidUrl(_)
            | Self::HttpRange(_)
            | Self::InvalidM3u8
            | Self::UnsupportedHlsKeyMethod(_)
            | Self::InvalidHlsKey(_)
            | Self::InvalidHlsByteRange(_)
            | Self::HlsDecrypt(_)
            | Self::HlsRemux(_)
            | Self::InvalidFtpUrl(_)
            | Self::HlsVariantOutOfRange { .. }
            | Self::TorrentSourceUnreadable(_)
            | Self::InvalidSftpUrl(_)
            | Self::SftpHostKeyVerification { .. }
            | Self::CredentialUnavailable { .. }
            | Self::CredentialConflict
            | Self::CredentialUnsupportedProtocol(_)
            | Self::InvalidSmbUrl(_)
            | Self::FtpsDataTls { .. }
            | Self::InvalidSha256 { .. }
            | Self::Sha256UnsupportedOutput { .. }
            | Self::Sha256Mismatch { .. } => false,
        }
    }

    pub fn user_message(&self) -> String {
        match self {
            Self::Http(error) => http_error_user_message(error),
            Self::Io(error) => io_error_user_message(error),
            Self::IncompleteTransfer {
                protocol,
                expected_bytes,
                actual_bytes,
            } => format!(
                "{} {}",
                protocol.as_str().to_ascii_uppercase(),
                if actual_bytes < expected_bytes {
                    format!(
                        "传输中断：已下载 {actual_bytes}/{expected_bytes} 字节，请检查网络后重试。"
                    )
                } else {
                    format!(
                        "本地文件大小异常：已有 {actual_bytes} 字节，远端为 {expected_bytes} 字节，请重新下载。"
                    )
                }
            ),
            Self::Ftp(error) => ftp_error_user_message(error),
            Self::FtpsDataTls { .. } => {
                "FTPS 数据连接失败：服务器要求复用 TLS 会话，当前内建引擎暂不兼容该服务端配置。"
                    .to_string()
            }
            Self::Sftp(error) => protocol_error_user_message("SFTP", error.message()),
            Self::SftpHostKeyVerification { .. } => {
                "SFTP 主机身份校验失败，请检查 known_hosts 中的主机指纹和端口。".to_string()
            }
            Self::CredentialUnavailable { .. } => {
                "下载凭据不可用，请检查系统凭据库中的引用和权限。".to_string()
            }
            Self::CredentialConflict => {
                "下载链接已经包含用户名或密码，不能同时使用凭据引用。".to_string()
            }
            Self::CredentialUnsupportedProtocol(protocol) => format!(
                "{} 协议当前不能使用凭据引用，请直接使用协议支持的认证方式。",
                protocol.as_str().to_ascii_uppercase()
            ),
            Self::Smb(error) => smb_error_user_message(error),
            Self::TorrentStalled { .. } => {
                "暂无可用 Peer 或 Tracker 未响应，请检查网络、Tracker 后稍后重试。".to_string()
            }
            Self::Torrent(error) => protocol_error_user_message("Torrent", &error.to_string()),
            Self::UnsupportedProtocol(protocol) => format!(
                "暂不支持 {} 协议，请检查链接或改用受支持的下载方式。",
                protocol.as_str()
            ),
            Self::MissingBackend { command, .. } => {
                format!("缺少外部下载组件 `{command}`，请安装后重试。")
            }
            Self::ExternalBackendFailed { .. } => {
                "外部下载组件执行失败，请检查组件状态后重试。".to_string()
            }
            Self::HandoffFailed { .. } => {
                "无法移交给系统或外部应用，请确认已安装可处理该链接的应用。".to_string()
            }
            Self::MissingFileName(_) => {
                "无法从链接识别文件名，请在新建任务时手动填写文件名。".to_string()
            }
            Self::InvalidUrl(_)
            | Self::InvalidFtpUrl(_)
            | Self::InvalidSftpUrl(_)
            | Self::InvalidSmbUrl(_) => {
                "下载链接格式无效，请检查协议、主机和文件路径。".to_string()
            }
            Self::HttpRange(_) => {
                "服务器的分段下载响应无效，请降低下载线程数或更换下载源。".to_string()
            }
            Self::InvalidM3u8 => "HLS 播放列表无效或没有可下载分片。".to_string(),
            Self::UnsupportedHlsKeyMethod(_) => {
                "HLS 使用了暂不支持的加密方式，无法下载该资源。".to_string()
            }
            Self::InvalidHlsKey(_) | Self::HlsDecrypt(_) => {
                "HLS 密钥无效或分片解密失败，请检查资源是否已过期。".to_string()
            }
            Self::InvalidHlsByteRange(_) => {
                "HLS 分片范围无效，请检查播放列表或更换下载源。".to_string()
            }
            Self::HlsRemux(_) => {
                "HLS 转封装失败，请确认 FFmpeg 可用，或改为保留 TS 文件。".to_string()
            }
            Self::HlsVariantOutOfRange { available, .. } => {
                format!("所选 HLS 清晰度已失效，当前可用清晰度共 {available} 个，请重新选择。")
            }
            Self::TorrentSourceUnreadable(_) => {
                "Torrent 文件无法读取，请检查文件是否存在且有访问权限。".to_string()
            }
            Self::Paused => "下载已暂停，可在任务列表中继续。".to_string(),
            Self::InvalidSha256 { .. } => {
                "SHA-256 格式无效，请填写 64 位十六进制校验值。".to_string()
            }
            Self::Sha256UnsupportedOutput { .. } => {
                "该任务输出为文件夹，暂不支持单文件 SHA-256 校验。".to_string()
            }
            Self::Sha256Mismatch {
                expected,
                actual,
                path,
            } => format!(
                "SHA-256 mismatch（校验不一致）：期望 {expected}，实际 {actual}，文件 {path}。请删除损坏文件后重新下载。"
            ),
        }
    }
}

fn http_error_is_retryable(error: &reqwest::Error) -> bool {
    if let Some(status) = error.status() {
        return status == StatusCode::REQUEST_TIMEOUT
            || status == StatusCode::TOO_MANY_REQUESTS
            || status.is_server_error();
    }
    // 作者: long
    // reqwest 在响应体已开始读取后遇到对端断开时，不同 hyper 版本可能分别标记为
    // body、request 或仅在错误文本中暴露 EOF；这些都属于网络切换/连接重置的瞬态失败，
    // 必须交给队列重试，不能把已经落盘的部分内容直接定格为最终失败。
    let detail = error.to_string().to_ascii_lowercase();
    error.is_connect()
        || error.is_timeout()
        || error.is_body()
        || error.is_decode()
        || (error.is_request() && !error.is_builder())
        || detail.contains("incomplete")
        || detail.contains("unexpected end")
        || detail.contains("connection reset")
        || detail.contains("connection closed")
        || detail.contains("broken pipe")
}

fn http_error_user_message(error: &reqwest::Error) -> String {
    match error.status() {
        Some(StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN) => {
            "认证失败，请检查下载链接中的账号、密码或访问权限。".to_string()
        }
        Some(StatusCode::NOT_FOUND | StatusCode::GONE) => {
            "下载资源不存在或已失效，请检查链接后重试。".to_string()
        }
        Some(StatusCode::REQUEST_TIMEOUT) => "服务器响应超时，请检查网络后重试。".to_string(),
        Some(StatusCode::TOO_MANY_REQUESTS) => "服务器请求过于频繁，请稍后重试。".to_string(),
        Some(status) if status.is_server_error() => {
            format!("服务器暂时不可用（HTTP {status}），请稍后重试。")
        }
        Some(status) => format!("下载请求失败（HTTP {status}），请检查链接和访问权限。"),
        None if error.is_timeout() => "网络请求超时，请检查网络后重试。".to_string(),
        None => "网络连接失败，请检查网络、代理或服务器地址后重试。".to_string(),
    }
}

fn io_error_is_retryable(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        std::io::ErrorKind::ConnectionRefused
            | std::io::ErrorKind::ConnectionReset
            | std::io::ErrorKind::ConnectionAborted
            | std::io::ErrorKind::NotConnected
            | std::io::ErrorKind::TimedOut
            | std::io::ErrorKind::Interrupted
            | std::io::ErrorKind::WouldBlock
            | std::io::ErrorKind::NetworkUnreachable
            | std::io::ErrorKind::HostUnreachable
            | std::io::ErrorKind::BrokenPipe
            | std::io::ErrorKind::UnexpectedEof
    )
}

fn io_error_user_message(error: &std::io::Error) -> String {
    match error.kind() {
        std::io::ErrorKind::StorageFull => {
            "磁盘空间不足，请释放空间或更换下载保存位置。".to_string()
        }
        std::io::ErrorKind::PermissionDenied | std::io::ErrorKind::ReadOnlyFilesystem => {
            "当前下载保存位置不可写，请重新选择目录并授予访问权限。".to_string()
        }
        std::io::ErrorKind::NotADirectory
        | std::io::ErrorKind::IsADirectory
        | std::io::ErrorKind::AlreadyExists => {
            "下载保存位置无效，请重新选择一个可写目录。".to_string()
        }
        kind if io_error_is_retryable(error) => {
            format!("网络传输中断（{kind:?}），请检查网络后重试。")
        }
        _ => "文件读写失败，请检查下载保存位置和存储设备后重试。".to_string(),
    }
}

fn ftp_error_is_retryable(error: &suppaftp::FtpError) -> bool {
    match error {
        suppaftp::FtpError::ConnectionError(error) => io_error_is_retryable(error),
        suppaftp::FtpError::UnexpectedResponse(response) => {
            matches!(
                response.status.code(),
                421 | 425 | 426 | 434 | 450 | 451 | 452
            )
        }
        _ => false,
    }
}

fn ftp_error_user_message(error: &suppaftp::FtpError) -> String {
    match error {
        suppaftp::FtpError::UnexpectedResponse(response)
            if matches!(response.status.code(), 430 | 530 | 532) =>
        {
            "FTP 认证失败，请检查账号、密码和目录权限。".to_string()
        }
        suppaftp::FtpError::UnexpectedResponse(response)
            if matches!(response.status.code(), 550) =>
        {
            "FTP 文件不存在或没有访问权限，请检查远程路径。".to_string()
        }
        suppaftp::FtpError::SecureError(_) => {
            "FTPS 证书或 TLS 握手失败，请检查服务端证书和连接模式。".to_string()
        }
        _ if ftp_error_is_retryable(error) => {
            "FTP 连接中断或服务器暂时不可用，请检查网络后重试。".to_string()
        }
        _ => "FTP 下载失败，请检查服务器地址、远程路径和连接模式。".to_string(),
    }
}

fn protocol_error_is_retryable(message: &str) -> bool {
    let message = message.to_ascii_lowercase();
    contains_any(
        &message,
        &[
            "timeout",
            "timed out",
            "connection reset",
            "connection refused",
            "connection closed",
            "disconnected",
            "socket",
            "network unreachable",
            "host unreachable",
            "temporarily unavailable",
        ],
    )
}

fn protocol_error_user_message(protocol: &str, message: &str) -> String {
    let normalized = message.to_ascii_lowercase();
    if contains_any(
        &normalized,
        &[
            "authentication",
            "permission denied",
            "access denied",
            "password",
        ],
    ) {
        return format!("{protocol} 认证失败，请检查账号、密码和访问权限。");
    }
    if contains_any(&normalized, &["not found", "no such file"]) {
        return format!("{protocol} 文件不存在，请检查远程路径。");
    }
    if contains_any(&normalized, &["peer", "tracker", "no download progress"]) {
        return "暂无可用 Peer 或 Tracker 未响应，请检查网络、Tracker 后稍后重试。".to_string();
    }
    if protocol_error_is_retryable(message) {
        return format!("{protocol} 连接中断或服务器暂时不可用，请检查网络后重试。");
    }
    format!("{protocol} 下载失败，请检查链接、服务端配置和访问权限。")
}

fn smb_error_user_message(error: &smb2::Error) -> String {
    match error.kind() {
        SmbErrorKind::AuthRequired | SmbErrorKind::SigningRequired => {
            "SMB 认证失败，请检查账号、密码、域和签名设置。".to_string()
        }
        SmbErrorKind::AccessDenied => "SMB 文件没有访问权限，请检查共享目录权限。".to_string(),
        SmbErrorKind::NotFound => "SMB 文件或共享目录不存在，请检查路径。".to_string(),
        SmbErrorKind::DiskFull => "SMB 服务端磁盘空间不足，无法继续下载。".to_string(),
        SmbErrorKind::ConnectionLost | SmbErrorKind::TimedOut | SmbErrorKind::SessionExpired => {
            "SMB 连接中断或会话已过期，请检查网络后重试。".to_string()
        }
        _ => "SMB 下载失败，请检查共享地址、路径和服务端配置。".to_string(),
    }
}

fn contains_any(message: &str, needles: &[&str]) -> bool {
    needles.iter().any(|needle| message.contains(needle))
}

fn ensure_transfer_complete(
    protocol: Protocol,
    actual_bytes: u64,
    expected_bytes: Option<u64>,
) -> Result<(), DownloadError> {
    let Some(expected_bytes) = expected_bytes else {
        return Ok(());
    };
    if actual_bytes == expected_bytes {
        return Ok(());
    }
    Err(DownloadError::IncompleteTransfer {
        protocol,
        expected_bytes,
        actual_bytes,
    })
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadProgress {
    pub downloaded_bytes: u64,
    pub total_bytes: Option<u64>,
}

pub type ProgressCallback = Arc<dyn Fn(DownloadProgress) + Send + Sync>;

#[derive(Debug, Clone, Default)]
pub struct CancelToken {
    cancelled: Arc<AtomicBool>,
}

impl CancelToken {
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadSummary {
    pub protocol: Protocol,
    pub backend: Backend,
    pub output_path: PathBuf,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    pub bytes_written: u64,
    pub resumed_from: u64,
    pub total_bytes: Option<u64>,
    pub segments_written: Option<usize>,
    pub sha256: Option<String>,
}

/// 单次运行的 SFTP 跳板配置；不参与任务序列化，避免把跳板凭据写入队列。
#[derive(Debug, Clone)]
pub struct SftpJumpOptions {
    pub address: String,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub password: Option<String>,
    pub known_hosts: Option<PathBuf>,
}

impl SftpJumpOptions {
    pub fn from_url(url: &Url, known_hosts: Option<PathBuf>) -> Result<Self, DownloadError> {
        if url.scheme() != "sftp" || url.path() != "" && url.path() != "/" {
            return Err(DownloadError::InvalidSftpUrl(
                "sftp jump url must contain only an authority".to_string(),
            ));
        }
        let host = url
            .host_str()
            .ok_or_else(|| DownloadError::InvalidSftpUrl(url.to_string()))?;
        if url.username().is_empty() {
            return Err(DownloadError::InvalidSftpUrl(
                "sftp jump url must include a username".to_string(),
            ));
        }
        let port = url.port().unwrap_or(22);
        Ok(Self {
            address: format!("{host}:{port}"),
            host: host.to_string(),
            port,
            username: percent_decode(url.username()),
            password: url.password().map(percent_decode),
            known_hosts: known_hosts.filter(|path| !path.as_os_str().is_empty()),
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadOptions {
    pub thread_count: usize,
    pub speed_limit_bps: Option<u64>,
    #[serde(default)]
    pub restart_existing: bool,
    #[serde(default)]
    pub hls_variant_index: Option<usize>,
    #[serde(default)]
    pub hls_keep_transport_stream: bool,
    /// 可选 OpenSSH known_hosts 文件；设置后 SFTP 连接必须匹配主机密钥。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sftp_known_hosts: Option<PathBuf>,
    /// 单次运行的 SFTP 跳板配置；凭据和路径不得进入任务 JSON。
    #[serde(skip)]
    pub sftp_jump: Option<SftpJumpOptions>,
    /// 移动端本次 FFI 运行注入的密码凭据；只存在当前下载 Future 的内存中。
    #[serde(skip)]
    pub runtime_credential: Option<StoredCredential>,
    /// FFI 队列运行时按 task id 提供的临时凭据；不会参与任务或选项序列化。
    #[serde(skip)]
    pub runtime_credentials: HashMap<String, StoredCredential>,
}

impl Default for DownloadOptions {
    fn default() -> Self {
        Self {
            thread_count: DEFAULT_DOWNLOAD_THREAD_COUNT,
            speed_limit_bps: None,
            restart_existing: false,
            hls_variant_index: None,
            hls_keep_transport_stream: false,
            sftp_known_hosts: None,
            sftp_jump: None,
            runtime_credential: None,
            runtime_credentials: HashMap::new(),
        }
    }
}

impl DownloadOptions {
    pub fn new(thread_count: usize, speed_limit_bps: Option<u64>) -> Self {
        Self {
            thread_count: thread_count.clamp(1, 32),
            speed_limit_bps: speed_limit_bps.filter(|limit| *limit > 0),
            restart_existing: false,
            hls_variant_index: None,
            hls_keep_transport_stream: false,
            sftp_known_hosts: None,
            sftp_jump: None,
            runtime_credential: None,
            runtime_credentials: HashMap::new(),
        }
    }

    pub fn with_restart_existing(mut self, restart_existing: bool) -> Self {
        self.restart_existing = restart_existing;
        self
    }

    pub fn with_hls_options(
        mut self,
        hls_variant_index: Option<usize>,
        hls_keep_transport_stream: bool,
    ) -> Self {
        self.hls_variant_index = hls_variant_index;
        self.hls_keep_transport_stream = hls_keep_transport_stream;
        self
    }

    pub fn with_sftp_known_hosts(mut self, path: Option<PathBuf>) -> Self {
        self.sftp_known_hosts = path.filter(|path| !path.as_os_str().is_empty());
        self
    }

    pub fn with_sftp_jump(mut self, jump: Option<SftpJumpOptions>) -> Self {
        self.sftp_jump = jump;
        self
    }

    pub fn with_runtime_credential(mut self, credential: Option<StoredCredential>) -> Self {
        self.runtime_credential = credential;
        self
    }

    pub fn with_runtime_credentials(
        mut self,
        credentials: HashMap<String, StoredCredential>,
    ) -> Self {
        self.runtime_credentials = credentials;
        self
    }
}

#[derive(Debug, Clone)]
pub struct DownloadEngine {
    client: Client,
}

struct HttpRangeDownload {
    client: Client,
    protocol: Protocol,
    url: Url,
    credentials: Option<(String, Option<String>)>,
    output_path: PathBuf,
    thread_count: usize,
    limiter: DownloadSpeedLimiter,
    progress: Option<ProgressCallback>,
    cancel: Option<CancelToken>,
}

struct FtpDownloadContext {
    output_dir: PathBuf,
    spec: FtpDownloadSpec,
    protocol: Protocol,
    progress: Option<ProgressCallback>,
    cancel: Option<CancelToken>,
    options: DownloadOptions,
}

impl Default for DownloadEngine {
    fn default() -> Self {
        Self::new()
    }
}

impl DownloadEngine {
    pub fn new() -> Self {
        Self {
            client: Client::new(),
        }
    }

    pub async fn download(
        &self,
        request: DownloadRequest,
    ) -> Result<DownloadSummary, DownloadError> {
        self.download_with_progress(request, None).await
    }

    pub async fn download_with_options(
        &self,
        request: DownloadRequest,
        options: DownloadOptions,
    ) -> Result<DownloadSummary, DownloadError> {
        self.download_with_progress_and_options(request, None, options)
            .await
    }

    pub async fn download_with_progress(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
    ) -> Result<DownloadSummary, DownloadError> {
        self.download_with_control(request, progress, None).await
    }

    pub async fn download_with_progress_and_options(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
        options: DownloadOptions,
    ) -> Result<DownloadSummary, DownloadError> {
        self.download_with_control_and_options(request, progress, None, options)
            .await
    }

    pub async fn download_with_control(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
        cancel: Option<CancelToken>,
    ) -> Result<DownloadSummary, DownloadError> {
        self.download_with_control_and_options(
            request,
            progress,
            cancel,
            DownloadOptions::default(),
        )
        .await
    }

    pub async fn download_with_control_and_options(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
        cancel: Option<CancelToken>,
        options: DownloadOptions,
    ) -> Result<DownloadSummary, DownloadError> {
        // 作者: long
        // 凭据引用只在本次运行期间解析并注入 URL，队列和任务对象仍只保留引用名，避免把密码写入磁盘。
        let request = request_with_credentials(request, options.runtime_credential.as_ref())?;
        let options = DownloadOptions::new(options.thread_count, options.speed_limit_bps)
            .with_restart_existing(options.restart_existing)
            .with_hls_options(options.hls_variant_index, options.hls_keep_transport_stream)
            .with_sftp_known_hosts(options.sftp_known_hosts.clone())
            .with_sftp_jump(options.sftp_jump.clone())
            .with_runtime_credential(options.runtime_credential.clone());
        let expected_sha256 = request
            .expected_sha256
            .as_deref()
            .map(normalized_expected_sha256)
            .transpose()?;
        if options.restart_existing {
            remove_existing_outputs_for_request(&request).await?;
        }
        let mut summary = match request.protocol() {
            Protocol::Http | Protocol::Https => {
                self.download_http(request, progress, cancel, options).await
            }
            Protocol::Webdav | Protocol::Webdavs => {
                self.download_webdav(request, progress, cancel, options)
                    .await
            }
            Protocol::Ftp | Protocol::Ftps => {
                self.download_ftp(request, progress, cancel, options).await
            }
            Protocol::Torrent | Protocol::Magnet => {
                self.download_torrent(request, progress, cancel, options)
                    .await
            }
            Protocol::M3u8 => self.download_m3u8(request, progress, cancel, options).await,
            Protocol::Sftp => self.download_sftp(request, progress, cancel, options).await,
            Protocol::Ed2k => self.download_with_ed2k(request).await,
            Protocol::Smb => self.download_smb(request, progress, cancel, options).await,
            protocol => Err(DownloadError::UnsupportedProtocol(protocol)),
        }?;
        validate_summary_sha256(&mut summary, expected_sha256.as_deref()).await?;
        Ok(summary)
    }

    async fn download_http(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
        cancel: Option<CancelToken>,
        options: DownloadOptions,
    ) -> Result<DownloadSummary, DownloadError> {
        fs::create_dir_all(&request.output_dir).await?;
        let mut url = Url::parse(&request.source)
            .map_err(|_| DownloadError::InvalidUrl(request.source.clone()))?;
        let client = http_client_for_url(&self.client, &url)?;
        let protocol = request.protocol();
        let file_name = request
            .file_name
            .map(|name| sanitize_download_file_name(&name, "download.bin"))
            .unwrap_or_else(|| infer_file_name(&url, "download.bin"));
        let output_path = request.output_dir.join(file_name);
        let mut existing_bytes = existing_file_size(&output_path).await?;
        let credentials = url_credentials(&mut url)?;
        let limiter = DownloadSpeedLimiter::new(options.speed_limit_bps);

        if existing_bytes == 0
            && options.thread_count > 1
            && let Some(summary) = self
                .download_http_ranges(HttpRangeDownload {
                    client: client.clone(),
                    protocol,
                    url: url.clone(),
                    credentials: credentials.clone(),
                    output_path: output_path.clone(),
                    thread_count: options.thread_count,
                    limiter: limiter.clone(),
                    progress: progress.clone(),
                    cancel: cancel.clone(),
                })
                .await?
        {
            return Ok(summary);
        }

        let mut builder = client.get(url.clone());
        if let Some((username, password)) = credentials.as_ref() {
            builder = builder.basic_auth(username, password.as_ref());
        }
        if existing_bytes > 0 {
            builder = builder.header(RANGE, format!("bytes={existing_bytes}-"));
        }

        let mut response = builder.send().await?;
        if existing_bytes > 0 && response.status() == StatusCode::RANGE_NOT_SATISFIABLE {
            let range_total = unsatisfied_range_total(response.headers().get(CONTENT_RANGE));
            // 作者: long
            // 部分服务器对已完整下载文件只回 416，却省略 Content-Range。
            // 只有响应头或额外 HEAD 明确证明远端长度等于本地长度，才能确认完成，避免把截断文件误判成功。
            let remote_total = if range_total.is_some() {
                range_total
            } else {
                let mut head = client.head(url.clone());
                if let Some((username, password)) = credentials.as_ref() {
                    head = head.basic_auth(username, password.as_ref());
                }
                head.send()
                    .await
                    .ok()
                    .filter(|response| response.status().is_success())
                    .and_then(|response| response.content_length())
            };
            if remote_total == Some(existing_bytes) {
                emit_progress(&progress, existing_bytes, Some(existing_bytes));
                return Ok(DownloadSummary {
                    protocol,
                    backend: Backend::BuiltIn,
                    display_name: display_name_from_path(&output_path),
                    output_path,
                    bytes_written: existing_bytes,
                    resumed_from: existing_bytes,
                    total_bytes: Some(existing_bytes),
                    segments_written: None,
                    sha256: None,
                });
            }

            // 作者: long
            // 本地残留文件比远端新版本更大，或服务端已经不接受这个断点时，继续携带旧 Range
            // 只会反复得到 416。清理残留文件并重新发起无 Range 请求，确保用户点击重试可以恢复。
            let _ = fs::remove_file(&output_path).await;
            existing_bytes = 0;
            let mut restart = client.get(url.clone());
            if let Some((username, password)) = credentials.as_ref() {
                restart = restart.basic_auth(username, password.as_ref());
            }
            response = restart.send().await?;
        }
        let response = response.error_for_status()?;
        let status = response.status();
        let append = existing_bytes > 0 && status == StatusCode::PARTIAL_CONTENT;
        let resumed_from = if append { existing_bytes } else { 0 };
        let total_bytes = infer_total_bytes(response.headers().get(CONTENT_LENGTH), resumed_from);
        let mut stream = response.bytes_stream();
        let mut file = if append {
            let mut file = OpenOptions::new().append(true).open(&output_path).await?;
            file.seek(std::io::SeekFrom::End(0)).await?;
            file
        } else {
            File::create(&output_path).await?
        };
        let mut bytes_written = resumed_from;
        emit_progress(&progress, bytes_written, total_bytes);

        while let Some(chunk) = stream.next().await {
            if is_cancelled(&cancel) {
                file.flush().await?;
                return Err(DownloadError::Paused);
            }
            let chunk = chunk?;
            limiter
                .wait_with_cancel(chunk.len() as u64, cancel.as_ref())
                .await?;
            file.write_all(&chunk).await?;
            bytes_written += chunk.len() as u64;
            emit_progress(&progress, bytes_written, total_bytes);
        }

        file.flush().await?;
        ensure_transfer_complete(protocol, bytes_written, total_bytes)?;

        Ok(DownloadSummary {
            protocol,
            backend: Backend::BuiltIn,
            display_name: display_name_from_path(&output_path),
            output_path,
            bytes_written,
            resumed_from,
            total_bytes,
            segments_written: None,
            sha256: None,
        })
    }

    async fn download_http_ranges(
        &self,
        context: HttpRangeDownload,
    ) -> Result<Option<DownloadSummary>, DownloadError> {
        let HttpRangeDownload {
            client,
            protocol,
            url,
            credentials,
            output_path,
            thread_count,
            limiter,
            progress,
            cancel,
        } = context;
        let mut head = client.head(url.clone());
        if let Some((username, password)) = &credentials {
            head = head.basic_auth(username, password.clone());
        }

        let response = match head.send().await {
            Ok(response) if response.status().is_success() => response,
            _ => return Ok(None),
        };
        let accepts_ranges = response
            .headers()
            .get(ACCEPT_RANGES)
            .and_then(|value| value.to_str().ok())
            .is_some_and(|value| value.eq_ignore_ascii_case("bytes"));
        let Some(total_bytes) = infer_total_bytes(response.headers().get(CONTENT_LENGTH), 0) else {
            return Ok(None);
        };
        if !accepts_ranges || total_bytes == 0 {
            return Ok(None);
        }

        let thread_count = thread_count.min(total_bytes as usize).max(1);
        let chunk_size = total_bytes.div_ceil(thread_count as u64);
        let ranges = (0..thread_count)
            .filter_map(|index| {
                let start = index as u64 * chunk_size;
                if start >= total_bytes {
                    return None;
                }
                let end = (start + chunk_size - 1).min(total_bytes - 1);
                Some((start, end))
            })
            .collect::<Vec<_>>();
        if ranges.len() <= 1 {
            return Ok(None);
        }

        let temp_output_path = range_temp_output_path(&output_path);
        let _ = fs::remove_file(&temp_output_path).await;
        let output = File::create(&temp_output_path).await?;
        output.set_len(total_bytes).await?;
        drop(output);
        let downloaded = Arc::new(AtomicU64::new(0));
        emit_progress(&progress, 0, Some(total_bytes));

        let results = stream::iter(ranges)
            .map(|(start, end)| {
                let client = client.clone();
                let url = url.clone();
                let credentials = credentials.clone();
                let output_path = temp_output_path.clone();
                let progress = progress.clone();
                let cancel = cancel.clone();
                let limiter = limiter.clone();
                let downloaded = Arc::clone(&downloaded);
                async move {
                    if is_cancelled(&cancel) {
                        return Err(DownloadError::Paused);
                    }

                    let mut request = client
                        .get(url)
                        .header(RANGE, format!("bytes={start}-{end}"));
                    if let Some((username, password)) = credentials {
                        request = request.basic_auth(username, password);
                    }
                    let response = request.send().await?;
                    if response.status() == StatusCode::RANGE_NOT_SATISFIABLE {
                        // 作者: long
                        // 部分 CDN/网关虽然 HEAD 声明支持 Range，但实际分片请求可能返回 416；
                        // 这不代表资源不可下载，交由外层清理预分配文件后回退单连接下载。
                        return Err(DownloadError::HttpRange(format!(
                            "server rejected byte range {start}-{end} with HTTP 416"
                        )));
                    }
                    let response = response.error_for_status()?;
                    if response.status() != StatusCode::PARTIAL_CONTENT {
                        return Err(DownloadError::HttpRange(format!(
                            "expected 206 for bytes {start}-{end}, got {}",
                            response.status()
                        )));
                    }

                    let mut file = OpenOptions::new().write(true).open(&output_path).await?;
                    file.seek(std::io::SeekFrom::Start(start)).await?;
                    let mut stream = response.bytes_stream();
                    let mut range_written = 0_u64;
                    while let Some(chunk) = stream.next().await {
                        if is_cancelled(&cancel) {
                            file.flush().await?;
                            return Err(DownloadError::Paused);
                        }
                        let chunk = chunk?;
                        limiter
                            .wait_with_cancel(chunk.len() as u64, cancel.as_ref())
                            .await?;
                        file.write_all(&chunk).await?;
                        range_written += chunk.len() as u64;
                        let total = downloaded.fetch_add(chunk.len() as u64, Ordering::SeqCst)
                            + chunk.len() as u64;
                        emit_progress(&progress, total, Some(total_bytes));
                    }
                    file.flush().await?;

                    let expected = end - start + 1;
                    if range_written != expected {
                        return Err(DownloadError::HttpRange(format!(
                            "expected {expected} bytes for range {start}-{end}, got {range_written}"
                        )));
                    }
                    Ok(())
                }
            })
            .buffer_unordered(thread_count)
            .collect::<Vec<_>>()
            .await;

        let range_rejected = results.iter().any(|item| {
            matches!(
                item,
                Err(DownloadError::HttpRange(message)) if message.contains("HTTP 416")
            )
        });
        let only_range_rejections = results.iter().all(|item| match item {
            Ok(()) => true,
            Err(DownloadError::HttpRange(message)) => message.contains("HTTP 416"),
            Err(_) => false,
        });
        if range_rejected && only_range_rejections {
            let _ = fs::remove_file(&temp_output_path).await;
            return Ok(None);
        }

        for result in results {
            if let Err(error) = result {
                let _ = fs::remove_file(&temp_output_path).await;
                return Err(error);
            }
        }

        let _ = fs::remove_file(&output_path).await;
        fs::rename(&temp_output_path, &output_path).await?;

        Ok(Some(DownloadSummary {
            protocol,
            backend: Backend::BuiltIn,
            display_name: display_name_from_path(&output_path),
            output_path,
            bytes_written: total_bytes,
            resumed_from: 0,
            total_bytes: Some(total_bytes),
            segments_written: None,
            sha256: None,
        }))
    }

    async fn download_webdav(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
        cancel: Option<CancelToken>,
        options: DownloadOptions,
    ) -> Result<DownloadSummary, DownloadError> {
        let protocol = request.protocol();
        let mut http_request = request;
        http_request.source = webdav_http_url(&http_request.source)?;
        let mut summary = self
            .download_http(http_request, progress, cancel, options)
            .await?;
        summary.protocol = protocol;
        Ok(summary)
    }

    async fn download_ftp(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
        cancel: Option<CancelToken>,
        options: DownloadOptions,
    ) -> Result<DownloadSummary, DownloadError> {
        fs::create_dir_all(&request.output_dir).await?;
        let url = Url::parse(&request.source)
            .map_err(|_| DownloadError::InvalidUrl(request.source.clone()))?;
        let protocol = request.protocol();
        let spec = FtpDownloadSpec::from_url(&url, request.file_name.clone())?;
        if protocol == Protocol::Ftps {
            let ftp = connect_ftps(&spec).await?;
            return self
                .download_ftp_stream(
                    ftp,
                    FtpDownloadContext {
                        output_dir: request.output_dir,
                        spec,
                        protocol,
                        progress,
                        cancel,
                        options,
                    },
                )
                .await;
        }

        let ftp = AsyncFtpStream::connect(spec.address.clone()).await?;
        self.download_ftp_stream(
            ftp,
            FtpDownloadContext {
                output_dir: request.output_dir,
                spec,
                protocol,
                progress,
                cancel,
                options,
            },
        )
        .await
    }

    async fn download_ftp_stream<T>(
        &self,
        mut ftp: ImplAsyncFtpStream<T>,
        context: FtpDownloadContext,
    ) -> Result<DownloadSummary, DownloadError>
    where
        T: TokioTlsStream + Send,
    {
        let FtpDownloadContext {
            output_dir,
            spec,
            protocol,
            progress,
            cancel,
            options,
        } = context;
        fs::create_dir_all(&output_dir).await?;
        let output_path = output_dir.join(&spec.file_name);
        let existing_bytes = existing_file_size(&output_path).await?;
        ftp.login(&spec.username, &spec.password).await?;
        ftp.set_mode(Mode::ExtendedPassive);
        ftp.transfer_type(FileType::Binary).await?;
        let total_bytes = ftp
            .size(&spec.remote_path)
            .await
            .ok()
            .map(|size| size as u64);
        if existing_bytes > 0 {
            ftp.resume_transfer(existing_bytes as usize).await?;
        }

        let mut stream = ftp
            .retr_as_stream(&spec.remote_path)
            .await
            .map_err(|error| map_ftp_data_error(protocol, error))?;
        let mut file = if existing_bytes > 0 {
            let mut file = OpenOptions::new().append(true).open(&output_path).await?;
            file.seek(std::io::SeekFrom::End(0)).await?;
            file
        } else {
            File::create(&output_path).await?
        };
        let mut bytes_written = existing_bytes;
        emit_progress(&progress, bytes_written, total_bytes);
        let mut buffer = vec![0_u8; 64 * 1024];
        let limiter = DownloadSpeedLimiter::new(options.speed_limit_bps);

        loop {
            if is_cancelled(&cancel) {
                file.flush().await?;
                drop(stream);
                let _ = ftp.quit().await;
                return Err(DownloadError::Paused);
            }

            let read = stream.read(&mut buffer).await?;
            if read == 0 {
                break;
            }
            limiter
                .wait_with_cancel(read as u64, cancel.as_ref())
                .await?;
            file.write_all(&buffer[..read]).await?;
            bytes_written += read as u64;
            emit_progress(&progress, bytes_written, total_bytes);
        }

        file.flush().await?;
        ftp.finalize_retr_stream(stream)
            .await
            .map_err(|error| map_ftp_data_error(protocol, error))?;
        let _ = ftp.quit().await;
        ensure_transfer_complete(protocol, bytes_written, total_bytes)?;

        Ok(DownloadSummary {
            protocol,
            backend: Backend::BuiltIn,
            display_name: display_name_from_path(&output_path),
            output_path,
            bytes_written,
            resumed_from: existing_bytes,
            total_bytes,
            segments_written: None,
            sha256: None,
        })
    }

    async fn download_torrent(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
        cancel: Option<CancelToken>,
        options: DownloadOptions,
    ) -> Result<DownloadSummary, DownloadError> {
        fs::create_dir_all(&request.output_dir).await?;
        let protocol = request.protocol();
        let add_torrent = torrent_source(&request.source, protocol).await?;
        let session = Session::new_with_opts(
            request.output_dir.clone(),
            torrent_session_options(options.speed_limit_bps),
        )
        .await?;
        let add_response = match session
            .add_torrent(
                add_torrent,
                Some(AddTorrentOptions {
                    overwrite: true,
                    only_files: torrent_only_files(&request),
                    ratelimits: torrent_rate_limits(options.speed_limit_bps),
                    ..Default::default()
                }),
            )
            .await
        {
            Ok(response) => response,
            Err(error) => {
                // 作者: long
                // Session 创建后即可能启动 DHT、Tracker 等后台任务；种子解析或加入失败也必须显式停止，不能只依赖 Arc 析构时机。
                session.stop().await;
                return Err(DownloadError::Torrent(error));
            }
        };
        let Some(handle) = add_response.into_handle() else {
            session.stop().await;
            return Err(DownloadError::Torrent(anyhow::anyhow!(
                "torrent was added in list-only mode"
            )));
        };

        let initial_stats = handle.stats();
        let (initial_progress, initial_total) = torrent_progress_for_request(
            &request,
            &initial_stats.file_progress,
            initial_stats.progress_bytes,
            initial_stats.total_bytes,
            matches!(initial_stats.state, TorrentStatsState::Initializing),
        );
        emit_progress(&progress, initial_progress, Some(initial_total));
        // 作者: long
        // 下载运行期间把会话句柄注册到详情注册表，GUI 才能展示文件列表、peer 与速率；
        // 任何退出路径都必须注销，避免句柄泄漏导致任务结束后仍显示“运行中”。
        if let Some(task_id) = request.task_id.as_deref() {
            crate::torrent_details::register_runtime_handle(task_id, handle.clone());
        }
        let runtime_registered = request.task_id.is_some();
        let runtime_task_id = request.task_id.clone();
        let mut last_progress_at = Instant::now();
        let mut last_progress_bytes = initial_progress;

        let wait_handle = handle.clone();
        let mut wait_task = tokio::spawn(async move { wait_handle.wait_until_completed().await });
        let mut interval = tokio::time::interval(std::time::Duration::from_millis(500));

        loop {
            if is_cancelled(&cancel) {
                if runtime_registered {
                    crate::torrent_details::unregister_runtime_handle(
                        runtime_task_id.as_deref().expect("runtime task id"),
                    );
                }
                wait_task.abort();
                let _ = session.pause(&handle).await;
                session.stop().await;
                return Err(DownloadError::Paused);
            }

            tokio::select! {
                result = &mut wait_task => {
                    match result {
                        Ok(Ok(())) => break,
                        Ok(Err(error)) => {
                            if runtime_registered {
                                crate::torrent_details::unregister_runtime_handle(
                                    runtime_task_id.as_deref().expect("runtime task id"),
                                );
                            }
                            session.stop().await;
                            return Err(DownloadError::Torrent(error));
                        }
                        Err(error) => {
                            if runtime_registered {
                                crate::torrent_details::unregister_runtime_handle(
                                    runtime_task_id.as_deref().expect("runtime task id"),
                                );
                            }
                            session.stop().await;
                            return Err(DownloadError::Torrent(anyhow::anyhow!(
                                "torrent task failed: {error}"
                            )));
                        }
                    }
                }
                _ = interval.tick() => {
                    let stats = handle.stats();
                    let (progress_bytes, total_bytes) = torrent_progress_for_request(
                        &request,
                        &stats.file_progress,
                        stats.progress_bytes,
                        stats.total_bytes,
                        matches!(stats.state, TorrentStatsState::Initializing),
                    );
                    emit_progress(&progress, progress_bytes, Some(total_bytes));
                    if progress_bytes > last_progress_bytes {
                        last_progress_at = Instant::now();
                        last_progress_bytes = progress_bytes;
                    } else if total_bytes > 0
                        && progress_bytes < total_bytes
                        && last_progress_at.elapsed() >= TORRENT_STALL_TIMEOUT
                    {
                        if runtime_registered {
                            crate::torrent_details::unregister_runtime_handle(
                                runtime_task_id.as_deref().expect("runtime task id"),
                            );
                        }
                        wait_task.abort();
                        session.stop().await;
                        return Err(DownloadError::TorrentStalled {
                            downloaded_bytes: progress_bytes,
                            total_bytes,
                            elapsed_secs: last_progress_at.elapsed().as_secs(),
                        });
                    }
                }
            }
        }

        let final_stats = handle.stats();
        let (final_progress, final_total) = torrent_progress_for_request(
            &request,
            &final_stats.file_progress,
            final_stats.progress_bytes,
            final_stats.total_bytes,
            matches!(final_stats.state, TorrentStatsState::Initializing),
        );
        emit_progress(&progress, final_progress, Some(final_total));
        let details_result = handle.with_metadata(|metadata| {
            let payload_file_count = metadata
                .file_infos
                .iter()
                .filter(|file| !file.attrs.padding)
                .count();
            let file_paths = metadata
                .file_infos
                .iter()
                .enumerate()
                .filter(|(index, _)| {
                    request.torrent_file_indices.is_empty()
                        || request.torrent_file_indices.contains(index)
                })
                .filter(|(_, file)| !file.attrs.padding)
                .map(|(_, file)| file.relative_filename.clone())
                .collect::<Vec<_>>();
            torrent_output_details(
                &request.output_dir,
                metadata.name.as_deref(),
                &file_paths,
                payload_file_count,
            )
        });
        if runtime_registered {
            crate::torrent_details::unregister_runtime_handle(
                runtime_task_id.as_deref().expect("runtime task id"),
            );
        }
        session.stop().await;
        ensure_transfer_complete(protocol, final_progress, Some(final_total))?;
        let (output_path, display_name) = details_result?;

        Ok(DownloadSummary {
            protocol,
            backend: Backend::BuiltIn,
            output_path,
            display_name,
            bytes_written: final_progress,
            resumed_from: 0,
            total_bytes: Some(final_total),
            segments_written: None,
            sha256: None,
        })
    }

    async fn download_sftp(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
        cancel: Option<CancelToken>,
        options: DownloadOptions,
    ) -> Result<DownloadSummary, DownloadError> {
        fs::create_dir_all(&request.output_dir).await?;
        let url = Url::parse(&request.source)
            .map_err(|_| DownloadError::InvalidSftpUrl(request.source.clone()))?;
        let spec = SftpDownloadSpec::from_url(&url, request.file_name.clone())?
            .with_runtime_credential(options.runtime_credential.as_ref());
        let output_dir = request.output_dir.clone();
        let cancel_for_task = cancel.clone();
        let progress_for_task = progress.clone();
        let speed_limit_bps = options.speed_limit_bps;
        let known_hosts_path = options.sftp_known_hosts.clone();
        let jump = options.sftp_jump.clone();

        tokio::task::spawn_blocking(move || {
            download_sftp_blocking(
                output_dir,
                spec,
                progress_for_task,
                cancel_for_task,
                speed_limit_bps,
                known_hosts_path,
                jump,
            )
        })
        .await
        .map_err(|error| anyhow::anyhow!("sftp task failed: {error}"))?
    }

    async fn download_m3u8(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
        cancel: Option<CancelToken>,
        options: DownloadOptions,
    ) -> Result<DownloadSummary, DownloadError> {
        fs::create_dir_all(&request.output_dir).await?;
        let playlist_url = Url::parse(&request.source)
            .map_err(|_| DownloadError::InvalidUrl(request.source.clone()))?;
        let playlist_text = self
            .client
            .get(playlist_url.clone())
            .send()
            .await?
            .error_for_status()?
            .text()
            .await?;
        let playlist = m3u8_rs::parse_playlist_res(playlist_text.as_bytes())
            .map_err(|_| DownloadError::InvalidM3u8)?;

        let (media_playlist, media_playlist_url, media_playlist_text) = match playlist {
            m3u8_rs::Playlist::MediaPlaylist(media) => {
                (media, playlist_url.clone(), playlist_text.clone())
            }
            m3u8_rs::Playlist::MasterPlaylist(master) => {
                // 作者: long
                // 支持按清晰度 variant 选择：未指定时保持旧行为取第一个，
                // 指定下标越界时报错而不是悄悄回退，避免用户选错清晰度。
                let variant = match request.hls_variant_index.or(options.hls_variant_index) {
                    Some(index) => master.variants.get(index).ok_or_else(|| {
                        DownloadError::HlsVariantOutOfRange {
                            index,
                            available: master.variants.len(),
                        }
                    })?,
                    None => master.variants.first().ok_or(DownloadError::InvalidM3u8)?,
                };
                let variant_url = playlist_url
                    .join(&variant.uri)
                    .map_err(|_| DownloadError::InvalidM3u8)?;
                let variant_text = self
                    .client
                    .get(variant_url.clone())
                    .send()
                    .await?
                    .error_for_status()?
                    .text()
                    .await?;
                let nested = m3u8_rs::parse_playlist_res(variant_text.as_bytes())
                    .map_err(|_| DownloadError::InvalidM3u8)?;
                match nested {
                    m3u8_rs::Playlist::MediaPlaylist(media) => (media, variant_url, variant_text),
                    _ => return Err(DownloadError::InvalidM3u8),
                }
            }
        };
        ensure_hls_media_has_segments(&media_playlist)?;

        let file_name = request
            .file_name
            .map(|name| sanitize_download_file_name(&name, "stream.mp4"))
            .unwrap_or_else(|| infer_file_name(&playlist_url, "stream.mp4"));
        let requested_output_path = request.output_dir.join(file_name);
        let output_path = hls_mp4_output_name(&requested_output_path);
        let temp_ts_path = hls_temp_transport_path(&output_path);
        let fallback_ts_path = hls_transport_output_name(&requested_output_path);
        // 作者: long
        // `#EXT-X-MAP` 表示后续分片是 fragmented MP4；这类资源已经具备 MP4 容器结构，
        // 不需要依赖移动端通常不存在的 ffmpeg，直接保留初始化段和媒体分片即可播放。
        let init_section = media_playlist
            .segments
            .iter()
            .find_map(|segment| segment.map.clone());
        let is_fmp4 = init_section.is_some();
        // 作者: long
        // 分片落盘到旁挂缓存目录：暂停/失败后任务重新入队时，已完成的分片直接复用，
        // 只补缺失分片；全部合并成功后才清掉缓存目录。
        let segment_cache_dir = hls_segment_cache_dir(&output_path);
        fs::create_dir_all(&segment_cache_dir).await?;

        let mut segment_specs = Vec::with_capacity(media_playlist.segments.len());
        let mut current_hls_key = None;
        let mut next_implicit_byte_range = None;
        for (index, segment) in media_playlist.segments.iter().enumerate() {
            let segment_url = media_playlist_url
                .join(&segment.uri)
                .map_err(|_| DownloadError::InvalidM3u8)?;
            let segment_sequence = media_playlist.media_sequence + index as u64;
            if let Some(key) = &segment.key {
                current_hls_key = Some(key.clone());
            }
            let byte_range = hls_byte_range_for_segment(
                segment.byte_range.as_ref(),
                &segment_url,
                &mut next_implicit_byte_range,
            )?;
            segment_specs.push(HlsSegmentSpec {
                index,
                url: segment_url,
                media_sequence: segment_sequence,
                key: current_hls_key.clone(),
                byte_range,
            });
        }

        // 作者: long
        // 分片缓存必须绑定最终 media playlist 的来源和正文；同一个输出文件名对应的新播放列表
        // 不能误复用旧分片，否则会把不同版本的视频拼接到一起。
        let expected_cache_manifest =
            hls_cache_manifest(&media_playlist_url, &media_playlist_text, &segment_specs);
        let segment_cache_manifest_path = hls_segment_cache_manifest_path(&segment_cache_dir);
        let existing_cache_manifest = fs::read(&segment_cache_manifest_path)
            .await
            .ok()
            .and_then(|bytes| serde_json::from_slice::<HlsCacheManifest>(&bytes).ok());
        let cache_manifest = if existing_cache_manifest.as_ref().is_some_and(|manifest| {
            hls_cache_manifest_matches_source(manifest, &expected_cache_manifest)
        }) {
            existing_cache_manifest.expect("checked above")
        } else {
            let _ = fs::remove_dir_all(&segment_cache_dir).await;
            fs::create_dir_all(&segment_cache_dir).await?;
            write_hls_cache_manifest(&segment_cache_dir, &expected_cache_manifest).await?;
            expected_cache_manifest
        };
        let cache_manifest = Arc::new(Mutex::new(cache_manifest));
        let cache_segments = cache_manifest.lock().await.segments.clone();

        let limiter = DownloadSpeedLimiter::new(options.speed_limit_bps);
        let init_bytes = if let Some(map) = init_section {
            let init_url = media_playlist_url
                .join(&map.uri)
                .map_err(|_| DownloadError::InvalidM3u8)?;
            let init_range = hls_map_byte_range(map.byte_range.as_ref())?;
            self.fetch_hls_segment_with_retry(
                init_url,
                init_range,
                limiter.clone(),
                cancel.clone(),
                HLS_SEGMENT_ATTEMPTS,
            )
            .await?
        } else {
            Vec::new()
        };
        if is_fmp4 && init_bytes.is_empty() {
            return Err(DownloadError::InvalidM3u8);
        }
        let mut output = File::create(&temp_ts_path).await?;
        let mut bytes_written = init_bytes.len() as u64;
        let mut segments_written = 0;
        if !init_bytes.is_empty() {
            output.write_all(&init_bytes).await?;
        }
        drop(init_bytes);
        emit_progress(&progress, bytes_written, None);

        let downloaded = Arc::new(AtomicU64::new(bytes_written));
        let segment_count = segment_specs.len();
        let segment_results = stream::iter(segment_specs)
            .map(|segment| {
                let engine = self.clone();
                let playlist_url = media_playlist_url.clone();
                let cancel = cancel.clone();
                let progress = progress.clone();
                let downloaded = Arc::clone(&downloaded);
                let limiter = limiter.clone();
                let segment_cache_path = hls_segment_cache_file(&segment_cache_dir, segment.index);
                let segment_cache_dir = segment_cache_dir.clone();
                let cache_manifest = Arc::clone(&cache_manifest);
                let cache_metadata = cache_segments
                    .iter()
                    .find(|metadata| metadata.index == segment.index)
                    .cloned();
                async move {
                    if is_cancelled(&cancel) {
                        return Err(DownloadError::Paused);
                    }
                    // 作者: long
                    // 断点恢复只接受 manifest 已登记、长度和 SHA-256 都匹配的分片，避免半写文件或
                    // 同名资源切换后继续拼接旧内容。
                    if let Some(cached_length) =
                        validate_hls_cached_segment(&segment_cache_path, cache_metadata.as_ref())
                            .await?
                    {
                        let total =
                            downloaded.fetch_add(cached_length, Ordering::SeqCst) + cached_length;
                        emit_progress(&progress, total, None);
                        return Ok((segment.index, cached_length));
                    }
                    let bytes = engine
                        .fetch_hls_segment_with_retry(
                            segment.url,
                            segment.byte_range,
                            limiter,
                            cancel.clone(),
                            HLS_SEGMENT_ATTEMPTS,
                        )
                        .await?;
                    let mut key_cache = HashMap::new();
                    let segment_bytes = engine
                        .decode_hls_segment(
                            &playlist_url,
                            segment.key.as_ref(),
                            bytes.as_slice(),
                            segment.media_sequence,
                            &mut key_cache,
                        )
                        .await?;
                    // 作者: long
                    // 先写临时文件再改名，暂停或进程崩溃时不会留下可被误认成完整分片的半文件。
                    let temporary_cache_path = hls_segment_cache_temp_file(&segment_cache_path);
                    let _ = fs::remove_file(&temporary_cache_path).await;
                    fs::write(&temporary_cache_path, &segment_bytes).await?;
                    fs::rename(&temporary_cache_path, &segment_cache_path).await?;
                    let cached_sha256 = sha256_bytes(&segment_bytes);
                    {
                        let mut manifest = cache_manifest.lock().await;
                        if let Some(metadata) = manifest
                            .segments
                            .iter_mut()
                            .find(|metadata| metadata.index == segment.index)
                        {
                            metadata.cached_length = Some(segment_bytes.len() as u64);
                            metadata.cached_sha256 = Some(cached_sha256);
                        }
                        write_hls_cache_manifest(&segment_cache_dir, &manifest).await?;
                    }
                    let total = downloaded.fetch_add(segment_bytes.len() as u64, Ordering::SeqCst)
                        + segment_bytes.len() as u64;
                    emit_progress(&progress, total, None);
                    Ok((segment.index, segment_bytes.len() as u64))
                }
            })
            .buffer_unordered(options.thread_count)
            .collect::<Vec<_>>()
            .await;

        let mut segment_lengths = vec![0_u64; segment_count];
        for result in segment_results {
            let (index, length) = result?;
            segment_lengths[index] = length;
        }

        // 作者: long
        // 并发任务只保留单个分片并写入缓存；最终文件按索引逐个读取，内存峰值与并发分片数相关，
        // 不再随着整段 HLS 媒体大小线性增长。
        let mut merge_buffer = vec![0_u8; 64 * 1024];
        for index in 0..segment_count {
            if is_cancelled(&cancel) {
                output.flush().await?;
                return Err(DownloadError::Paused);
            }
            let segment_path = hls_segment_cache_file(&segment_cache_dir, index);
            let mut segment_file = File::open(&segment_path).await?;
            let mut merged_segment_bytes = 0_u64;
            loop {
                let read = segment_file.read(&mut merge_buffer).await?;
                if read == 0 {
                    break;
                }
                output.write_all(&merge_buffer[..read]).await?;
                merged_segment_bytes += read as u64;
                bytes_written += read as u64;
            }
            if merged_segment_bytes != segment_lengths[index] {
                return Err(DownloadError::InvalidHlsByteRange(format!(
                    "cached HLS segment {index} length changed from {} to {}",
                    segment_lengths[index], merged_segment_bytes
                )));
            }
            segments_written += 1;
        }

        output.flush().await?;
        drop(output);

        // 作者: long
        // 走到这里说明所有分片已就绪，缓存目录的使命结束；转封装失败时仍会保留 TS，
        // 因此无论哪种产物路径都可以安全清理分片缓存。
        let _ = fs::remove_dir_all(&segment_cache_dir).await;

        let (output_path, output_bytes) = if is_fmp4 {
            // 作者: long
            // fMP4 已经是最终容器，即使用户保留 TS 选项也不能改成 `.ts`，否则文件内容和扩展名会误导后续打开/预览。
            let _ = fs::remove_file(&output_path).await;
            fs::rename(&temp_ts_path, &output_path).await?;
            (output_path, bytes_written)
        } else if request
            .hls_keep_transport_stream
            .unwrap_or(options.hls_keep_transport_stream)
        {
            fs::rename(&temp_ts_path, &fallback_ts_path).await?;
            (fallback_ts_path, bytes_written)
        } else {
            match remux_hls_transport_stream(&temp_ts_path, &output_path).await {
                Ok(bytes) => {
                    let _ = fs::remove_file(&temp_ts_path).await;
                    (output_path, bytes)
                }
                Err(_) => {
                    if fallback_ts_path != temp_ts_path {
                        let _ = fs::remove_file(&fallback_ts_path).await;
                        fs::rename(&temp_ts_path, &fallback_ts_path).await?;
                    }
                    (fallback_ts_path, bytes_written)
                }
            }
        };

        Ok(DownloadSummary {
            protocol: Protocol::M3u8,
            backend: Backend::BuiltIn,
            display_name: display_name_from_path(&output_path),
            output_path,
            bytes_written: output_bytes,
            resumed_from: 0,
            total_bytes: Some(output_bytes),
            segments_written: Some(segments_written),
            sha256: None,
        })
    }

    async fn fetch_hls_segment_with_retry(
        &self,
        url: Url,
        byte_range: Option<HlsByteRange>,
        limiter: DownloadSpeedLimiter,
        cancel: Option<CancelToken>,
        attempts: usize,
    ) -> Result<Vec<u8>, DownloadError> {
        let attempts = attempts.max(1);
        let mut last_error = None;
        for attempt in 0..attempts {
            if is_cancelled(&cancel) {
                return Err(DownloadError::Paused);
            }
            match self
                .fetch_hls_segment_bytes(url.clone(), byte_range, limiter.clone(), cancel.clone())
                .await
            {
                Ok(bytes) => return Ok(bytes),
                Err(DownloadError::Paused) => return Err(DownloadError::Paused),
                Err(error) => {
                    if !error.is_retryable() {
                        return Err(error);
                    }
                    last_error = Some(error);
                    if attempt + 1 < attempts {
                        // 作者: long
                        // HLS 分片只重试连接中断、超时和服务端临时错误；认证失败、404、范围错误继续请求只会浪费重试次数。
                        sleep_with_cancel(
                            Duration::from_millis(150 * (attempt as u64 + 1)),
                            cancel.as_ref(),
                        )
                        .await?;
                    }
                }
            }
        }
        Err(last_error.expect("at least one HLS segment attempt has run"))
    }

    async fn fetch_hls_segment_bytes(
        &self,
        url: Url,
        byte_range: Option<HlsByteRange>,
        limiter: DownloadSpeedLimiter,
        cancel: Option<CancelToken>,
    ) -> Result<Vec<u8>, DownloadError> {
        let mut request = self.client.get(url.clone());
        if let Some(byte_range) = byte_range {
            request = request.header(
                RANGE,
                format!(
                    "bytes={}-{}",
                    byte_range.offset,
                    byte_range.end_inclusive()?
                ),
            );
        }
        let response = request.send().await?;
        let status = response.status();
        if byte_range.is_none() {
            let response = response.error_for_status()?;
            return self
                .read_hls_response_bytes(response, limiter, cancel)
                .await;
        }
        if status != StatusCode::PARTIAL_CONTENT && status != StatusCode::OK {
            return match response.error_for_status() {
                Ok(_) => Err(DownloadError::InvalidHlsByteRange(format!(
                    "unexpected HTTP status {status} for {url}"
                ))),
                Err(error) => Err(DownloadError::Http(error)),
            };
        }
        let mut stream = response.bytes_stream();
        let mut bytes = Vec::new();
        while let Some(chunk) = stream.next().await {
            if is_cancelled(&cancel) {
                return Err(DownloadError::Paused);
            }
            let chunk = chunk?;
            limiter
                .wait_with_cancel(chunk.len() as u64, cancel.as_ref())
                .await?;
            bytes.extend_from_slice(&chunk);
        }
        let byte_range = byte_range.expect("checked above");
        if status == StatusCode::PARTIAL_CONTENT {
            if bytes.len() as u64 != byte_range.length {
                return Err(DownloadError::InvalidHlsByteRange(format!(
                    "expected {} bytes from {}, got {}",
                    byte_range.length,
                    url,
                    bytes.len()
                )));
            }
            return Ok(bytes);
        }

        let offset = usize::try_from(byte_range.offset).map_err(|_| {
            DownloadError::InvalidHlsByteRange(format!(
                "offset {} is too large for {}",
                byte_range.offset, url
            ))
        })?;
        let range_end = byte_range
            .offset
            .checked_add(byte_range.length)
            .ok_or_else(|| {
                DownloadError::InvalidHlsByteRange(format!(
                    "overflow for offset {} and length {} from {}",
                    byte_range.offset, byte_range.length, url
                ))
            })?;
        let end = usize::try_from(range_end).map_err(|_| {
            DownloadError::InvalidHlsByteRange(format!(
                "range {}+{} is too large for {}",
                byte_range.offset, byte_range.length, url
            ))
        })?;
        if bytes.len() < end {
            return Err(DownloadError::InvalidHlsByteRange(format!(
                "range {}-{} exceeds {} bytes from {}",
                byte_range.offset,
                byte_range.end_inclusive()?,
                bytes.len(),
                url
            )));
        }
        // 作者: long
        // 有些本地 fixture 或简单 WebDAV 服务会忽略 Range 并返回 200；保留本地裁剪，避免 BYTERANGE HLS 被误拼成整文件重复内容。
        Ok(bytes[offset..end].to_vec())
    }

    async fn read_hls_response_bytes(
        &self,
        response: reqwest::Response,
        limiter: DownloadSpeedLimiter,
        cancel: Option<CancelToken>,
    ) -> Result<Vec<u8>, DownloadError> {
        let expected_bytes = response.content_length();
        let mut stream = response.bytes_stream();
        let mut bytes = Vec::new();
        while let Some(chunk) = stream.next().await {
            if is_cancelled(&cancel) {
                return Err(DownloadError::Paused);
            }
            let chunk = chunk?;
            limiter
                .wait_with_cancel(chunk.len() as u64, cancel.as_ref())
                .await?;
            bytes.extend_from_slice(&chunk);
        }
        ensure_transfer_complete(Protocol::M3u8, bytes.len() as u64, expected_bytes)?;
        Ok(bytes)
    }

    async fn decode_hls_segment(
        &self,
        playlist_url: &Url,
        key: Option<&Key>,
        segment_bytes: &[u8],
        media_sequence: u64,
        key_cache: &mut HashMap<String, [u8; 16]>,
    ) -> Result<Vec<u8>, DownloadError> {
        let Some(key) = key else {
            return Ok(segment_bytes.to_vec());
        };

        match &key.method {
            KeyMethod::None => Ok(segment_bytes.to_vec()),
            KeyMethod::AES128 => {
                let key_bytes = self.fetch_hls_key(playlist_url, key, key_cache).await?;
                let iv = hls_segment_iv(key, media_sequence)?;
                decrypt_hls_aes128(segment_bytes, key_bytes, iv)
            }
            KeyMethod::SampleAES => Err(DownloadError::UnsupportedHlsKeyMethod(
                "SAMPLE-AES".to_string(),
            )),
            KeyMethod::Other(method) => Err(DownloadError::UnsupportedHlsKeyMethod(method.clone())),
        }
    }

    async fn fetch_hls_key(
        &self,
        playlist_url: &Url,
        key: &Key,
        key_cache: &mut HashMap<String, [u8; 16]>,
    ) -> Result<[u8; 16], DownloadError> {
        if let Some(keyformat) = &key.keyformat
            && keyformat != "identity"
        {
            return Err(DownloadError::InvalidHlsKey(format!(
                "unsupported KEYFORMAT {keyformat}"
            )));
        }

        let key_uri = key
            .uri
            .as_ref()
            .ok_or_else(|| DownloadError::InvalidHlsKey("missing URI".to_string()))?;
        let key_url = playlist_url
            .join(key_uri)
            .map_err(|_| DownloadError::InvalidHlsKey(format!("invalid URI {key_uri}")))?;
        let cache_key = key_url.to_string();
        if let Some(cached) = key_cache.get(&cache_key) {
            return Ok(*cached);
        }

        let bytes = self
            .client
            .get(key_url)
            .send()
            .await?
            .error_for_status()?
            .bytes()
            .await?;
        if bytes.len() != 16 {
            return Err(DownloadError::InvalidHlsKey(format!(
                "AES-128 key must be 16 bytes, got {}",
                bytes.len()
            )));
        }

        let mut key_bytes = [0; 16];
        key_bytes.copy_from_slice(&bytes);
        key_cache.insert(cache_key, key_bytes);
        Ok(key_bytes)
    }

    async fn download_with_ed2k(
        &self,
        request: DownloadRequest,
    ) -> Result<DownloadSummary, DownloadError> {
        let protocol = request.protocol();
        fs::create_dir_all(&request.output_dir).await?;
        if backend_availability(Backend::Amule).await.available {
            return run_ed2k_cli(request, "ed2k").await;
        }

        open::that(&request.source).map_err(|error| DownloadError::HandoffFailed {
            protocol,
            message: error.to_string(),
        })?;

        Ok(DownloadSummary {
            protocol,
            backend: Backend::SystemHandoff,
            output_path: request.output_dir,
            display_name: None,
            bytes_written: 0,
            resumed_from: 0,
            total_bytes: None,
            segments_written: None,
            sha256: None,
        })
    }

    async fn download_smb(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
        cancel: Option<CancelToken>,
        options: DownloadOptions,
    ) -> Result<DownloadSummary, DownloadError> {
        fs::create_dir_all(&request.output_dir).await?;
        let url = Url::parse(&request.source)
            .map_err(|_| DownloadError::InvalidSmbUrl(request.source.clone()))?;
        let spec = SmbDownloadSpec::from_url(&url, request.file_name.clone())?;
        let output_path = request.output_dir.join(&spec.file_name);
        let mut client = SmbClient::connect(spec.client_config()).await?;
        let share = client.connect_share(&spec.share).await?;
        let mut download = client.download(&share, &spec.remote_path).await?;
        let total_bytes = Some(download.size());
        let mut file = File::create(&output_path).await?;
        let mut bytes_written = 0;
        let limiter = DownloadSpeedLimiter::new(options.speed_limit_bps);
        emit_progress(&progress, bytes_written, total_bytes);

        while let Some(chunk) = download.next_chunk().await {
            if is_cancelled(&cancel) {
                file.flush().await?;
                return Err(DownloadError::Paused);
            }

            let chunk = chunk?;
            limiter
                .wait_with_cancel(chunk.len() as u64, cancel.as_ref())
                .await?;
            file.write_all(&chunk).await?;
            bytes_written += chunk.len() as u64;
            emit_progress(&progress, bytes_written, total_bytes);
        }

        file.flush().await?;
        ensure_transfer_complete(Protocol::Smb, bytes_written, total_bytes)?;

        Ok(DownloadSummary {
            protocol: Protocol::Smb,
            backend: Backend::BuiltIn,
            display_name: display_name_from_path(&output_path),
            output_path,
            bytes_written,
            resumed_from: 0,
            total_bytes,
            segments_written: None,
            sha256: None,
        })
    }
}

#[derive(Debug, Clone)]
struct HlsSegmentSpec {
    index: usize,
    url: Url,
    media_sequence: u64,
    key: Option<Key>,
    byte_range: Option<HlsByteRange>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct HlsCacheManifest {
    version: u8,
    playlist_url_sha256: String,
    playlist_sha256: String,
    segments: Vec<HlsCacheSegmentMetadata>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct HlsCacheSegmentMetadata {
    index: usize,
    url_sha256: String,
    media_sequence: u64,
    byte_range: Option<HlsByteRange>,
    cached_length: Option<u64>,
    cached_sha256: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
struct HlsByteRange {
    offset: u64,
    length: u64,
}

const HLS_CACHE_MANIFEST_VERSION: u8 = 1;

fn sha256_bytes(bytes: impl AsRef<[u8]>) -> String {
    format!("{:x}", Sha256::digest(bytes.as_ref()))
}

fn hls_cache_manifest(
    playlist_url: &Url,
    playlist_text: &str,
    segment_specs: &[HlsSegmentSpec],
) -> HlsCacheManifest {
    HlsCacheManifest {
        version: HLS_CACHE_MANIFEST_VERSION,
        // 作者: long
        // 清单只保留 URL 的摘要，不把可能含用户名/密码的原始地址写入磁盘。
        playlist_url_sha256: sha256_bytes(playlist_url.as_str()),
        playlist_sha256: sha256_bytes(playlist_text.as_bytes()),
        segments: segment_specs
            .iter()
            .map(|segment| HlsCacheSegmentMetadata {
                index: segment.index,
                url_sha256: sha256_bytes(segment.url.as_str()),
                media_sequence: segment.media_sequence,
                byte_range: segment.byte_range,
                cached_length: None,
                cached_sha256: None,
            })
            .collect(),
    }
}

fn hls_cache_manifest_matches_source(
    actual: &HlsCacheManifest,
    expected: &HlsCacheManifest,
) -> bool {
    actual.version == expected.version
        && actual.playlist_url_sha256 == expected.playlist_url_sha256
        && actual.playlist_sha256 == expected.playlist_sha256
        && actual.segments.len() == expected.segments.len()
        && actual
            .segments
            .iter()
            .zip(&expected.segments)
            .all(|(actual, expected)| {
                actual.index == expected.index
                    && actual.url_sha256 == expected.url_sha256
                    && actual.media_sequence == expected.media_sequence
                    && actual.byte_range == expected.byte_range
            })
}

async fn write_hls_cache_manifest(
    cache_dir: &Path,
    manifest: &HlsCacheManifest,
) -> Result<(), DownloadError> {
    let manifest_path = hls_segment_cache_manifest_path(cache_dir);
    let temporary_path = hls_segment_cache_manifest_temp_path(cache_dir);
    let bytes = serde_json::to_vec_pretty(manifest).map_err(|error| {
        DownloadError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("serialize HLS cache manifest: {error}"),
        ))
    })?;
    let _ = fs::remove_file(&temporary_path).await;
    fs::write(&temporary_path, bytes).await?;
    // 作者: long
    // 清单采用临时文件改名，确保启动恢复时只会读到完整 JSON；Windows 下先删除目标文件。
    let _ = fs::remove_file(&manifest_path).await;
    fs::rename(temporary_path, manifest_path).await?;
    Ok(())
}

async fn validate_hls_cached_segment(
    path: &Path,
    metadata: Option<&HlsCacheSegmentMetadata>,
) -> Result<Option<u64>, DownloadError> {
    let Some(metadata) = metadata else {
        return Ok(None);
    };
    let Some(expected_length) = metadata.cached_length else {
        return Ok(None);
    };
    let Some(expected_sha256) = metadata.cached_sha256.as_deref() else {
        return Ok(None);
    };
    let file_metadata = match fs::metadata(path).await {
        Ok(metadata) if metadata.is_file() => metadata,
        Ok(_) => return Ok(None),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if file_metadata.len() != expected_length {
        return Ok(None);
    }
    let actual_sha256 = sha256_file(path).await?;
    if actual_sha256 != expected_sha256 {
        return Ok(None);
    }
    Ok(Some(expected_length))
}

fn hls_map_byte_range(
    byte_range: Option<&m3u8_rs::ByteRange>,
) -> Result<Option<HlsByteRange>, DownloadError> {
    let Some(byte_range) = byte_range else {
        return Ok(None);
    };
    if byte_range.length == 0 {
        return Err(DownloadError::InvalidHlsByteRange(
            "initialization section length must be greater than zero".to_string(),
        ));
    }
    // 作者: long
    // 初始化段的 BYTERANGE 未提供偏移时，HLS 规范默认从资源起始位置读取；
    // 普通媒体分片的省略偏移则必须沿用同一 URI 的上一段，两者语义不同。
    Ok(Some(HlsByteRange {
        offset: byte_range.offset.unwrap_or(0),
        length: byte_range.length,
    }))
}

impl HlsByteRange {
    fn end_inclusive(&self) -> Result<u64, DownloadError> {
        self.offset
            .checked_add(self.length)
            .and_then(|end| end.checked_sub(1))
            .ok_or_else(|| {
                DownloadError::InvalidHlsByteRange(format!(
                    "overflow for offset {} and length {}",
                    self.offset, self.length
                ))
            })
    }
}

fn hls_byte_range_for_segment(
    byte_range: Option<&m3u8_rs::ByteRange>,
    segment_url: &Url,
    next_implicit_byte_range: &mut Option<(String, u64)>,
) -> Result<Option<HlsByteRange>, DownloadError> {
    let Some(byte_range) = byte_range else {
        *next_implicit_byte_range = None;
        return Ok(None);
    };
    if byte_range.length == 0 {
        return Err(DownloadError::InvalidHlsByteRange(
            "length must be greater than zero".to_string(),
        ));
    }
    let segment_url_text = segment_url.to_string();
    let offset = match byte_range.offset {
        Some(offset) => offset,
        None => {
            let Some((previous_url, next_offset)) = next_implicit_byte_range.as_ref() else {
                return Err(DownloadError::InvalidHlsByteRange(
                    "missing offset for first byte-range segment".to_string(),
                ));
            };
            if previous_url != &segment_url_text {
                return Err(DownloadError::InvalidHlsByteRange(
                    "implicit offset requires the same segment URI as the previous byte range"
                        .to_string(),
                ));
            }
            *next_offset
        }
    };
    let range = HlsByteRange {
        offset,
        length: byte_range.length,
    };
    // 作者: long
    // HLS 允许后续 BYTERANGE 省略 @offset，下一段只能从同一资源的上一段结尾继续，不能跨 URI 继承。
    *next_implicit_byte_range = Some((
        segment_url_text,
        offset.checked_add(byte_range.length).ok_or_else(|| {
            DownloadError::InvalidHlsByteRange(format!(
                "overflow for offset {offset} and length {}",
                byte_range.length
            ))
        })?,
    ));
    Ok(Some(range))
}

fn ensure_hls_media_has_segments(playlist: &m3u8_rs::MediaPlaylist) -> Result<(), DownloadError> {
    // 作者: long
    // 空媒体播放列表或只有初始化段的 fMP4 不能生成有效下载文件；提前失败，避免把 0 字节
    // 临时文件改名成“成功”的 TS/MP4 任务，也避免 Android 后处理误判为可播放资源。
    if playlist.segments.is_empty() {
        Err(DownloadError::InvalidM3u8)
    } else {
        Ok(())
    }
}

#[derive(Debug, Clone)]
struct DownloadSpeedLimiter {
    inner: Option<Arc<Mutex<SpeedLimiterState>>>,
}

#[derive(Debug)]
struct SpeedLimiterState {
    bytes_per_second: u64,
    next_available: Instant,
}

impl DownloadSpeedLimiter {
    fn new(speed_limit_bps: Option<u64>) -> Self {
        Self {
            inner: speed_limit_bps.filter(|limit| *limit > 0).map(|limit| {
                Arc::new(Mutex::new(SpeedLimiterState {
                    bytes_per_second: limit,
                    next_available: Instant::now(),
                }))
            }),
        }
    }

    async fn wait_with_cancel(
        &self,
        bytes: u64,
        cancel: Option<&CancelToken>,
    ) -> Result<(), DownloadError> {
        let Some(inner) = &self.inner else {
            return Ok(());
        };
        if bytes == 0 {
            return Ok(());
        }

        let sleep_for = {
            let mut state = inner.lock().await;
            let now = Instant::now();
            let start = if state.next_available > now {
                state.next_available
            } else {
                now
            };
            let ready_at = start + transfer_duration(bytes, state.bytes_per_second);
            state.next_available = ready_at;
            ready_at.saturating_duration_since(now)
        };
        // 作者: long
        // 低速限速时单个网络块可能占用数秒配额；分段等待让暂停或删除能及时中断，避免任务长时间卡在“下载中”。
        let deadline = Instant::now() + sleep_for;
        loop {
            if cancel.is_some_and(CancelToken::is_cancelled) {
                return Err(DownloadError::Paused);
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            tokio::time::sleep(remaining.min(Duration::from_millis(50))).await;
        }
        Ok(())
    }
}

#[derive(Debug, Clone)]
struct BlockingDownloadSpeedLimiter {
    bytes_per_second: Option<u64>,
}

impl BlockingDownloadSpeedLimiter {
    fn new(bytes_per_second: Option<u64>) -> Self {
        Self {
            bytes_per_second: bytes_per_second.filter(|limit| *limit > 0),
        }
    }

    fn wait(&self, bytes: u64) {
        let Some(bytes_per_second) = self.bytes_per_second else {
            return;
        };
        if bytes == 0 {
            return;
        }
        std::thread::sleep(transfer_duration(bytes, bytes_per_second));
    }
}

fn transfer_duration(bytes: u64, bytes_per_second: u64) -> Duration {
    Duration::from_secs_f64(bytes as f64 / bytes_per_second.max(1) as f64)
}

fn torrent_rate_limits(speed_limit_bps: Option<u64>) -> LimitsConfig {
    LimitsConfig {
        upload_bps: None,
        download_bps: speed_limit_nonzero_u32(speed_limit_bps),
    }
}

fn torrent_only_files(request: &DownloadRequest) -> Option<Vec<usize>> {
    // 作者: long
    // 空选择表示下载整个种子；只有用户明确选择文件时才传给 librqbit，保持旧任务和单文件种子的默认行为不变。
    (!request.torrent_file_indices.is_empty()).then(|| request.torrent_file_indices.clone())
}

fn torrent_progress_for_request(
    request: &DownloadRequest,
    file_progress: &[u64],
    aggregate_progress: u64,
    aggregate_total: u64,
    initializing: bool,
) -> (u64, u64) {
    // 作者: long
    // librqbit 的总进度包含整个 metadata；用户只确认部分文件时，任务卡和队列状态必须
    // 使用同一组选中文件的大小与已写入字节，否则未选择文件会把任务显示成“43/43”一类的假完成。
    if request.torrent_file_indices.is_empty() || request.torrent_files.is_empty() {
        return (
            if initializing { 0 } else { aggregate_progress },
            aggregate_total,
        );
    }

    let selected = request
        .torrent_file_indices
        .iter()
        .copied()
        .collect::<std::collections::BTreeSet<_>>();
    let selected_total = request
        .torrent_files
        .iter()
        .filter(|file| selected.contains(&file.index))
        .map(|file| file.size)
        .sum::<u64>();
    if selected_total == 0 {
        return (
            if initializing { 0 } else { aggregate_progress },
            aggregate_total,
        );
    }

    let selected_progress = if initializing {
        0
    } else if file_progress.is_empty() {
        aggregate_progress.min(selected_total)
    } else {
        request
            .torrent_file_indices
            .iter()
            .filter_map(|index| file_progress.get(*index))
            .copied()
            .sum::<u64>()
            .min(selected_total)
    };
    (selected_progress, selected_total)
}

pub(crate) fn torrent_session_options(speed_limit_bps: Option<u64>) -> SessionOptions {
    SessionOptions {
        // 作者: long
        // BitTorrent 需要监听 peer 端口，tracker 才能把本机作为可连接下载端告诉做种方。
        listen_port_range: Some(TORRENT_LISTEN_PORT_START..TORRENT_LISTEN_PORT_END),
        // 作者: long
        // CLI/桌面下载是一次性任务，禁用全局 DHT 持久化可避免多个本地会话争用同一份 DHT 端口状态。
        disable_dht_persistence: true,
        ratelimits: torrent_rate_limits(speed_limit_bps),
        ..Default::default()
    }
}

fn speed_limit_nonzero_u32(speed_limit_bps: Option<u64>) -> Option<NonZeroU32> {
    speed_limit_bps
        .filter(|limit| *limit > 0)
        .map(|limit| limit.min(u32::MAX as u64) as u32)
        .and_then(NonZeroU32::new)
}

fn emit_progress(
    progress: &Option<ProgressCallback>,
    downloaded_bytes: u64,
    total_bytes: Option<u64>,
) {
    if let Some(callback) = progress {
        callback(DownloadProgress {
            downloaded_bytes,
            total_bytes,
        });
    }
}

fn is_cancelled(cancel: &Option<CancelToken>) -> bool {
    cancel.as_ref().is_some_and(CancelToken::is_cancelled)
}

async fn sleep_with_cancel(
    duration: Duration,
    cancel: Option<&CancelToken>,
) -> Result<(), DownloadError> {
    let deadline = Instant::now() + duration;
    loop {
        if cancel.is_some_and(CancelToken::is_cancelled) {
            return Err(DownloadError::Paused);
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Ok(());
        }
        tokio::time::sleep(remaining.min(Duration::from_millis(25))).await;
    }
}

async fn existing_file_size(path: &Path) -> Result<u64, std::io::Error> {
    match fs::metadata(path).await {
        Ok(metadata) if metadata.is_file() => Ok(metadata.len()),
        Ok(_) => Ok(0),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(0),
        Err(error) => Err(error),
    }
}

async fn validate_summary_sha256(
    summary: &mut DownloadSummary,
    expected_sha256: Option<&str>,
) -> Result<(), DownloadError> {
    let Some(expected_sha256) = expected_sha256 else {
        return Ok(());
    };

    let expected = normalized_expected_sha256(expected_sha256)?;
    let actual = sha256_file(&summary.output_path).await?;
    if actual != expected {
        return Err(DownloadError::Sha256Mismatch {
            expected,
            actual,
            path: summary.output_path.display().to_string(),
        });
    }
    summary.sha256 = Some(actual);
    Ok(())
}

fn normalized_expected_sha256(value: &str) -> Result<String, DownloadError> {
    validate_sha256_text(value).map_err(|_| DownloadError::InvalidSha256 {
        value: value.to_string(),
    })
}

async fn sha256_file(path: &Path) -> Result<String, DownloadError> {
    let metadata = fs::metadata(path).await?;
    if !metadata.is_file() {
        return Err(DownloadError::Sha256UnsupportedOutput {
            path: path.display().to_string(),
        });
    }

    let mut file = File::open(path).await?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer).await?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }

    Ok(format!("{:x}", hasher.finalize()))
}

async fn remove_existing_outputs_for_request(
    request: &DownloadRequest,
) -> Result<(), std::io::Error> {
    for path in output_file_candidates_for_request(request) {
        match fs::metadata(&path).await {
            Ok(metadata) if metadata.is_file() => {
                fs::remove_file(path).await?;
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
    }
    if request.protocol() == Protocol::M3u8 {
        let file_name = request
            .file_name
            .clone()
            .map(|name| sanitize_download_file_name(&name, "download.bin"))
            .unwrap_or_else(|| inferred_file_name_from_source(&request.source));
        let output_path = hls_mp4_output_name(&request.output_dir.join(file_name));
        let cache_dir = hls_segment_cache_dir(&output_path);
        match fs::metadata(&cache_dir).await {
            Ok(metadata) if metadata.is_dir() => fs::remove_dir_all(cache_dir).await?,
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn output_file_candidates_for_request(request: &DownloadRequest) -> Vec<PathBuf> {
    let file_name = request
        .file_name
        .clone()
        .map(|name| sanitize_download_file_name(&name, "download.bin"))
        .unwrap_or_else(|| inferred_file_name_from_source(&request.source));
    let primary = request.output_dir.join(&file_name);
    let mut candidates = Vec::new();

    match request.protocol() {
        Protocol::M3u8 => {
            let base = PathBuf::from(&file_name);
            let mp4 = request.output_dir.join(base.with_extension("mp4"));
            let ts = request
                .output_dir
                .join(PathBuf::from(&file_name).with_extension("ts"));
            candidates.push(mp4.clone());
            candidates.push(ts);
            candidates.push(hls_temp_transport_path(&mp4));
        }
        Protocol::Torrent | Protocol::Magnet => {
            if request.file_name.is_some() {
                candidates.push(primary.clone());
            }
        }
        _ => candidates.push(primary.clone()),
    }

    candidates.push(range_temp_output_path(&primary));
    candidates
}

fn display_name_from_path(output_path: &Path) -> Option<String> {
    output_path
        .file_name()
        .and_then(|file_name| file_name.to_str())
        .filter(|file_name| !file_name.trim().is_empty())
        .map(ToOwned::to_owned)
}

fn torrent_output_details(
    output_dir: &Path,
    torrent_name: Option<&str>,
    file_paths: &[PathBuf],
    payload_file_count: usize,
) -> (PathBuf, Option<String>) {
    if file_paths.len() == 1 {
        let output_path = if payload_file_count > 1 {
            // 作者: long
            // librqbit 会把多文件种子落到 metadata name 目录下；即便用户只选一个文件，summary 也必须指向真实产物。
            safe_torrent_name(torrent_name)
                .map(|root| output_dir.join(root).join(&file_paths[0]))
                .unwrap_or_else(|| output_dir.join(&file_paths[0]))
        } else {
            output_dir.join(&file_paths[0])
        };
        let display_name =
            display_name_from_path(&output_path).or_else(|| safe_torrent_name(torrent_name));
        return (output_path, display_name);
    }

    // 作者: long
    // Torrent 多文件任务最终会落到一个文件树里，队列卡片优先展示真实顶层目录，避免继续显示 .torrent 或 magnet-download。
    let display_name =
        common_top_level_name(file_paths).or_else(|| safe_torrent_name(torrent_name));
    let output_path = display_name
        .as_ref()
        .map(|root| output_dir.join(root))
        .filter(|path| path.exists())
        .unwrap_or_else(|| output_dir.to_path_buf());

    (output_path, display_name)
}

fn common_top_level_name(file_paths: &[PathBuf]) -> Option<String> {
    let mut common = None;
    for path in file_paths {
        let name = first_path_component_name(path)?;
        match &common {
            None => common = Some(name),
            Some(existing) if existing == &name => {}
            Some(_) => return None,
        }
    }
    common
}

fn first_path_component_name(path: &Path) -> Option<String> {
    match path.components().next()? {
        std::path::Component::Normal(component) => component.to_str().map(ToOwned::to_owned),
        _ => None,
    }
}

fn safe_torrent_name(name: Option<&str>) -> Option<String> {
    let name = name?.trim();
    if name.is_empty() || name == "." || name == ".." || name.contains('/') || name.contains('\\') {
        return None;
    }
    Some(name.to_string())
}

fn inferred_file_name_from_source(source: &str) -> String {
    suggested_download_file_name(source)
}

fn infer_total_bytes(
    content_length: Option<&reqwest::header::HeaderValue>,
    resumed_from: u64,
) -> Option<u64> {
    content_length
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok())
        .map(|length| length + resumed_from)
}

fn unsatisfied_range_total(content_range: Option<&reqwest::header::HeaderValue>) -> Option<u64> {
    let value = content_range?.to_str().ok()?.trim();
    let total = value.strip_prefix("bytes */")?;
    total.parse::<u64>().ok()
}

fn infer_file_name(url: &Url, fallback: &str) -> String {
    let inferred = url
        .path_segments()
        .and_then(|mut segments| segments.next_back())
        .filter(|segment| !segment.is_empty())
        .or_else(|| url.host_str())
        .unwrap_or(fallback)
        .to_string();
    sanitize_download_file_name(&percent_decode(&inferred), fallback)
}

fn url_credentials(url: &mut Url) -> Result<Option<(String, Option<String>)>, DownloadError> {
    if url.username().is_empty() && url.password().is_none() {
        return Ok(None);
    }

    let username = percent_decode_str(url.username())
        .decode_utf8_lossy()
        .into_owned();
    let password = url
        .password()
        .map(|value| percent_decode_str(value).decode_utf8_lossy().into_owned());
    url.set_username("")
        .map_err(|_| DownloadError::InvalidUrl(url.to_string()))?;
    url.set_password(None)
        .map_err(|_| DownloadError::InvalidUrl(url.to_string()))?;
    Ok(Some((username, password)))
}

fn request_with_credentials(
    mut request: DownloadRequest,
    runtime_credential: Option<&StoredCredential>,
) -> Result<DownloadRequest, DownloadError> {
    let Some(raw_reference) = request.credential_ref.clone() else {
        return Ok(request);
    };
    let reference = validate_credential_ref(&raw_reference).map_err(|error| {
        DownloadError::CredentialUnavailable {
            reference: raw_reference,
            reason: credential_store_error_reason(error),
        }
    })?;
    let protocol = request.protocol();
    if !matches!(
        protocol,
        Protocol::Http
            | Protocol::Https
            | Protocol::Webdav
            | Protocol::Webdavs
            | Protocol::Ftp
            | Protocol::Ftps
            | Protocol::Sftp
            | Protocol::Smb
    ) {
        return Err(DownloadError::CredentialUnsupportedProtocol(protocol));
    }
    if credential_store_uses_private_key(runtime_credential) && protocol != Protocol::Sftp {
        return Err(DownloadError::CredentialUnsupportedProtocol(protocol));
    }

    let mut url = Url::parse(&request.source)
        .map_err(|_| DownloadError::InvalidUrl(request.source.clone()))?;
    if !url.username().is_empty() || url.password().is_some() {
        return Err(DownloadError::CredentialConflict);
    }
    let credential = match runtime_credential {
        Some(credential) => credential.clone(),
        None => {
            get_credential(&reference).map_err(|error| DownloadError::CredentialUnavailable {
                reference: reference.clone(),
                reason: credential_store_error_reason(error),
            })?
        }
    };
    url.set_username(&credential.username)
        .map_err(|_| DownloadError::CredentialUnavailable {
            reference: reference.clone(),
            reason: "用户名无法编码到下载地址".to_string(),
        })?;
    if !credential.uses_private_key() {
        url.set_password(Some(&credential.password)).map_err(|_| {
            DownloadError::CredentialUnavailable {
                reference: reference.clone(),
                reason: "密码无法编码到下载地址".to_string(),
            }
        })?;
    }
    request.source = url.to_string();
    request.credential_ref = Some(reference);
    Ok(request)
}

fn credential_store_uses_private_key(credential: Option<&StoredCredential>) -> bool {
    credential.is_some_and(StoredCredential::uses_private_key)
}

fn credential_store_error_reason(error: CredentialStoreError) -> String {
    match error {
        CredentialStoreError::InvalidReference => "凭据引用无效".to_string(),
        CredentialStoreError::UnsupportedPlatform => "当前平台没有可用的系统凭据库".to_string(),
        CredentialStoreError::Backend => "系统凭据库不可用或凭据不存在".to_string(),
        CredentialStoreError::InvalidPayload => "系统凭据内容无效".to_string(),
    }
}

async fn torrent_source(
    source: &str,
    protocol: Protocol,
) -> Result<AddTorrent<'static>, DownloadError> {
    match protocol {
        Protocol::Magnet => Ok(AddTorrent::from_url(source.to_string())),
        Protocol::Torrent if source.starts_with("http://") || source.starts_with("https://") => {
            Ok(AddTorrent::from_url(source.to_string()))
        }
        Protocol::Torrent => {
            let bytes = fs::read(source).await?;
            Ok(AddTorrent::from_bytes(bytes))
        }
        _ => Err(DownloadError::UnsupportedProtocol(protocol)),
    }
}

/// 读取 .torrent 字节：http(s) URL 走 reqwest 下载，其它按本地文件路径读取。
pub async fn read_torrent_bytes_from_url(source: &str) -> Result<Vec<u8>, DownloadError> {
    if source.starts_with("http://") || source.starts_with("https://") {
        let response = reqwest::get(source)
            .await
            .map_err(|error| {
                DownloadError::TorrentSourceUnreadable(format!("下载种子失败: {error}"))
            })?
            .error_for_status()
            .map_err(|error| {
                DownloadError::TorrentSourceUnreadable(format!("下载种子失败: {error}"))
            })?;
        let bytes = response.bytes().await.map_err(|error| {
            DownloadError::TorrentSourceUnreadable(format!("读取种子内容失败: {error}"))
        })?;
        Ok(bytes.to_vec())
    } else {
        tokio::fs::read(source).await.map_err(|error| {
            DownloadError::TorrentSourceUnreadable(format!("读取种子文件失败: {error}"))
        })
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct HlsVariantInfo {
    pub index: usize,
    pub uri: String,
    pub bandwidth: u64,
    pub average_bandwidth: Option<u64>,
    pub codecs: Option<String>,
    pub resolution: Option<String>,
    pub frame_rate: Option<f64>,
}

/// 解析 master playlist 的清晰度 variant 列表，供用户在新建任务时选择。
/// 源不是 master playlist（已是 media playlist）时返回空列表。
pub async fn hls_variants(source: &str) -> Result<Vec<HlsVariantInfo>, DownloadError> {
    let client = Client::builder()
        .user_agent(concat!("FluxDown/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|_error| DownloadError::InvalidM3u8)?;
    let url = Url::parse(source).map_err(|_| DownloadError::InvalidUrl(source.to_string()))?;
    let text = client
        .get(url)
        .send()
        .await?
        .error_for_status()?
        .text()
        .await?;
    let playlist =
        m3u8_rs::parse_playlist_res(text.as_bytes()).map_err(|_| DownloadError::InvalidM3u8)?;
    let m3u8_rs::Playlist::MasterPlaylist(master) = playlist else {
        return Ok(Vec::new());
    };
    Ok(master
        .variants
        .iter()
        .enumerate()
        .filter(|(_, variant)| !variant.is_i_frame)
        .map(|(index, variant)| HlsVariantInfo {
            index,
            uri: variant.uri.clone(),
            // 作者: long
            // m3u8_rs 已将带宽解析为无符号整数，直接保留源值即可，避免无意义的下限裁剪触发 Clippy。
            bandwidth: variant.bandwidth,
            average_bandwidth: variant.average_bandwidth,
            codecs: variant.codecs.clone(),
            resolution: variant
                .resolution
                .as_ref()
                .map(|resolution| format!("{}x{}", resolution.width, resolution.height)),
            frame_rate: variant.frame_rate,
        })
        .collect())
}

fn webdav_http_url(source: &str) -> Result<String, DownloadError> {
    let url = Url::parse(source).map_err(|_| DownloadError::InvalidUrl(source.to_string()))?;
    let target_scheme = match url.scheme() {
        "webdav" => "http",
        "webdavs" => "https",
        _ => return Err(DownloadError::InvalidUrl(source.to_string())),
    };
    if url.host_str().is_none() {
        return Err(DownloadError::InvalidUrl(source.to_string()));
    }

    let scheme_end = source
        .find(':')
        .ok_or_else(|| DownloadError::InvalidUrl(source.to_string()))?;
    let mapped = format!("{target_scheme}{}", &source[scheme_end..]);
    Url::parse(&mapped)
        .map(|url| url.to_string())
        .map_err(|_| DownloadError::InvalidUrl(source.to_string()))
}

fn allows_bad_certificate(url: &Url) -> bool {
    url.query_pairs().any(|(key, value)| {
        key.eq_ignore_ascii_case("allowBadCertificate") && value.eq_ignore_ascii_case("true")
    })
}

fn http_client_for_url(default_client: &Client, url: &Url) -> Result<Client, DownloadError> {
    if !allows_bad_certificate(url) {
        return Ok(default_client.clone());
    }

    // 作者: long
    // 本地实验室 HTTPS/WebDAVS fixture 会使用临时自签证书；只有 URL 显式 opt-in 时才放宽校验，避免影响普通公网下载的 TLS 安全边界。
    Ok(Client::builder()
        .danger_accept_invalid_certs(true)
        .build()?)
}

fn hls_segment_iv(key: &Key, media_sequence: u64) -> Result<[u8; 16], DownloadError> {
    match &key.iv {
        Some(iv) => parse_hls_hex_iv(iv),
        None => Ok(hls_sequence_iv(media_sequence)),
    }
}

fn hls_sequence_iv(media_sequence: u64) -> [u8; 16] {
    let mut iv = [0; 16];
    iv[8..].copy_from_slice(&media_sequence.to_be_bytes());
    iv
}

fn parse_hls_hex_iv(value: &str) -> Result<[u8; 16], DownloadError> {
    let hex = value
        .strip_prefix("0x")
        .or_else(|| value.strip_prefix("0X"))
        .unwrap_or(value);
    if hex.len() != 32 {
        return Err(DownloadError::InvalidHlsKey(format!(
            "IV must be 16 bytes of hex, got {} hex chars",
            hex.len()
        )));
    }

    let mut iv = [0; 16];
    for index in 0..16 {
        let byte = u8::from_str_radix(&hex[index * 2..index * 2 + 2], 16)
            .map_err(|_| DownloadError::InvalidHlsKey("IV contains non-hex data".to_string()))?;
        iv[index] = byte;
    }
    Ok(iv)
}

fn decrypt_hls_aes128(
    ciphertext: &[u8],
    key: [u8; 16],
    iv: [u8; 16],
) -> Result<Vec<u8>, DownloadError> {
    Aes128CbcDec::new(&key.into(), &iv.into())
        .decrypt_padded_vec_mut::<Pkcs7>(ciphertext)
        .map_err(|error| DownloadError::HlsDecrypt(error.to_string()))
}

// FTPS 数据连接建立阶段的 TLS 错误通常是服务器强制会话复用（vsftpd/Rebex 类）所致；
// 上游 suppaftp 引擎暂不支持该能力，这里把底层晦涩的 SecureError 翻译成可操作的提示。
fn map_ftp_data_error(protocol: Protocol, error: suppaftp::FtpError) -> DownloadError {
    if protocol == Protocol::Ftps {
        DownloadError::FtpsDataTls { source: error }
    } else {
        DownloadError::Ftp(error)
    }
}

async fn connect_ftps(spec: &FtpDownloadSpec) -> Result<AsyncRustlsFtpStream, DownloadError> {
    let config = ftps_tls_config(spec.allow_bad_certificate);
    let connector = AsyncRustlsConnector::from(tokio_rustls::TlsConnector::from(Arc::new(config)));

    if spec.implicit_tls {
        AsyncRustlsFtpStream::connect_secure_implicit(spec.address.clone(), connector, &spec.host)
            .await
            .map_err(DownloadError::from)
    } else {
        AsyncRustlsFtpStream::connect(spec.address.clone())
            .await?
            .into_secure(connector, &spec.host)
            .await
            .map_err(DownloadError::from)
    }
}

fn ftps_tls_config(allow_bad_certificate: bool) -> tokio_rustls::rustls::ClientConfig {
    let builder = tokio_rustls::rustls::ClientConfig::builder();
    if allow_bad_certificate {
        return builder
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(AcceptInvalidServerCertificate))
            .with_no_client_auth();
    }

    let root_store = tokio_rustls::rustls::RootCertStore::from_iter(
        webpki_roots::TLS_SERVER_ROOTS.iter().cloned(),
    );
    builder
        .with_root_certificates(root_store)
        .with_no_client_auth()
}

#[derive(Debug)]
struct AcceptInvalidServerCertificate;

impl tokio_rustls::rustls::client::danger::ServerCertVerifier for AcceptInvalidServerCertificate {
    fn verify_server_cert(
        &self,
        _end_entity: &tokio_rustls::rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[tokio_rustls::rustls::pki_types::CertificateDer<'_>],
        _server_name: &tokio_rustls::rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: tokio_rustls::rustls::pki_types::UnixTime,
    ) -> Result<tokio_rustls::rustls::client::danger::ServerCertVerified, tokio_rustls::rustls::Error>
    {
        // 作者: long
        // FTPS 本地实验室 fixture 使用临时自签证书；能走到这里说明 URL 已显式 opt-in，不改变默认公网证书校验策略。
        Ok(tokio_rustls::rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &tokio_rustls::rustls::pki_types::CertificateDer<'_>,
        _dss: &tokio_rustls::rustls::DigitallySignedStruct,
    ) -> Result<
        tokio_rustls::rustls::client::danger::HandshakeSignatureValid,
        tokio_rustls::rustls::Error,
    > {
        Ok(tokio_rustls::rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &tokio_rustls::rustls::pki_types::CertificateDer<'_>,
        _dss: &tokio_rustls::rustls::DigitallySignedStruct,
    ) -> Result<
        tokio_rustls::rustls::client::danger::HandshakeSignatureValid,
        tokio_rustls::rustls::Error,
    > {
        Ok(tokio_rustls::rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<tokio_rustls::rustls::SignatureScheme> {
        use tokio_rustls::rustls::SignatureScheme;

        vec![
            SignatureScheme::RSA_PKCS1_SHA1,
            SignatureScheme::ECDSA_SHA1_Legacy,
            SignatureScheme::RSA_PKCS1_SHA256,
            SignatureScheme::ECDSA_NISTP256_SHA256,
            SignatureScheme::RSA_PKCS1_SHA384,
            SignatureScheme::ECDSA_NISTP384_SHA384,
            SignatureScheme::RSA_PKCS1_SHA512,
            SignatureScheme::ECDSA_NISTP521_SHA512,
            SignatureScheme::RSA_PSS_SHA256,
            SignatureScheme::RSA_PSS_SHA384,
            SignatureScheme::RSA_PSS_SHA512,
            SignatureScheme::ED25519,
            SignatureScheme::ED448,
        ]
    }
}

fn download_sftp_blocking(
    output_dir: PathBuf,
    spec: SftpDownloadSpec,
    progress: Option<ProgressCallback>,
    cancel: Option<CancelToken>,
    speed_limit_bps: Option<u64>,
    known_hosts_path: Option<PathBuf>,
    jump: Option<SftpJumpOptions>,
) -> Result<DownloadSummary, DownloadError> {
    std::fs::create_dir_all(&output_dir)?;
    let output_path = output_dir.join(&spec.file_name);
    let existing_bytes = std::fs::metadata(&output_path)
        .ok()
        .filter(|metadata| metadata.is_file())
        .map(|metadata| metadata.len())
        .unwrap_or(0);

    let mut jump_session = None;
    let mut bridge = None;
    let tcp = if let Some(jump) = jump.as_ref() {
        let jump_tcp = TcpStream::connect(&jump.address)?;
        let mut session = SshSession::new()?;
        session.set_tcp_stream(jump_tcp);
        session.handshake()?;
        if let Some(path) = jump.known_hosts.as_deref() {
            verify_sftp_host_key(&session, &jump.host, jump.port, path)?;
        }
        authenticate_sftp_session(&session, &jump.username, jump.password.as_deref(), None)?;
        let channel = session.channel_direct_tcpip(&spec.host, spec.port, None)?;
        // 作者: long
        // ssh2 的同一会话共享内部锁，桥接阶段改用非阻塞单线程轮询，避免读操作长期占锁后阻塞写操作。
        session.set_blocking(false);
        let (local_tcp, relay) = TcpRelay::start(channel)?;
        jump_session = Some(session);
        bridge = Some(relay);
        local_tcp
    } else {
        TcpStream::connect(&spec.address)?
    };

    let mut session = SshSession::new()?;
    session.set_tcp_stream(tcp);
    session.handshake()?;
    if let Some(path) = known_hosts_path.as_deref() {
        verify_sftp_host_key(&session, &spec.host, spec.port, path)?;
    }
    authenticate_sftp_session(
        &session,
        &spec.username,
        spec.password.as_deref(),
        spec.private_key_pem
            .as_deref()
            .map(|pem| (pem, spec.passphrase.as_deref())),
    )?;
    let sftp = session.sftp()?;
    let total_bytes = sftp.stat(Path::new(&spec.remote_path))?.size;
    let mut remote = sftp.open(Path::new(&spec.remote_path))?;
    if existing_bytes > 0 {
        remote.seek(std::io::SeekFrom::Start(existing_bytes))?;
    }

    let mut local = if existing_bytes > 0 {
        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(&output_path)?;
        file.seek(std::io::SeekFrom::End(0))?;
        file
    } else {
        std::fs::File::create(&output_path)?
    };

    let mut bytes_written = existing_bytes;
    emit_progress(&progress, bytes_written, total_bytes);
    let mut buffer = vec![0_u8; 64 * 1024];
    let limiter = BlockingDownloadSpeedLimiter::new(speed_limit_bps);

    loop {
        if is_cancelled(&cancel) {
            std::io::Write::flush(&mut local)?;
            return Err(DownloadError::Paused);
        }

        let read = remote.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        limiter.wait(read as u64);
        std::io::Write::write_all(&mut local, &buffer[..read])?;
        bytes_written += read as u64;
        emit_progress(&progress, bytes_written, total_bytes);
    }

    std::io::Write::flush(&mut local)?;
    ensure_transfer_complete(Protocol::Sftp, bytes_written, total_bytes)?;
    let summary = DownloadSummary {
        protocol: Protocol::Sftp,
        backend: Backend::BuiltIn,
        display_name: display_name_from_path(&output_path),
        output_path,
        bytes_written,
        resumed_from: existing_bytes,
        total_bytes,
        segments_written: None,
        sha256: None,
    };
    drop(sftp);
    drop(session);
    drop(bridge);
    drop(jump_session);
    Ok(summary)
}

fn authenticate_sftp_session(
    session: &SshSession,
    username: &str,
    password: Option<&str>,
    private_key: Option<(&str, Option<&str>)>,
) -> Result<(), DownloadError> {
    // 作者: long
    // Android 凭据只在本次握手内存中使用；私钥认证优先于密码和 SSH agent，避免私钥任务误走空密码分支。
    match private_key {
        Some((pem, passphrase)) => {
            session.userauth_pubkey_memory(username, None, pem, passphrase)?
        }
        None => match password {
            Some(password) => session.userauth_password(username, password)?,
            None => session.userauth_agent(username)?,
        },
    }
    Ok(())
}

fn verify_sftp_host_key(
    session: &SshSession,
    host: &str,
    port: u16,
    known_hosts_path: &Path,
) -> Result<(), DownloadError> {
    if !known_hosts_path.is_file() {
        return Err(DownloadError::SftpHostKeyVerification {
            message: "known_hosts 文件不存在或不可读".to_string(),
        });
    }

    let (key, _) = session
        .host_key()
        .ok_or_else(|| DownloadError::SftpHostKeyVerification {
            message: "SSH 服务端没有返回主机密钥".to_string(),
        })?;
    let mut known_hosts =
        session
            .known_hosts()
            .map_err(|error| DownloadError::SftpHostKeyVerification {
                message: format!("无法初始化 known_hosts: {}", error.message()),
            })?;
    known_hosts
        .read_file(known_hosts_path, KnownHostFileKind::OpenSSH)
        .map_err(|error| DownloadError::SftpHostKeyVerification {
            message: format!("无法读取 known_hosts: {}", error.message()),
        })?;

    let result = if port == 22 {
        known_hosts.check(host, key)
    } else {
        known_hosts.check_port(host, port, key)
    };
    match result {
        CheckResult::Match => Ok(()),
        CheckResult::NotFound => Err(DownloadError::SftpHostKeyVerification {
            message: "known_hosts 中没有该主机和端口的密钥".to_string(),
        }),
        CheckResult::Mismatch => Err(DownloadError::SftpHostKeyVerification {
            message: "known_hosts 中的主机密钥与服务端不一致".to_string(),
        }),
        CheckResult::Failure => Err(DownloadError::SftpHostKeyVerification {
            message: "known_hosts 主机密钥检查失败".to_string(),
        }),
    }
}

struct TcpRelay {
    shutdown: Option<TcpStream>,
    thread: Option<JoinHandle<()>>,
}

impl TcpRelay {
    fn start(channel: ssh2::Channel) -> Result<(TcpStream, Self), DownloadError> {
        let listener = TcpListener::bind("127.0.0.1:0")?;
        let address = listener.local_addr()?;
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        let thread = thread::spawn(move || {
            let accepted = listener.accept();
            let (socket, _) = match accepted {
                Ok(value) => value,
                Err(_) => return,
            };
            let _ = ready_tx.send(());
            relay_channel(channel, socket);
        });

        let local = TcpStream::connect(address)?;
        ready_rx
            .recv()
            .map_err(|_| std::io::Error::other("SFTP 跳板回环桥接启动失败"))?;
        let shutdown = local.try_clone()?;
        Ok((
            local,
            Self {
                shutdown: Some(shutdown),
                thread: Some(thread),
            },
        ))
    }
}

fn relay_channel(mut channel: ssh2::Channel, mut socket: TcpStream) {
    if socket.set_nonblocking(true).is_err() {
        return;
    }
    let mut socket_to_channel = Vec::new();
    let mut channel_to_socket = Vec::new();
    let mut socket_eof = false;
    let mut channel_eof = false;
    let mut socket_buffer = [0_u8; 32 * 1024];
    let mut channel_buffer = [0_u8; 32 * 1024];

    while !(socket_eof
        && channel_eof
        && socket_to_channel.is_empty()
        && channel_to_socket.is_empty())
    {
        let mut progressed = false;
        if !socket_eof && socket_to_channel.len() < 128 * 1024 {
            match socket.read(&mut socket_buffer) {
                Ok(0) => socket_eof = true,
                Ok(read) => {
                    socket_to_channel.extend_from_slice(&socket_buffer[..read]);
                    progressed = true;
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(_) => socket_eof = true,
            }
        }

        if !socket_to_channel.is_empty() {
            match channel.write(&socket_to_channel) {
                Ok(0) => channel_eof = true,
                Ok(written) => {
                    socket_to_channel.drain(..written);
                    progressed = true;
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(_) => channel_eof = true,
            }
        }

        if !channel_eof && channel_to_socket.len() < 128 * 1024 {
            match channel.read(&mut channel_buffer) {
                Ok(0) => channel_eof = true,
                Ok(read) => {
                    channel_to_socket.extend_from_slice(&channel_buffer[..read]);
                    progressed = true;
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(_) => channel_eof = true,
            }
        }

        if !channel_to_socket.is_empty() {
            match socket.write(&channel_to_socket) {
                Ok(0) => socket_eof = true,
                Ok(written) => {
                    channel_to_socket.drain(..written);
                    progressed = true;
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(_) => socket_eof = true,
            }
        }

        if socket_eof && socket_to_channel.is_empty() {
            let _ = channel.send_eof();
        }
        if !progressed {
            thread::sleep(Duration::from_millis(1));
        }
    }
    let _ = channel.close();
    let _ = channel.wait_close();
}

impl Drop for TcpRelay {
    fn drop(&mut self) {
        if let Some(socket) = self.shutdown.take() {
            let _ = socket.shutdown(Shutdown::Both);
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

#[derive(Debug, Clone)]
struct SftpDownloadSpec {
    address: String,
    host: String,
    port: u16,
    username: String,
    /// 缺少密码表示请求使用当前环境的 SSH agent，而不是尝试空密码登录。
    password: Option<String>,
    private_key_pem: Option<String>,
    passphrase: Option<String>,
    remote_path: String,
    file_name: String,
}

impl SftpDownloadSpec {
    fn from_url(url: &Url, requested_file_name: Option<String>) -> Result<Self, DownloadError> {
        if url.scheme() != "sftp" {
            return Err(DownloadError::InvalidSftpUrl(url.to_string()));
        }

        let host = url
            .host_str()
            .ok_or_else(|| DownloadError::InvalidSftpUrl(url.to_string()))?;
        let port = url.port().unwrap_or(22);
        let path = url.path().trim_start_matches('/');
        if path.is_empty() {
            return Err(DownloadError::InvalidSftpUrl(url.to_string()));
        }
        if url.username().is_empty() {
            return Err(DownloadError::InvalidSftpUrl(
                "sftp url must include a username".to_string(),
            ));
        }
        let password = url.password().map(percent_decode);

        let file_name = requested_file_name
            .map(|name| sanitize_download_file_name(&name, "sftp-download.bin"))
            .unwrap_or_else(|| {
                path.rsplit('/')
                    .next()
                    .filter(|segment| !segment.is_empty())
                    .map(percent_decode)
                    .map(|name| sanitize_download_file_name(&name, "sftp-download.bin"))
                    .unwrap_or_else(|| "sftp-download.bin".to_string())
            });

        Ok(Self {
            address: format!("{host}:{port}"),
            host: host.to_string(),
            port,
            username: percent_decode(url.username()),
            password,
            private_key_pem: None,
            passphrase: None,
            remote_path: percent_decode(path),
            file_name,
        })
    }

    fn with_runtime_credential(mut self, credential: Option<&StoredCredential>) -> Self {
        if let Some(credential) = credential {
            self.username = credential.username.clone();
            if credential.uses_private_key() {
                self.password = None;
                self.private_key_pem = credential.private_key_pem.clone();
                self.passphrase = credential.passphrase.clone();
            }
        }
        self
    }
}

#[derive(Debug, Clone)]
struct SmbDownloadSpec {
    address: String,
    username: String,
    password: String,
    domain: String,
    share: String,
    remote_path: String,
    file_name: String,
}

impl SmbDownloadSpec {
    fn from_url(url: &Url, requested_file_name: Option<String>) -> Result<Self, DownloadError> {
        if url.scheme() != "smb" {
            return Err(DownloadError::InvalidSmbUrl(url.to_string()));
        }

        let host = url
            .host_str()
            .ok_or_else(|| DownloadError::InvalidSmbUrl(url.to_string()))?;
        let port = url.port().unwrap_or(445);
        let path_segments = url
            .path_segments()
            .ok_or_else(|| DownloadError::InvalidSmbUrl(url.to_string()))?
            .filter(|segment| !segment.is_empty())
            .map(percent_decode)
            .collect::<Vec<_>>();
        if path_segments.len() < 2 {
            return Err(DownloadError::InvalidSmbUrl(
                "smb url must include a share and remote file path".to_string(),
            ));
        }

        let share = path_segments[0].clone();
        let remote_path = path_segments[1..].join("/");
        let file_name = requested_file_name
            .map(|name| sanitize_download_file_name(&name, "smb-download.bin"))
            .unwrap_or_else(|| {
                path_segments
                    .last()
                    .filter(|segment| !segment.is_empty())
                    .map(|name| sanitize_download_file_name(name, "smb-download.bin"))
                    .unwrap_or_else(|| "smb-download.bin".to_string())
            });
        let domain = url
            .query_pairs()
            .find_map(|(key, value)| {
                if key.eq_ignore_ascii_case("domain") || key.eq_ignore_ascii_case("workgroup") {
                    Some(value.into_owned())
                } else {
                    None
                }
            })
            .unwrap_or_default();

        Ok(Self {
            address: format_smb_address(host, port),
            username: percent_decode(url.username()),
            password: url.password().map(percent_decode).unwrap_or_default(),
            domain,
            share,
            remote_path,
            file_name,
        })
    }

    fn client_config(&self) -> ClientConfig {
        ClientConfig {
            addr: self.address.clone(),
            timeout: std::time::Duration::from_secs(30),
            username: self.username.clone(),
            password: self.password.clone(),
            domain: self.domain.clone(),
            auto_reconnect: true,
            compression: true,
            dfs_enabled: true,
            dfs_target_overrides: std::collections::HashMap::new(),
        }
    }
}

#[derive(Debug, Clone)]
struct FtpDownloadSpec {
    address: String,
    host: String,
    username: String,
    password: String,
    remote_path: String,
    file_name: String,
    implicit_tls: bool,
    allow_bad_certificate: bool,
}

impl FtpDownloadSpec {
    fn from_url(url: &Url, requested_file_name: Option<String>) -> Result<Self, DownloadError> {
        let scheme = url.scheme();
        if scheme != "ftp" && scheme != "ftps" {
            return Err(DownloadError::InvalidFtpUrl(url.to_string()));
        }

        let host = url
            .host_str()
            .ok_or_else(|| DownloadError::InvalidFtpUrl(url.to_string()))?;
        let port = url
            .port()
            .unwrap_or(if scheme == "ftps" { 990 } else { 21 });
        let path = url.path().trim_start_matches('/');
        if path.is_empty() {
            return Err(DownloadError::InvalidFtpUrl(url.to_string()));
        }

        let file_name = requested_file_name
            .map(|name| sanitize_download_file_name(&name, "ftp-download.bin"))
            .unwrap_or_else(|| {
                path.rsplit('/')
                    .next()
                    .filter(|segment| !segment.is_empty())
                    .map(percent_decode)
                    .map(|name| sanitize_download_file_name(&name, "ftp-download.bin"))
                    .unwrap_or_else(|| "ftp-download.bin".to_string())
            });
        let username = if url.username().is_empty() {
            "anonymous".to_string()
        } else {
            percent_decode(url.username())
        };
        let password = url
            .password()
            .map(percent_decode)
            .unwrap_or_else(|| "anonymous@".to_string());

        Ok(Self {
            address: format!("{host}:{port}"),
            host: host.to_string(),
            username,
            password,
            remote_path: percent_decode(path),
            file_name,
            implicit_tls: scheme == "ftps" && port == 990,
            allow_bad_certificate: allows_bad_certificate(url),
        })
    }
}

fn percent_decode(value: &str) -> String {
    percent_encoding::percent_decode_str(value)
        .decode_utf8_lossy()
        .into_owned()
}

fn format_smb_address(host: &str, port: u16) -> String {
    if host.parse::<IpAddr>().is_ok_and(|ip| ip.is_ipv6()) {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    }
}

async fn run_ed2k_cli(
    request: DownloadRequest,
    command: &str,
) -> Result<DownloadSummary, DownloadError> {
    let protocol = request.protocol();
    let mut process = Command::new(command);
    process.arg(&request.source);

    let output = process.output().await?;
    if !output.status.success() {
        return Err(DownloadError::ExternalBackendFailed {
            protocol,
            backend: Backend::Amule,
            status: output.status.code().map_or_else(
                || "terminated by signal".to_string(),
                |code| code.to_string(),
            ),
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
        });
    }

    Ok(DownloadSummary {
        protocol,
        backend: Backend::Amule,
        output_path: request.output_dir,
        display_name: None,
        bytes_written: 0,
        resumed_from: 0,
        total_bytes: None,
        segments_written: None,
        sha256: None,
    })
}

async fn remux_hls_transport_stream(
    source_ts: &Path,
    output_mp4: &Path,
) -> Result<u64, DownloadError> {
    let _ = fs::remove_file(output_mp4).await;
    let output = Command::new("ffmpeg")
        .arg("-y")
        .arg("-loglevel")
        .arg("error")
        .arg("-i")
        .arg(source_ts)
        .arg("-c")
        .arg("copy")
        .arg(output_mp4)
        .output()
        .await
        .map_err(|error| DownloadError::HlsRemux(error.to_string()))?;

    if !output.status.success() {
        return Err(DownloadError::HlsRemux(
            String::from_utf8_lossy(&output.stderr).trim().to_string(),
        ));
    }

    let output_bytes = fs::metadata(output_mp4).await?.len();
    if output_bytes == 0 {
        return Err(DownloadError::HlsRemux(
            "ffmpeg produced an empty MP4".to_string(),
        ));
    }
    Ok(output_bytes)
}

fn hls_mp4_output_name(path: &Path) -> PathBuf {
    if path.extension().is_some_and(|extension| extension == "mp4") {
        path.to_path_buf()
    } else {
        path.with_extension("mp4")
    }
}

fn hls_transport_output_name(path: &Path) -> PathBuf {
    if path.extension().is_some_and(|extension| extension == "ts") {
        path.to_path_buf()
    } else {
        path.with_extension("ts")
    }
}

fn hls_temp_transport_path(output_mp4: &Path) -> PathBuf {
    let file_name = output_mp4
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("stream.mp4");
    output_mp4.with_file_name(format!(".{file_name}.ts"))
}

fn hls_segment_cache_dir(output_mp4: &Path) -> PathBuf {
    let stem = output_mp4
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("stream");
    output_mp4.with_file_name(format!(".{stem}.hls-parts"))
}

fn hls_segment_cache_file(cache_dir: &Path, index: usize) -> PathBuf {
    cache_dir.join(format!("{index:08}.ts"))
}

fn hls_segment_cache_temp_file(cache_file: &Path) -> PathBuf {
    cache_file.with_extension("ts.tmp")
}

fn hls_segment_cache_manifest_path(cache_dir: &Path) -> PathBuf {
    cache_dir.join("manifest.json")
}

fn hls_segment_cache_manifest_temp_path(cache_dir: &Path) -> PathBuf {
    cache_dir.join("manifest.json.tmp")
}

fn range_temp_output_path(output_path: &Path) -> PathBuf {
    let file_name = output_path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("download.bin");
    output_path.with_file_name(format!(".{file_name}.part"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TorrentFileMetadata;
    use aes::cipher::{BlockEncryptMut, block_padding::Pkcs7};
    use std::fs as std_fs;
    use std::sync::{
        OnceLock,
        atomic::{AtomicUsize, Ordering as AtomicOrdering},
    };
    use tokio::net::TcpListener;
    use tokio::sync::Mutex as AsyncMutex;

    type Aes128CbcEnc = cbc::Encryptor<aes::Aes128>;

    #[test]
    fn ftps_data_tls_error_carries_guidance() {
        let error = DownloadError::FtpsDataTls {
            source: suppaftp::FtpError::SecureError("bad record".into()),
        };
        let text = error.to_string();
        assert!(text.contains("TLS session reuse"), "unexpected: {text}");
        assert!(text.contains("suppaftp issue #93"), "unexpected: {text}");
    }

    #[test]
    fn ftp_data_errors_stay_transparent_for_plain_ftp() {
        let error = map_ftp_data_error(
            Protocol::Ftp,
            suppaftp::FtpError::SecureError("bad record".into()),
        );
        assert!(matches!(error, DownloadError::Ftp(_)));
        let error = map_ftp_data_error(
            Protocol::Ftps,
            suppaftp::FtpError::SecureError("bad record".into()),
        );
        assert!(matches!(error, DownloadError::FtpsDataTls { .. }));
    }

    #[test]
    fn download_errors_expose_actionable_retry_policy() {
        let storage_full = DownloadError::Io(std::io::Error::from(std::io::ErrorKind::StorageFull));
        assert!(!storage_full.is_retryable());
        assert!(storage_full.user_message().contains("磁盘空间不足"));

        let permission_denied =
            DownloadError::Io(std::io::Error::from(std::io::ErrorKind::PermissionDenied));
        assert!(!permission_denied.is_retryable());
        assert!(permission_denied.user_message().contains("不可写"));

        let incomplete = DownloadError::IncompleteTransfer {
            protocol: Protocol::Ftp,
            expected_bytes: 10,
            actual_bytes: 4,
        };
        assert!(incomplete.is_retryable());
        assert!(incomplete.user_message().contains("4/10"));

        let oversized = DownloadError::IncompleteTransfer {
            protocol: Protocol::Sftp,
            expected_bytes: 4,
            actual_bytes: 10,
        };
        assert!(!oversized.is_retryable());
        assert!(oversized.user_message().contains("本地文件大小异常"));

        let ftp_auth = DownloadError::Ftp(suppaftp::FtpError::UnexpectedResponse(
            suppaftp::types::Response::new(
                suppaftp::Status::NotLoggedIn,
                b"530 Login incorrect".to_vec(),
            ),
        ));
        assert!(!ftp_auth.is_retryable());
        assert!(ftp_auth.user_message().contains("FTP 认证失败"));

        let ftps_tls = DownloadError::FtpsDataTls {
            source: suppaftp::FtpError::SecureError("handshake failed".into()),
        };
        assert!(!ftps_tls.is_retryable());
        assert!(ftps_tls.user_message().contains("暂不兼容"));

        let sftp_auth = DownloadError::Sftp(ssh2::Error::new(
            ssh2::ErrorCode::Session(-18),
            "authentication failed",
        ));
        assert!(!sftp_auth.is_retryable());
        assert!(sftp_auth.user_message().contains("SFTP 认证失败"));

        let smb_timeout = DownloadError::Smb(smb2::Error::Timeout);
        assert!(smb_timeout.is_retryable());
        assert!(smb_timeout.user_message().contains("SMB 连接中断"));

        let smb_auth = DownloadError::Smb(smb2::Error::Auth {
            message: "bad credentials".to_string(),
        });
        assert!(!smb_auth.is_retryable());
        assert!(smb_auth.user_message().contains("SMB 认证失败"));

        let hls_invalid = DownloadError::InvalidM3u8;
        assert!(!hls_invalid.is_retryable());
        assert!(hls_invalid.user_message().contains("HLS 播放列表无效"));

        let no_peer = DownloadError::TorrentStalled {
            downloaded_bytes: 0,
            total_bytes: 10,
            elapsed_secs: 45,
        };
        assert!(no_peer.is_retryable());
        assert!(no_peer.user_message().contains("Peer"));
    }

    #[test]
    fn torrent_output_details_use_single_file_name() {
        let temp_dir = tempfile::tempdir().unwrap();
        let files = vec![PathBuf::from("20260614.mp4")];

        let (output_path, display_name) =
            torrent_output_details(temp_dir.path(), Some("download.torrent"), &files, 1);

        assert_eq!(output_path, temp_dir.path().join("20260614.mp4"));
        assert_eq!(display_name.as_deref(), Some("20260614.mp4"));
    }

    #[test]
    fn torrent_output_details_keeps_selected_multi_file_under_metadata_folder() {
        let temp_dir = tempfile::tempdir().unwrap();
        let files = vec![PathBuf::from("a-selected.bin")];

        let (output_path, display_name) =
            torrent_output_details(temp_dir.path(), Some("bundle"), &files, 2);

        assert_eq!(output_path, temp_dir.path().join("bundle/a-selected.bin"));
        assert_eq!(display_name.as_deref(), Some("a-selected.bin"));
    }

    #[test]
    fn torrent_output_details_use_common_top_level_folder() {
        let temp_dir = tempfile::tempdir().unwrap();
        let root = temp_dir.path().join("20260614_bundle");
        std_fs::create_dir_all(&root).unwrap();
        let files = vec![
            PathBuf::from("20260614_bundle/20260614.mp4"),
            PathBuf::from("20260614_bundle/readme.txt"),
        ];

        let (output_path, display_name) =
            torrent_output_details(temp_dir.path(), Some("metadata-name"), &files, files.len());

        assert_eq!(output_path, root);
        assert_eq!(display_name.as_deref(), Some("20260614_bundle"));
    }

    #[test]
    fn torrent_output_details_fall_back_to_metadata_name_without_common_root() {
        let temp_dir = tempfile::tempdir().unwrap();
        let files = vec![PathBuf::from("video.mp4"), PathBuf::from("readme.txt")];

        let (output_path, display_name) =
            torrent_output_details(temp_dir.path(), Some("loose-files"), &files, files.len());

        assert_eq!(output_path, temp_dir.path());
        assert_eq!(display_name.as_deref(), Some("loose-files"));
    }

    #[test]
    fn torrent_output_details_use_existing_metadata_folder_without_common_root() {
        let temp_dir = tempfile::tempdir().unwrap();
        let metadata_dir = temp_dir.path().join("loose-files");
        std_fs::create_dir_all(&metadata_dir).unwrap();
        let files = vec![PathBuf::from("video.mp4"), PathBuf::from("readme.txt")];

        let (output_path, display_name) =
            torrent_output_details(temp_dir.path(), Some("loose-files"), &files, files.len());

        assert_eq!(output_path, metadata_dir);
        assert_eq!(display_name.as_deref(), Some("loose-files"));
    }

    #[test]
    fn torrent_progress_only_counts_confirmed_files() {
        let mut request = DownloadRequest::new("magnet:?xt=urn:btih:test", "/tmp");
        request.torrent_file_indices = vec![1];
        request.torrent_files = vec![
            TorrentFileMetadata {
                index: 0,
                path: "bundle/skipped.txt".to_string(),
                name: "skipped.txt".to_string(),
                size: 21,
                is_streamable: false,
            },
            TorrentFileMetadata {
                index: 1,
                path: "bundle/selected.txt".to_string(),
                name: "selected.txt".to_string(),
                size: 22,
                is_streamable: false,
            },
        ];

        let (downloaded, total) = torrent_progress_for_request(&request, &[21, 22], 43, 43, false);
        assert_eq!((downloaded, total), (22, 22));
    }

    #[test]
    fn torrent_progress_preserves_whole_resource_without_selection() {
        let request = DownloadRequest::new("magnet:?xt=urn:btih:test", "/tmp");
        assert_eq!(
            torrent_progress_for_request(&request, &[21, 22], 43, 43, false),
            (43, 43)
        );
    }

    #[test]
    fn torrent_initializing_progress_never_counts_piece_checking_as_downloaded() {
        let request = DownloadRequest::new("magnet:?xt=urn:btih:test", "/tmp");
        assert_eq!(
            torrent_progress_for_request(&request, &[], 43, 43, true),
            (0, 43)
        );
    }

    #[test]
    fn parses_ftp_download_specs() {
        let url =
            Url::parse("ftp://user:p%40ss@example.com:2121/pub/releases/file%20one.bin").unwrap();
        let spec = FtpDownloadSpec::from_url(&url, None).unwrap();

        assert_eq!(spec.address, "example.com:2121");
        assert_eq!(spec.username, "user");
        assert_eq!(spec.password, "p@ss");
        assert_eq!(spec.remote_path, "pub/releases/file one.bin");
        assert_eq!(spec.file_name, "file one.bin");
        assert!(!spec.allow_bad_certificate);
    }

    #[test]
    fn sanitizes_inferred_and_requested_file_names() {
        let http_url = Url::parse("https://example.com/files/bad%2Fname%3F.bin").unwrap();
        assert_eq!(infer_file_name(&http_url, "download.bin"), "bad_name_.bin");

        let ftp_url = Url::parse("ftp://example.com/pub/bad%2Fname.bin").unwrap();
        let ftp_spec =
            FtpDownloadSpec::from_url(&ftp_url, Some("../custom:name.bin".to_string())).unwrap();
        assert_eq!(ftp_spec.file_name, "_custom_name.bin");

        let hls_request = DownloadRequest {
            source: "https://example.com/live/index.m3u8".to_string(),
            output_dir: PathBuf::from("/tmp/fluxdown"),
            file_name: Some("../movie:name.m3u8".to_string()),
            credential_ref: None,
            expected_sha256: None,
            torrent_file_indices: Vec::new(),
            torrent_name: None,
            torrent_files: Vec::new(),
            speed_limit_mbps: None,
            hls_variant_index: None,
            hls_keep_transport_stream: None,
            task_id: None,
        };
        let candidates = output_file_candidates_for_request(&hls_request);
        assert!(candidates.contains(&PathBuf::from("/tmp/fluxdown/_movie_name.mp4")));
    }

    #[test]
    fn uses_anonymous_ftp_defaults_and_requested_name() {
        let url = Url::parse("ftp://example.com/pub/file.bin").unwrap();
        let spec = FtpDownloadSpec::from_url(&url, Some("renamed.bin".to_string())).unwrap();

        assert_eq!(spec.address, "example.com:21");
        assert_eq!(spec.host, "example.com");
        assert_eq!(spec.username, "anonymous");
        assert_eq!(spec.password, "anonymous@");
        assert_eq!(spec.remote_path, "pub/file.bin");
        assert_eq!(spec.file_name, "renamed.bin");
        assert!(!spec.implicit_tls);
    }

    #[test]
    fn parses_ftps_download_specs() {
        let url = Url::parse("ftps://example.com/pub/file.bin").unwrap();
        let spec = FtpDownloadSpec::from_url(&url, None).unwrap();

        assert_eq!(spec.address, "example.com:990");
        assert_eq!(spec.host, "example.com");
        assert_eq!(spec.file_name, "file.bin");
        assert!(spec.implicit_tls);
        assert!(!spec.allow_bad_certificate);
    }

    #[test]
    fn parses_local_ftps_bad_certificate_opt_in() {
        let url =
            Url::parse("ftps://user:pass@127.0.0.1:2121/pub/file.bin?allowBadCertificate=true")
                .unwrap();
        let spec = FtpDownloadSpec::from_url(&url, None).unwrap();

        assert_eq!(spec.address, "127.0.0.1:2121");
        assert!(!spec.implicit_tls);
        assert!(spec.allow_bad_certificate);
    }

    #[test]
    fn protocol_specs_keep_local_file_names_inside_output_dir() {
        let ftp_url = Url::parse("ftp://example.com/pub/bad%2Fname.bin").unwrap();
        let sftp_url = Url::parse("sftp://user:pass@example.com/pub/%2Fescape.bin").unwrap();
        let smb_url = Url::parse("smb://nas/Share/path/bad%5Cname?.bin").unwrap();

        assert_eq!(
            FtpDownloadSpec::from_url(&ftp_url, None).unwrap().file_name,
            "bad_name.bin"
        );
        assert_eq!(
            SftpDownloadSpec::from_url(&sftp_url, None)
                .unwrap()
                .file_name,
            "_escape.bin"
        );
        assert_eq!(
            SmbDownloadSpec::from_url(&smb_url, None).unwrap().file_name,
            "bad_name"
        );
    }

    #[test]
    fn parses_sftp_download_specs() {
        let url =
            Url::parse("sftp://user:p%40ss@example.com:2222/pub/releases/file%20one.bin").unwrap();
        let spec = SftpDownloadSpec::from_url(&url, None).unwrap();

        assert_eq!(spec.address, "example.com:2222");
        assert_eq!(spec.username, "user");
        assert_eq!(spec.password.as_deref(), Some("p@ss"));
        assert_eq!(spec.remote_path, "pub/releases/file one.bin");
        assert_eq!(spec.file_name, "file one.bin");
    }

    #[test]
    fn parses_sftp_download_spec_without_password_for_ssh_agent() {
        let url = Url::parse("sftp://agent@example.com/pub/releases/file.bin").unwrap();
        let spec = SftpDownloadSpec::from_url(&url, None).unwrap();

        assert_eq!(spec.username, "agent");
        assert_eq!(spec.password, None);
        assert_eq!(spec.remote_path, "pub/releases/file.bin");
    }

    #[test]
    fn sftp_known_hosts_option_keeps_non_empty_path_and_drops_empty_path() {
        let path = PathBuf::from("/tmp/fluxdown-known-hosts");
        let options = DownloadOptions::default().with_sftp_known_hosts(Some(path.clone()));
        assert_eq!(options.sftp_known_hosts, Some(path));

        let empty = DownloadOptions::default().with_sftp_known_hosts(Some(PathBuf::new()));
        assert_eq!(empty.sftp_known_hosts, None);
    }

    #[test]
    fn missing_sftp_known_hosts_is_a_non_retryable_host_key_error() {
        let spec = SftpDownloadSpec::from_url(
            &Url::parse("sftp://user:pass@example.com:2222/pub/file.bin").unwrap(),
            None,
        )
        .unwrap();
        let session = SshSession::new().expect("create SSH session for preflight check");
        let missing = tempfile::tempdir()
            .unwrap()
            .path()
            .join("missing-known-hosts");

        let error = verify_sftp_host_key(&session, &spec.host, spec.port, &missing).unwrap_err();
        assert!(matches!(
            error,
            DownloadError::SftpHostKeyVerification { .. }
        ));
        assert!(!error.is_retryable());
        assert!(error.user_message().contains("known_hosts"));
    }

    #[test]
    fn sftp_host_key_mismatch_is_not_automatically_retried() {
        let error = DownloadError::SftpHostKeyVerification {
            message: "known_hosts 中的主机密钥与服务端不一致".to_string(),
        };
        assert!(!error.is_retryable());
        assert!(error.user_message().contains("主机身份校验失败"));
    }

    #[test]
    fn parses_smb_download_specs() {
        let url = Url::parse(
            "smb://DOMAIN%5Cuser:p%40ss@nas.example.com:1445/Media/Shows/file%20one.mkv?domain=WORKGROUP",
        )
        .unwrap();
        let spec = SmbDownloadSpec::from_url(&url, None).unwrap();

        assert_eq!(spec.address, "nas.example.com:1445");
        assert_eq!(spec.username, "DOMAIN\\user");
        assert_eq!(spec.password, "p@ss");
        assert_eq!(spec.domain, "WORKGROUP");
        assert_eq!(spec.share, "Media");
        assert_eq!(spec.remote_path, "Shows/file one.mkv");
        assert_eq!(spec.file_name, "file one.mkv");
    }

    #[test]
    fn parses_smb_requested_file_name_and_ipv6_address() {
        let url = Url::parse("smb://[2001:db8::1]/Share/path/file.bin").unwrap();
        let spec = SmbDownloadSpec::from_url(&url, Some("renamed.bin".to_string())).unwrap();

        assert_eq!(spec.address, "[2001:db8::1]:445");
        assert_eq!(spec.file_name, "renamed.bin");
        assert_eq!(spec.remote_path, "path/file.bin");
    }

    #[test]
    fn rejects_smb_urls_without_share_and_path() {
        let url = Url::parse("smb://nas/Media").unwrap();
        assert!(SmbDownloadSpec::from_url(&url, None).is_err());
    }

    #[tokio::test]
    async fn accepts_magnet_sources_for_builtin_torrent_engine() {
        let add = torrent_source(
            "magnet:?xt=urn:btih:0123456789012345678901234567890123456789",
            Protocol::Magnet,
        )
        .await
        .unwrap();

        assert!(matches!(add, AddTorrent::Url(_)));
    }

    #[tokio::test]
    async fn runs_ed2k_cli_backend_when_available() {
        static PATH_LOCK: OnceLock<AsyncMutex<()>> = OnceLock::new();
        let _guard = PATH_LOCK.get_or_init(|| AsyncMutex::new(())).lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let log_path = temp_dir.path().join("ed2k-args.log");
        let command_path = fake_ed2k_command(temp_dir.path(), &log_path);
        let original_path = std::env::var_os("PATH").unwrap_or_default();
        let mut paths = vec![temp_dir.path().to_path_buf()];
        paths.extend(std::env::split_paths(&original_path));
        let test_path = std::env::join_paths(paths).unwrap();
        unsafe {
            std::env::set_var("PATH", test_path);
        }

        let summary = DownloadEngine::new()
            .download(DownloadRequest::new(
                "ed2k://|file|example.iso|123|ABCDEF|/",
                temp_dir.path(),
            ))
            .await
            .unwrap();

        unsafe {
            std::env::set_var("PATH", original_path);
        }

        assert_eq!(summary.backend, Backend::Amule);
        assert_eq!(summary.output_path, temp_dir.path());
        assert_eq!(
            std_fs::read_to_string(log_path).unwrap(),
            "ed2k://|file|example.iso|123|ABCDEF|/\n"
        );
        assert!(command_path.exists());
    }

    #[cfg(unix)]
    fn fake_ed2k_command(dir: &Path, log_path: &Path) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;

        let path = dir.join("ed2k");
        std_fs::write(
            &path,
            format!("#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then exit 0; fi\nprintf '%s\\n' \"$1\" > '{}'\n", log_path.display()),
        )
        .unwrap();
        std_fs::set_permissions(&path, std_fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    #[cfg(windows)]
    fn fake_ed2k_command(dir: &Path, log_path: &Path) -> PathBuf {
        let source_path = dir.join("ed2k-fake.rs");
        let path = dir.join("ed2k.exe");
        let log_literal = format!("{:?}", log_path.display().to_string());
        std_fs::write(
            &source_path,
            format!(
                r#"
fn main() {{
    let first = match std::env::args().nth(1) {{
        Some(arg) => arg,
        None => std::process::exit(1),
    }};

    if first == "--version" {{
        return;
    }}

    std::fs::write({log_literal}, format!("{{first}}\n")).unwrap();
}}
"#
            ),
        )
        .unwrap();
        let output = std::process::Command::new("rustc")
            .arg(&source_path)
            .arg("-o")
            .arg(&path)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "failed to build fake ed2k command: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        path
    }

    #[test]
    fn detects_bad_certificate_opt_in_case_insensitively() {
        let url = Url::parse("https://127.0.0.1/file.txt?allowBadCertificate=TRUE").unwrap();

        assert!(allows_bad_certificate(&url));
    }

    #[test]
    fn maps_webdav_urls_to_http_urls() {
        assert_eq!(
            webdav_http_url("webdav://cloud.example.com/remote.php/dav/files/a.zip").unwrap(),
            "http://cloud.example.com/remote.php/dav/files/a.zip",
        );
        assert_eq!(
            webdav_http_url("webdavs://user:pass@cloud.example.com/files/a.zip?download=1")
                .unwrap(),
            "https://user:pass@cloud.example.com/files/a.zip?download=1",
        );
    }

    #[test]
    fn extracts_url_credentials_for_basic_auth() {
        let mut url = Url::parse("https://user:p%40ss@example.com/file.bin").unwrap();
        let credentials = url_credentials(&mut url).unwrap();

        assert_eq!(
            credentials,
            Some(("user".to_string(), Some("p@ss".to_string())))
        );
        assert_eq!(url.as_str(), "https://example.com/file.bin");
    }

    #[test]
    fn runtime_mobile_credential_is_injected_without_serializing_secret_options() {
        let mut request = DownloadRequest::new("https://example.com/private.bin", "/tmp");
        request.credential_ref = Some("office-http".to_string());
        let credential = StoredCredential::password("alice", "secret-pass");
        let resolved = request_with_credentials(request, Some(&credential)).unwrap();
        assert!(resolved.source.contains("alice"));
        assert!(resolved.source.contains("secret-pass"));

        let options = DownloadOptions::default().with_runtime_credential(Some(credential));
        let serialized = serde_json::to_string(&options).unwrap();
        assert!(!serialized.contains("secret-pass"));
    }

    #[test]
    fn credential_reference_rejects_url_credentials_before_keyring_lookup() {
        let mut request =
            DownloadRequest::new("https://user:password@example.com/private.bin", "/tmp");
        request.credential_ref = Some("office-http".to_string());

        let error = request_with_credentials(request, None).unwrap_err();

        assert!(matches!(error, DownloadError::CredentialConflict));
        assert!(!error.is_retryable());
        assert!(error.user_message().contains("不能同时使用凭据引用"));
        assert!(!error.user_message().contains("password"));
    }

    #[test]
    fn credential_reference_rejects_unsupported_protocol_before_keyring_lookup() {
        let mut request = DownloadRequest::new("magnet:?xt=urn:btih:abc", "/tmp");
        request.credential_ref = Some("office-http".to_string());

        let error = request_with_credentials(request, None).unwrap_err();

        assert!(matches!(
            error,
            DownloadError::CredentialUnsupportedProtocol(Protocol::Magnet)
        ));
        assert!(!error.is_retryable());
        assert!(error.user_message().contains("MAGNET 协议"));
    }

    #[test]
    fn invalid_credential_reference_is_non_retryable_and_redacted() {
        let mut request = DownloadRequest::new("https://example.com/private.bin", "/tmp");
        request.credential_ref = Some("   ".to_string());

        let error = request_with_credentials(request, None).unwrap_err();

        assert!(matches!(error, DownloadError::CredentialUnavailable { .. }));
        assert!(!error.is_retryable());
        assert!(error.user_message().contains("下载凭据不可用"));
        assert!(!error.user_message().contains("office"));
    }

    #[tokio::test]
    async fn speed_limiter_paces_initial_chunk() {
        let limiter = DownloadSpeedLimiter::new(Some(256 * 1024));
        let started = Instant::now();

        limiter.wait_with_cancel(64 * 1024, None).await.unwrap();

        assert!(started.elapsed() >= Duration::from_millis(220));
    }

    #[tokio::test]
    async fn speed_limiter_wait_can_be_cancelled() {
        let limiter = DownloadSpeedLimiter::new(Some(256 * 1024));
        let cancel = CancelToken::default();
        let cancel_after_delay = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            cancel_after_delay.cancel();
        });

        let result = tokio::time::timeout(
            Duration::from_secs(1),
            limiter.wait_with_cancel(512 * 1024, Some(&cancel)),
        )
        .await
        .expect("cancelled limiter wait should return promptly");

        assert!(matches!(result, Err(DownloadError::Paused)));
    }

    #[tokio::test]
    async fn downloads_http_ranges_when_threads_requested() {
        let payload = Arc::new(
            (0..(256 * 1024))
                .map(|index| (index % 251) as u8)
                .collect::<Vec<_>>(),
        );
        let range_hits = Arc::new(AtomicUsize::new(0));
        let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let source = format!("http://{}/payload.bin", server.local_addr().unwrap());
        let server_payload = Arc::clone(&payload);
        let server_range_hits = Arc::clone(&range_hits);
        let server_task = tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = server.accept().await else {
                    return;
                };
                let payload = Arc::clone(&server_payload);
                let range_hits = Arc::clone(&server_range_hits);
                tokio::spawn(async move {
                    let mut buffer = [0; 2048];
                    let Ok(read) = stream.read(&mut buffer).await else {
                        return;
                    };
                    let request = String::from_utf8_lossy(&buffer[..read]);
                    let method = request
                        .lines()
                        .next()
                        .and_then(|line| line.split_whitespace().next())
                        .unwrap_or("GET");

                    if method == "HEAD" {
                        let header = format!(
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                            payload.len()
                        );
                        let _ = stream.write_all(header.as_bytes()).await;
                        let _ = stream.shutdown().await;
                        return;
                    }

                    let (status, extra_header, body) =
                        if let Some((start, end)) = requested_range(&request) {
                            range_hits.fetch_add(1, AtomicOrdering::SeqCst);
                            let body = payload[start..=end].to_vec();
                            (
                                "206 Partial Content",
                                format!("Content-Range: bytes {start}-{end}/{}\r\n", payload.len()),
                                body,
                            )
                        } else {
                            ("200 OK", String::new(), payload.to_vec())
                        };
                    let header = format!(
                        "HTTP/1.1 {status}\r\nContent-Length: {}\r\n{extra_header}Connection: close\r\n\r\n",
                        body.len()
                    );
                    let _ = stream.write_all(header.as_bytes()).await;
                    let _ = stream.write_all(&body).await;
                    let _ = stream.shutdown().await;
                });
            }
        });

        let temp_dir = tempfile::tempdir().unwrap();
        let summary = DownloadEngine::new()
            .download_with_options(
                DownloadRequest::new(source, temp_dir.path()),
                DownloadOptions::new(4, None),
            )
            .await
            .unwrap();

        assert_eq!(summary.bytes_written, payload.len() as u64);
        assert_eq!(
            fs::read(temp_dir.path().join("payload.bin")).await.unwrap(),
            payload.as_slice(),
        );
        assert!(range_hits.load(AtomicOrdering::SeqCst) >= 2);
        server_task.abort();
    }

    #[tokio::test]
    async fn failed_http_range_download_does_not_poison_retry() {
        let payload = Arc::new(
            (0..(128 * 1024))
                .map(|index| (index % 197) as u8)
                .collect::<Vec<_>>(),
        );
        let failed_ranges = Arc::new(AtomicUsize::new(0));
        let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let source = format!("http://{}/payload.bin", server.local_addr().unwrap());
        let server_payload = Arc::clone(&payload);
        let server_failed_ranges = Arc::clone(&failed_ranges);
        let server_task = tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = server.accept().await else {
                    return;
                };
                let payload = Arc::clone(&server_payload);
                let failed_ranges = Arc::clone(&server_failed_ranges);
                tokio::spawn(async move {
                    let mut buffer = [0; 2048];
                    let Ok(read) = stream.read(&mut buffer).await else {
                        return;
                    };
                    let request = String::from_utf8_lossy(&buffer[..read]);
                    let method = request
                        .lines()
                        .next()
                        .and_then(|line| line.split_whitespace().next())
                        .unwrap_or("GET");

                    if method == "HEAD" {
                        let header = format!(
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                            payload.len()
                        );
                        let _ = stream.write_all(header.as_bytes()).await;
                        let _ = stream.shutdown().await;
                        return;
                    }

                    let Some((start, end)) = requested_range(&request) else {
                        let header = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                        let _ = stream.write_all(header.as_bytes()).await;
                        let _ = stream.shutdown().await;
                        return;
                    };
                    let mut body = payload[start..=end].to_vec();
                    if failed_ranges.fetch_add(1, AtomicOrdering::SeqCst) == 0 {
                        body.truncate(body.len().saturating_sub(8));
                    }
                    let header = format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{end}/{}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                        body.len(),
                        payload.len()
                    );
                    let _ = stream.write_all(header.as_bytes()).await;
                    let _ = stream.write_all(&body).await;
                    let _ = stream.shutdown().await;
                });
            }
        });

        let temp_dir = tempfile::tempdir().unwrap();
        let request = DownloadRequest::new(source, temp_dir.path());
        let first = DownloadEngine::new()
            .download_with_options(request.clone(), DownloadOptions::new(4, None))
            .await;

        assert!(first.is_err());
        assert!(!temp_dir.path().join("payload.bin").exists());
        assert!(!range_temp_output_path(&temp_dir.path().join("payload.bin")).exists());

        let summary = DownloadEngine::new()
            .download_with_options(request, DownloadOptions::new(4, None))
            .await
            .unwrap();

        assert_eq!(summary.bytes_written, payload.len() as u64);
        assert_eq!(
            fs::read(temp_dir.path().join("payload.bin")).await.unwrap(),
            payload.as_slice(),
        );
        server_task.abort();
    }

    fn requested_range(request: &str) -> Option<(usize, usize)> {
        let range = request.lines().find_map(|line| {
            let (name, value) = line.split_once(':')?;
            if name.eq_ignore_ascii_case("range") {
                Some(value.trim())
            } else {
                None
            }
        })?;
        let value = range.strip_prefix("bytes=")?;
        let (start, end) = value.split_once('-')?;
        Some((start.parse().ok()?, end.parse().ok()?))
    }

    #[test]
    fn parses_explicit_hls_iv() {
        let iv = parse_hls_hex_iv("0x0000000000000000000000000000000f").unwrap();

        assert_eq!(iv, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 15]);
    }

    #[test]
    fn derives_hls_iv_from_media_sequence() {
        assert_eq!(
            hls_sequence_iv(258),
            [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2],
        );
    }

    #[test]
    fn decrypts_hls_aes128_segments() {
        let key = *b"0123456789abcdef";
        let iv = hls_sequence_iv(7);
        let plain = b"clear transport stream bytes";
        let ciphertext =
            Aes128CbcEnc::new(&key.into(), &iv.into()).encrypt_padded_vec_mut::<Pkcs7>(plain);

        let decrypted = decrypt_hls_aes128(&ciphertext, key, iv).unwrap();

        assert_eq!(decrypted, plain);
    }

    #[test]
    fn rejects_empty_hls_media_playlist() {
        let playlist = m3u8_rs::parse_playlist_res(b"#EXTM3U\n#EXT-X-ENDLIST\n").unwrap();
        let m3u8_rs::Playlist::MediaPlaylist(media) = playlist else {
            panic!("expected media playlist");
        };

        assert!(matches!(
            ensure_hls_media_has_segments(&media),
            Err(DownloadError::InvalidM3u8)
        ));
    }

    #[test]
    fn torrent_session_options_enable_peer_listener() {
        let options = torrent_session_options(Some(1024));

        assert_eq!(
            options.listen_port_range,
            Some(TORRENT_LISTEN_PORT_START..TORRENT_LISTEN_PORT_END)
        );
        assert!(options.disable_dht_persistence);
        assert!(options.ratelimits.download_bps.is_some());
    }

    #[tokio::test]
    async fn downloads_aes128_hls_playlist() {
        let key = *b"0123456789abcdef";
        let first_plain = b"first clear transport chunk".to_vec();
        let second_plain = b"second clear transport stream chunk".to_vec();
        let first_encrypted = Aes128CbcEnc::new(&key.into(), &hls_sequence_iv(7).into())
            .encrypt_padded_vec_mut::<Pkcs7>(&first_plain);
        let second_encrypted = Aes128CbcEnc::new(&key.into(), &hls_sequence_iv(8).into())
            .encrypt_padded_vec_mut::<Pkcs7>(&second_plain);
        let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let source = format!("http://{}/playlist.m3u8", server.local_addr().unwrap());
        let server_task = tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = server.accept().await else {
                    return;
                };
                let mut buffer = [0; 1024];
                let Ok(read) = stream.read(&mut buffer).await else {
                    continue;
                };
                let request = String::from_utf8_lossy(&buffer[..read]);
                let path = request
                    .lines()
                    .next()
                    .and_then(|line| line.split_whitespace().nth(1))
                    .unwrap_or("/");
                let (status, content_type, body): (&str, &str, Vec<u8>) = match path {
                    "/playlist.m3u8" => (
                        "200 OK",
                        "application/vnd.apple.mpegurl",
                        b"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-MEDIA-SEQUENCE:7\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:1,\nseg-1.ts\n#EXTINF:1,\nseg-2.ts\n#EXT-X-ENDLIST\n"
                            .to_vec(),
                    ),
                    "/key.bin" => ("200 OK", "application/octet-stream", key.to_vec()),
                    "/seg-1.ts" => (
                        "200 OK",
                        "video/mp2t",
                        first_encrypted.clone(),
                    ),
                    "/seg-2.ts" => (
                        "200 OK",
                        "video/mp2t",
                        second_encrypted.clone(),
                    ),
                    _ => ("404 Not Found", "text/plain", b"not found".to_vec()),
                };
                let header = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = stream.write_all(header.as_bytes()).await;
                let _ = stream.write_all(&body).await;
                let _ = stream.shutdown().await;
            }
        });

        let temp_dir = tempfile::tempdir().unwrap();
        let summary = DownloadEngine::new()
            .download(DownloadRequest::new(source, temp_dir.path()))
            .await
            .unwrap();

        assert_eq!(summary.segments_written, Some(2));
        assert_eq!(
            summary.bytes_written,
            (first_plain.len() + second_plain.len()) as u64
        );
        assert_eq!(
            fs::read(temp_dir.path().join("playlist.ts")).await.unwrap(),
            [first_plain, second_plain].concat(),
        );
        server_task.abort();
    }

    #[tokio::test]
    async fn downloads_hls_byte_range_segments() {
        let first_segment = b"core hls byte range first".to_vec();
        let second_segment = b"second range segment".to_vec();
        let first_len = first_segment.len();
        let second_len = second_segment.len();
        let media = [first_segment.clone(), second_segment.clone()].concat();
        let requested_ranges = Arc::new(AsyncMutex::new(Vec::new()));
        let server_requested_ranges = Arc::clone(&requested_ranges);
        let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let source = format!("http://{}/playlist.m3u8", server.local_addr().unwrap());
        let server_task = tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = server.accept().await else {
                    return;
                };
                let media = media.clone();
                let requested_ranges = Arc::clone(&server_requested_ranges);
                tokio::spawn(async move {
                    let mut buffer = [0; 2048];
                    let Ok(read) = stream.read(&mut buffer).await else {
                        return;
                    };
                    let request = String::from_utf8_lossy(&buffer[..read]);
                    let path = request
                        .lines()
                        .next()
                        .and_then(|line| line.split_whitespace().nth(1))
                        .unwrap_or("/");
                    let range = request.lines().find_map(|line| {
                        let (name, value) = line.split_once(':')?;
                        if name.eq_ignore_ascii_case("range") {
                            Some(value.trim().to_string())
                        } else {
                            None
                        }
                    });
                    let (status, content_type, headers, body): (&str, &str, String, Vec<u8>) =
                        match path {
                            "/playlist.m3u8" => (
                                "200 OK",
                                "application/vnd.apple.mpegurl",
                                String::new(),
                                format!(
                                    "#EXTM3U\n#EXT-X-VERSION:4\n#EXTINF:1,\n#EXT-X-BYTERANGE:{}@0\nmedia.ts\n#EXTINF:1,\n#EXT-X-BYTERANGE:{}\nmedia.ts\n#EXT-X-ENDLIST\n",
                                    first_len,
                                    second_len
                                )
                                .into_bytes(),
                            ),
                            "/media.ts" => {
                                requested_ranges
                                    .lock()
                                    .await
                                    .push(range.clone().unwrap_or_default());
                                let (start, end) = requested_range(
                                    &format!(
                                        "GET /media.ts HTTP/1.1\r\nRange: {}\r\n\r\n",
                                        range.as_deref().unwrap_or_default()
                                    ),
                                )
                                .unwrap();
                                (
                                    "206 Partial Content",
                                    "video/mp2t",
                                    format!(
                                        "Content-Range: bytes {start}-{end}/{}\r\n",
                                        media.len()
                                    ),
                                    media[start..=end].to_vec(),
                                )
                            }
                            _ => (
                                "404 Not Found",
                                "text/plain",
                                String::new(),
                                b"not found".to_vec(),
                            ),
                        };
                    let header = format!(
                        "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\n{headers}Content-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    );
                    let _ = stream.write_all(header.as_bytes()).await;
                    let _ = stream.write_all(&body).await;
                    let _ = stream.shutdown().await;
                });
            }
        });

        let temp_dir = tempfile::tempdir().unwrap();
        let summary = DownloadEngine::new()
            .download(DownloadRequest::new(source, temp_dir.path()))
            .await
            .unwrap();

        assert_eq!(summary.segments_written, Some(2));
        assert_eq!(
            summary.bytes_written,
            (first_segment.len() + second_segment.len()) as u64
        );
        assert_eq!(
            fs::read(temp_dir.path().join("playlist.ts")).await.unwrap(),
            [first_segment.clone(), second_segment.clone()].concat(),
        );
        let mut ranges = requested_ranges.lock().await.clone();
        ranges.sort();
        let mut expected = vec![
            format!("bytes=0-{}", first_segment.len() - 1),
            format!(
                "bytes={}-{}",
                first_segment.len(),
                first_segment.len() + second_segment.len() - 1
            ),
        ];
        expected.sort();
        assert_eq!(ranges, expected);
        server_task.abort();
    }

    #[tokio::test]
    async fn retries_hls_segment_connection_reset() {
        let failed_segment_requests = Arc::new(AtomicUsize::new(0));
        let server_failed_segment_requests = Arc::clone(&failed_segment_requests);
        let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let source = format!("http://{}/playlist.m3u8", server.local_addr().unwrap());
        let server_task = tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = server.accept().await else {
                    return;
                };
                let mut buffer = [0; 1024];
                let Ok(read) = stream.read(&mut buffer).await else {
                    continue;
                };
                let request = String::from_utf8_lossy(&buffer[..read]);
                let path = request
                    .lines()
                    .next()
                    .and_then(|line| line.split_whitespace().nth(1))
                    .unwrap_or("/");
                if path == "/seg-1.ts"
                    && server_failed_segment_requests.fetch_add(1, AtomicOrdering::SeqCst) == 0
                {
                    continue;
                }
                let (status, content_type, body): (&str, &str, Vec<u8>) = match path {
                    "/playlist.m3u8" => (
                        "200 OK",
                        "application/vnd.apple.mpegurl",
                        b"#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:1,\nseg-1.ts\n#EXTINF:1,\nseg-2.ts\n#EXT-X-ENDLIST\n"
                            .to_vec(),
                    ),
                    "/seg-1.ts" => ("200 OK", "video/mp2t", b"first segment".to_vec()),
                    "/seg-2.ts" => ("200 OK", "video/mp2t", b"second segment".to_vec()),
                    _ => ("404 Not Found", "text/plain", b"not found".to_vec()),
                };
                let header = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = stream.write_all(header.as_bytes()).await;
                let _ = stream.write_all(&body).await;
                let _ = stream.shutdown().await;
            }
        });

        let temp_dir = tempfile::tempdir().unwrap();
        let summary = DownloadEngine::new()
            .download_with_options(
                DownloadRequest::new(source, temp_dir.path()),
                DownloadOptions::new(1, None),
            )
            .await
            .unwrap();

        assert_eq!(failed_segment_requests.load(AtomicOrdering::SeqCst), 2);
        assert_eq!(summary.segments_written, Some(2));
        assert_eq!(
            fs::read(temp_dir.path().join("playlist.ts")).await.unwrap(),
            b"first segmentsecond segment"
        );
        server_task.abort();
    }

    #[tokio::test]
    async fn does_not_retry_hls_segment_not_found() {
        let segment_requests = Arc::new(AtomicUsize::new(0));
        let server_segment_requests = Arc::clone(&segment_requests);
        let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let source = format!("http://{}/playlist.m3u8", server.local_addr().unwrap());
        let server_task = tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = server.accept().await else {
                    return;
                };
                let mut buffer = [0; 1024];
                let Ok(read) = stream.read(&mut buffer).await else {
                    continue;
                };
                let request = String::from_utf8_lossy(&buffer[..read]);
                let path = request
                    .lines()
                    .next()
                    .and_then(|line| line.split_whitespace().nth(1))
                    .unwrap_or("/");
                let (status, content_type, body): (&str, &str, &[u8]) = match path {
                    "/playlist.m3u8" => (
                        "200 OK",
                        "application/vnd.apple.mpegurl",
                        b"#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:1,\nmissing.ts\n#EXT-X-ENDLIST\n",
                    ),
                    "/missing.ts" => {
                        server_segment_requests.fetch_add(1, AtomicOrdering::SeqCst);
                        ("404 Not Found", "text/plain", b"not found")
                    }
                    _ => ("404 Not Found", "text/plain", b"not found"),
                };
                let header = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = stream.write_all(header.as_bytes()).await;
                let _ = stream.write_all(body).await;
                let _ = stream.shutdown().await;
            }
        });

        let temp_dir = tempfile::tempdir().unwrap();
        let error = DownloadEngine::new()
            .download_with_options(
                DownloadRequest::new(source, temp_dir.path()),
                DownloadOptions::new(1, None),
            )
            .await
            .unwrap_err();

        assert!(matches!(error, DownloadError::Http(_)));
        assert!(!error.is_retryable());
        assert_eq!(segment_requests.load(AtomicOrdering::SeqCst), 1);
        server_task.abort();
    }

    #[tokio::test]
    async fn downloads_hls_master_playlist_through_first_variant() {
        let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let source = format!("http://{}/master.m3u8", server.local_addr().unwrap());
        let server_task = tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = server.accept().await else {
                    return;
                };
                let mut buffer = [0; 1024];
                let Ok(read) = stream.read(&mut buffer).await else {
                    continue;
                };
                let request = String::from_utf8_lossy(&buffer[..read]);
                let path = request
                    .lines()
                    .next()
                    .and_then(|line| line.split_whitespace().nth(1))
                    .unwrap_or("/");
                let (status, content_type, body): (&str, &str, Vec<u8>) = match path {
                    "/master.m3u8" => (
                        "200 OK",
                        "application/vnd.apple.mpegurl",
                        b"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=64000\nvariants/low.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=256000\nvariants/high.m3u8\n"
                            .to_vec(),
                    ),
                    "/variants/low.m3u8" => (
                        "200 OK",
                        "application/vnd.apple.mpegurl",
                        b"#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:1,\nlow-1.ts\n#EXTINF:1,\nlow-2.ts\n#EXT-X-ENDLIST\n"
                            .to_vec(),
                    ),
                    "/variants/low-1.ts" => {
                        ("200 OK", "video/mp2t", b"low variant segment one".to_vec())
                    }
                    "/variants/low-2.ts" => {
                        ("200 OK", "video/mp2t", b"low variant segment two".to_vec())
                    }
                    "/variants/high.m3u8" | "/variants/high-1.ts" => (
                        "500 Internal Server Error",
                        "text/plain",
                        b"high variant should not be requested".to_vec(),
                    ),
                    _ => ("404 Not Found", "text/plain", b"not found".to_vec()),
                };
                let header = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = stream.write_all(header.as_bytes()).await;
                let _ = stream.write_all(&body).await;
                let _ = stream.shutdown().await;
            }
        });

        let temp_dir = tempfile::tempdir().unwrap();
        let summary = DownloadEngine::new()
            .download(DownloadRequest::new(source, temp_dir.path()))
            .await
            .unwrap();

        assert_eq!(summary.segments_written, Some(2));
        assert_eq!(summary.bytes_written, 46);
        assert_eq!(
            fs::read(temp_dir.path().join("master.ts")).await.unwrap(),
            b"low variant segment onelow variant segment two"
        );
        server_task.abort();
    }

    #[tokio::test]
    async fn downloads_hls_master_playlist_variant_by_index() {
        let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let source = format!("http://{}/master.m3u8", server.local_addr().unwrap());
        let server_task = tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = server.accept().await else {
                    return;
                };
                let mut buffer = [0; 1024];
                let Ok(read) = stream.read(&mut buffer).await else {
                    continue;
                };
                let request = String::from_utf8_lossy(&buffer[..read]);
                let path = request
                    .lines()
                    .next()
                    .and_then(|line| line.split_whitespace().nth(1))
                    .unwrap_or("/");
                let (status, content_type, body): (&str, &str, Vec<u8>) = match path {
                    "/master.m3u8" => (
                        "200 OK",
                        "application/vnd.apple.mpegurl",
                        b"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=64000\nvariants/low.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=256000\nvariants/high.m3u8\n"
                            .to_vec(),
                    ),
                    "/variants/high.m3u8" => (
                        "200 OK",
                        "application/vnd.apple.mpegurl",
                        b"#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:1,\nhigh-1.ts\n#EXT-X-ENDLIST\n"
                            .to_vec(),
                    ),
                    "/variants/high-1.ts" => {
                        ("200 OK", "video/mp2t", b"high variant only".to_vec())
                    }
                    "/variants/low.m3u8" | "/variants/low-1.ts" => (
                        "500 Internal Server Error",
                        "text/plain",
                        b"low variant should not be requested".to_vec(),
                    ),
                    _ => ("404 Not Found", "text/plain", b"not found".to_vec()),
                };
                let header = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = stream.write_all(header.as_bytes()).await;
                let _ = stream.write_all(&body).await;
                let _ = stream.shutdown().await;
            }
        });

        let temp_dir = tempfile::tempdir().unwrap();
        let mut request = DownloadRequest::new(source, temp_dir.path());
        request.hls_variant_index = Some(1);
        let summary = DownloadEngine::new().download(request).await.unwrap();

        assert_eq!(summary.segments_written, Some(1));
        assert_eq!(
            fs::read(temp_dir.path().join("master.ts")).await.unwrap(),
            b"high variant only"
        );
        server_task.abort();
    }

    #[tokio::test]
    async fn downloads_hls_fmp4_without_ffmpeg() {
        let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let source = format!("http://{}/master.m3u8", server.local_addr().unwrap());
        let init = vec![
            0, 0, 0, 24, b'f', b't', b'y', b'p', b'i', b's', b'o', b'm', 0, 0, 0, 0, b'i', b's',
            b'o', b'm', b'i', b's', b'o', b'6',
        ];
        let first = vec![1, 2, 3, 4];
        let second = vec![5, 6, 7];
        let expected_len = (init.len() + first.len() + second.len()) as u64;
        let server_init = init.clone();
        let server_first = first.clone();
        let server_second = second.clone();
        let server_task = tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = server.accept().await else {
                    return;
                };
                let mut buffer = [0; 1024];
                let Ok(read) = stream.read(&mut buffer).await else {
                    continue;
                };
                let request = String::from_utf8_lossy(&buffer[..read]);
                let path = request
                    .lines()
                    .next()
                    .and_then(|line| line.split_whitespace().nth(1))
                    .unwrap_or("/");
                let (status, content_type, body): (&str, &str, Vec<u8>) = match path {
                    "/master.m3u8" => (
                        "200 OK",
                        "application/vnd.apple.mpegurl",
                        b"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=64000\nvariant.m3u8\n".to_vec(),
                    ),
                    "/variant.m3u8" => (
                        "200 OK",
                        "application/vnd.apple.mpegurl",
                        b"#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:1,\nfirst.m4s\n#EXTINF:1,\nsecond.m4s\n#EXT-X-ENDLIST\n".to_vec(),
                    ),
                    "/init.mp4" => ("200 OK", "video/mp4", server_init.clone()),
                    "/first.m4s" => ("200 OK", "video/iso.segment", server_first.clone()),
                    "/second.m4s" => ("200 OK", "video/iso.segment", server_second.clone()),
                    _ => ("404 Not Found", "text/plain", b"not found".to_vec()),
                };
                let header = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = stream.write_all(header.as_bytes()).await;
                let _ = stream.write_all(&body).await;
                let _ = stream.shutdown().await;
            }
        });

        let temp_dir = tempfile::tempdir().unwrap();
        let summary = DownloadEngine::new()
            .download(DownloadRequest::new(source, temp_dir.path()))
            .await
            .unwrap();

        assert_eq!(summary.display_name.as_deref(), Some("master.mp4"));
        assert_eq!(summary.segments_written, Some(2));
        assert_eq!(summary.bytes_written, expected_len);
        let mut expected = init;
        expected.extend(first);
        expected.extend(second);
        assert_eq!(
            fs::read(temp_dir.path().join("master.mp4")).await.unwrap(),
            expected
        );
        assert!(!temp_dir.path().join("master.ts").exists());
        server_task.abort();
    }

    #[tokio::test]
    async fn http_range_416_falls_back_to_single_connection_download() {
        let payload = Arc::new(
            (0..(128 * 1024))
                .map(|index| (index % 191) as u8)
                .collect::<Vec<_>>(),
        );
        let rejected = Arc::new(AtomicUsize::new(0));
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let source = format!("http://{}/payload.bin", listener.local_addr().unwrap());
        let server_payload = Arc::clone(&payload);
        let server_rejected = Arc::clone(&rejected);
        let server = tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = listener.accept().await else {
                    return;
                };
                let payload = Arc::clone(&server_payload);
                let rejected = Arc::clone(&server_rejected);
                tokio::spawn(async move {
                    let mut buffer = [0; 2048];
                    let Ok(read) = stream.read(&mut buffer).await else {
                        return;
                    };
                    let request = String::from_utf8_lossy(&buffer[..read]);
                    let method = request
                        .lines()
                        .next()
                        .and_then(|line| line.split_whitespace().next())
                        .unwrap_or("GET");
                    if method == "HEAD" {
                        let header = format!(
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                            payload.len()
                        );
                        let _ = stream.write_all(header.as_bytes()).await;
                        return;
                    }

                    if let Some((start, end)) = requested_range(&request) {
                        if rejected.fetch_add(1, AtomicOrdering::SeqCst) == 0 {
                            let _ = stream
                                .write_all(
                                    b"HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                                )
                                .await;
                            return;
                        }
                        let body = payload[start..=end].to_vec();
                        let header = format!(
                            "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{end}/{}\r\nConnection: close\r\n\r\n",
                            body.len(),
                            payload.len()
                        );
                        let _ = stream.write_all(header.as_bytes()).await;
                        let _ = stream.write_all(&body).await;
                        return;
                    }

                    let header = format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        payload.len()
                    );
                    let _ = stream.write_all(header.as_bytes()).await;
                    let _ = stream.write_all(&payload).await;
                });
            }
        });

        let temp_dir = tempfile::tempdir().unwrap();
        let summary = DownloadEngine::new()
            .download_with_options(
                DownloadRequest::new(source, temp_dir.path()),
                DownloadOptions::new(4, None),
            )
            .await
            .unwrap();
        assert_eq!(summary.bytes_written, payload.len() as u64);
        assert_eq!(
            fs::read(temp_dir.path().join("payload.bin")).await.unwrap(),
            payload.as_slice()
        );
        assert!(rejected.load(AtomicOrdering::SeqCst) >= 1);
        server.abort();
    }

    #[tokio::test]
    async fn http_resume_416_discards_stale_partial_and_restarts() {
        let payload = b"fresh remote payload".to_vec();
        let range_hits = Arc::new(AtomicUsize::new(0));
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let source = format!("http://{}/payload.bin", listener.local_addr().unwrap());
        let server_payload = payload.clone();
        let server_range_hits = Arc::clone(&range_hits);
        let server = tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = listener.accept().await else {
                    return;
                };
                let payload = server_payload.clone();
                let range_hits = Arc::clone(&server_range_hits);
                tokio::spawn(async move {
                    let mut buffer = [0; 2048];
                    let Ok(read) = stream.read(&mut buffer).await else {
                        return;
                    };
                    let request = String::from_utf8_lossy(&buffer[..read]);
                    let method = request
                        .lines()
                        .next()
                        .and_then(|line| line.split_whitespace().next())
                        .unwrap_or("GET");
                    if method == "HEAD" {
                        let header = format!(
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                            payload.len()
                        );
                        let _ = stream.write_all(header.as_bytes()).await;
                        return;
                    }

                    if request.lines().any(|line| {
                        line.split_once(':')
                            .is_some_and(|(name, _)| name.eq_ignore_ascii_case("range"))
                    }) {
                        range_hits.fetch_add(1, AtomicOrdering::SeqCst);
                        let header = format!(
                            "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                            payload.len()
                        );
                        let _ = stream.write_all(header.as_bytes()).await;
                        return;
                    }

                    let header = format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        payload.len()
                    );
                    let _ = stream.write_all(header.as_bytes()).await;
                    let _ = stream.write_all(&payload).await;
                });
            }
        });

        let temp_dir = tempfile::tempdir().unwrap();
        fs::write(
            temp_dir.path().join("payload.bin"),
            [payload.as_slice(), b"stale tail"].concat(),
        )
        .await
        .unwrap();
        let mut request = DownloadRequest::new(source, temp_dir.path());
        request.file_name = Some("payload.bin".to_string());
        let summary = DownloadEngine::new()
            .download_with_options(request, DownloadOptions::new(1, None))
            .await
            .unwrap();

        assert_eq!(summary.bytes_written, payload.len() as u64);
        assert_eq!(
            fs::read(temp_dir.path().join("payload.bin")).await.unwrap(),
            payload
        );
        assert_eq!(range_hits.load(AtomicOrdering::SeqCst), 1);
        server.abort();
    }

    #[tokio::test]
    async fn streams_large_hls_playlist_in_order_and_cleans_cache() {
        const SEGMENT_COUNT: usize = 48;
        const SEGMENT_SIZE: usize = 128 * 1024;
        let segments = Arc::new(
            (0..SEGMENT_COUNT)
                .map(|segment_index| {
                    (0..SEGMENT_SIZE)
                        .map(|byte_index| {
                            ((segment_index.wrapping_mul(31) + byte_index) % 251) as u8
                        })
                        .collect::<Vec<_>>()
                })
                .collect::<Vec<_>>(),
        );
        let playlist = format!(
            "#EXTM3U\n#EXT-X-VERSION:3\n{}#EXT-X-ENDLIST\n",
            (0..SEGMENT_COUNT)
                .map(|index| format!("#EXTINF:1,\nseg-{index}.ts\n"))
                .collect::<String>()
        );
        let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let source = format!("http://{}/playlist.m3u8", server.local_addr().unwrap());
        let server_segments = Arc::clone(&segments);
        let server_playlist = playlist.clone().into_bytes();
        let server_task = tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = server.accept().await else {
                    return;
                };
                let server_segments = Arc::clone(&server_segments);
                let server_playlist = server_playlist.clone();
                tokio::spawn(async move {
                    let mut buffer = [0; 2048];
                    let Ok(read) = stream.read(&mut buffer).await else {
                        return;
                    };
                    let request = String::from_utf8_lossy(&buffer[..read]);
                    let path = request
                        .lines()
                        .next()
                        .and_then(|line| line.split_whitespace().nth(1))
                        .unwrap_or("/");
                    let body = if path == "/playlist.m3u8" {
                        server_playlist
                    } else if let Some(index) = path
                        .strip_prefix("/seg-")
                        .and_then(|value| value.strip_suffix(".ts"))
                        .and_then(|value| value.parse::<usize>().ok())
                        .filter(|index| *index < server_segments.len())
                    {
                        server_segments[index].clone()
                    } else {
                        let header = b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                        let _ = stream.write_all(header).await;
                        let _ = stream.shutdown().await;
                        return;
                    };
                    let header = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    );
                    let _ = stream.write_all(header.as_bytes()).await;
                    let _ = stream.write_all(&body).await;
                    let _ = stream.shutdown().await;
                });
            }
        });

        let temp_dir = tempfile::tempdir().unwrap();
        let mut request = DownloadRequest::new(source, temp_dir.path());
        request.file_name = Some("large-playlist.m3u8".to_string());
        request.hls_keep_transport_stream = Some(true);
        let summary = DownloadEngine::new()
            .download_with_options(request, DownloadOptions::new(8, None))
            .await
            .unwrap();

        let mut expected = Vec::with_capacity(SEGMENT_COUNT * SEGMENT_SIZE);
        for segment in segments.iter() {
            expected.extend_from_slice(segment);
        }
        let output_path = temp_dir.path().join("large-playlist.ts");
        assert_eq!(summary.segments_written, Some(SEGMENT_COUNT));
        assert_eq!(summary.bytes_written, expected.len() as u64);
        assert_eq!(fs::read(&output_path).await.unwrap(), expected);
        // 作者: long
        // 成功合并后不保留临时分片目录，避免大媒体缓存长期占用设备空间。
        assert!(!hls_segment_cache_dir(&hls_mp4_output_name(&output_path)).exists());
        server_task.abort();
    }

    #[tokio::test]
    async fn hls_segment_cache_skips_network_for_cached_segments() {
        let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let source = format!("http://{}/playlist.m3u8", server.local_addr().unwrap());
        let playlist_text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:1,\nseg-1.ts\n#EXTINF:1,\nseg-2.ts\n#EXT-X-ENDLIST\n";
        let playlist_text_for_server = playlist_text.to_string();
        let server_task = tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = server.accept().await else {
                    return;
                };
                let mut buffer = [0; 1024];
                let Ok(read) = stream.read(&mut buffer).await else {
                    continue;
                };
                let request = String::from_utf8_lossy(&buffer[..read]);
                let path = request
                    .lines()
                    .next()
                    .and_then(|line| line.split_whitespace().nth(1))
                    .unwrap_or("/");
                let (status, content_type, body): (&str, &str, Vec<u8>) = match path {
                    "/playlist.m3u8" => (
                        "200 OK",
                        "application/vnd.apple.mpegurl",
                        playlist_text_for_server.as_bytes().to_vec(),
                    ),
                    // 作者: long
                    // 断点恢复断言：seg-1 已在缓存目录，服务器不再提供该分片；
                    // 只有 seg-2 走网络。
                    "/seg-1.ts" => ("404 Not Found", "text/plain", b"gone".to_vec()),
                    "/seg-2.ts" => ("200 OK", "video/mp2t", b"second segment".to_vec()),
                    _ => ("404 Not Found", "text/plain", b"not found".to_vec()),
                };
                let header = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = stream.write_all(header.as_bytes()).await;
                let _ = stream.write_all(&body).await;
                let _ = stream.shutdown().await;
            }
        });

        let temp_dir = tempfile::tempdir().unwrap();
        let output_path = temp_dir.path().join("playlist.ts");
        let cache_dir = hls_segment_cache_dir(&hls_mp4_output_name(&output_path));
        fs::create_dir_all(&cache_dir).await.unwrap();
        fs::write(hls_segment_cache_file(&cache_dir, 0), b"first segment")
            .await
            .unwrap();
        let playlist_url = Url::parse(&source).unwrap();
        let segment_specs = vec![
            HlsSegmentSpec {
                index: 0,
                url: playlist_url.join("seg-1.ts").unwrap(),
                media_sequence: 0,
                key: None,
                byte_range: None,
            },
            HlsSegmentSpec {
                index: 1,
                url: playlist_url.join("seg-2.ts").unwrap(),
                media_sequence: 1,
                key: None,
                byte_range: None,
            },
        ];
        let mut cache_manifest = hls_cache_manifest(&playlist_url, playlist_text, &segment_specs);
        cache_manifest.segments[0].cached_length = Some("first segment".len() as u64);
        cache_manifest.segments[0].cached_sha256 = Some(sha256_bytes(b"first segment"));
        write_hls_cache_manifest(&cache_dir, &cache_manifest)
            .await
            .unwrap();

        let summary = DownloadEngine::new()
            .download(DownloadRequest::new(source, temp_dir.path()))
            .await
            .unwrap();

        assert_eq!(summary.segments_written, Some(2));
        assert_eq!(
            fs::read(temp_dir.path().join("playlist.ts")).await.unwrap(),
            b"first segmentsecond segment"
        );
        // 成功完成后分片缓存必须被清理。
        assert!(!cache_dir.exists());
        server_task.abort();
    }

    #[test]
    fn hls_cache_manifest_rejects_playlist_source_changes() {
        let playlist_url = Url::parse("https://example.test/video/playlist.m3u8").unwrap();
        let segment_specs = vec![HlsSegmentSpec {
            index: 0,
            url: playlist_url.join("segment.ts").unwrap(),
            media_sequence: 7,
            key: None,
            byte_range: None,
        }];
        let original = hls_cache_manifest(&playlist_url, "playlist-v1", &segment_specs);
        let changed_playlist = hls_cache_manifest(&playlist_url, "playlist-v2", &segment_specs);
        let changed_url = hls_cache_manifest(
            &Url::parse("https://example.test/video/other.m3u8").unwrap(),
            "playlist-v1",
            &segment_specs,
        );

        assert!(hls_cache_manifest_matches_source(&original, &original));
        assert!(!hls_cache_manifest_matches_source(
            &original,
            &changed_playlist
        ));
        assert!(!hls_cache_manifest_matches_source(&original, &changed_url));
    }

    #[tokio::test]
    async fn hls_cache_validation_rejects_corrupted_segment_bytes() {
        let temp_dir = tempfile::tempdir().unwrap();
        let path = temp_dir.path().join("00000000.ts");
        fs::write(&path, b"corrupted").await.unwrap();
        let metadata = HlsCacheSegmentMetadata {
            index: 0,
            url_sha256: sha256_bytes("https://example.test/segment.ts"),
            media_sequence: 0,
            byte_range: None,
            cached_length: Some(11),
            cached_sha256: Some(sha256_bytes(b"expected bytes")),
        };

        assert_eq!(
            validate_hls_cached_segment(&path, Some(&metadata))
                .await
                .unwrap(),
            None
        );
    }
}
