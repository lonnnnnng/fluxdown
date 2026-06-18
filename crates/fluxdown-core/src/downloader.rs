use crate::{
    Backend, DownloadRequest, Protocol, backend_availability, sanitize_download_file_name,
    validate_sha256_text,
};
use aes::cipher::{BlockDecryptMut, KeyIvInit, block_padding::Pkcs7};
use futures_util::{StreamExt, stream};
use librqbit::{AddTorrent, AddTorrentOptions, Session, SessionOptions, limits::LimitsConfig};
use m3u8_rs::{Key, KeyMethod};
use percent_encoding::percent_decode_str;
use reqwest::Client;
use reqwest::StatusCode;
use reqwest::header::{ACCEPT_RANGES, CONTENT_LENGTH, CONTENT_RANGE, RANGE};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use smb2::{ClientConfig, SmbClient};
use ssh2::Session as SshSession;
use std::collections::HashMap;
use std::io::{Read, Seek};
use std::net::{IpAddr, TcpStream};
use std::num::NonZeroU32;
use std::path::{Path, PathBuf};
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64, Ordering},
};
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
const TORRENT_STALL_TIMEOUT: Duration = Duration::from_secs(45);
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
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error("invalid m3u8 playlist")]
    InvalidM3u8,
    #[error("unsupported HLS key method: {0}")]
    UnsupportedHlsKeyMethod(String),
    #[error("invalid HLS key: {0}")]
    InvalidHlsKey(String),
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
    #[error("invalid sftp url: {0}")]
    InvalidSftpUrl(String),
    #[error("invalid smb url: {0}")]
    InvalidSmbUrl(String),
    #[error(transparent)]
    Ftp(#[from] suppaftp::FtpError),
    #[error(transparent)]
    Sftp(#[from] ssh2::Error),
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

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct DownloadOptions {
    pub thread_count: usize,
    pub speed_limit_bps: Option<u64>,
    #[serde(default)]
    pub restart_existing: bool,
}

impl Default for DownloadOptions {
    fn default() -> Self {
        Self {
            thread_count: 1,
            speed_limit_bps: None,
            restart_existing: false,
        }
    }
}

impl DownloadOptions {
    pub fn new(thread_count: usize, speed_limit_bps: Option<u64>) -> Self {
        Self {
            thread_count: thread_count.clamp(1, 32),
            speed_limit_bps: speed_limit_bps.filter(|limit| *limit > 0),
            restart_existing: false,
        }
    }

    pub fn with_restart_existing(mut self, restart_existing: bool) -> Self {
        self.restart_existing = restart_existing;
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
        let options = DownloadOptions::new(options.thread_count, options.speed_limit_bps)
            .with_restart_existing(options.restart_existing);
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
            Protocol::Ipfs => {
                self.download_ipfs_gateway(request, progress, cancel, options)
                    .await
            }
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
        let existing_bytes = existing_file_size(&output_path).await?;
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

        let mut builder = client.get(url);
        if let Some((username, password)) = credentials {
            builder = builder.basic_auth(username, password);
        }
        if existing_bytes > 0 {
            builder = builder.header(RANGE, format!("bytes={existing_bytes}-"));
        }

        let response = builder.send().await?;
        if existing_bytes > 0
            && response.status() == StatusCode::RANGE_NOT_SATISFIABLE
            && unsatisfied_range_total(response.headers().get(CONTENT_RANGE))
                == Some(existing_bytes)
        {
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
            limiter.wait(chunk.len() as u64).await;
            file.write_all(&chunk).await?;
            bytes_written += chunk.len() as u64;
            emit_progress(&progress, bytes_written, total_bytes);
        }

        file.flush().await?;

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
                    let response = request.send().await?.error_for_status()?;
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
                        limiter.wait(chunk.len() as u64).await;
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

        let mut stream = ftp.retr_as_stream(&spec.remote_path).await?;
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
            limiter.wait(read as u64).await;
            file.write_all(&buffer[..read]).await?;
            bytes_written += read as u64;
            emit_progress(&progress, bytes_written, total_bytes);
        }

        file.flush().await?;
        ftp.finalize_retr_stream(stream).await?;
        let _ = ftp.quit().await;

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
        let handle = session
            .add_torrent(
                add_torrent,
                Some(AddTorrentOptions {
                    overwrite: true,
                    ratelimits: torrent_rate_limits(options.speed_limit_bps),
                    ..Default::default()
                }),
            )
            .await?
            .into_handle()
            .ok_or_else(|| anyhow::anyhow!("torrent was added in list-only mode"))?;

        let initial_stats = handle.stats();
        emit_progress(
            &progress,
            initial_stats.progress_bytes,
            Some(initial_stats.total_bytes),
        );
        let mut last_progress_at = Instant::now();
        let mut last_progress_bytes = initial_stats.progress_bytes;

        let wait_handle = handle.clone();
        let mut wait_task = tokio::spawn(async move { wait_handle.wait_until_completed().await });
        let mut interval = tokio::time::interval(std::time::Duration::from_millis(500));

        loop {
            if is_cancelled(&cancel) {
                let _ = session.pause(&handle).await;
                session.stop().await;
                return Err(DownloadError::Paused);
            }

            tokio::select! {
                result = &mut wait_task => {
                    result.map_err(|error| anyhow::anyhow!("torrent task failed: {error}"))??;
                    break;
                }
                _ = interval.tick() => {
                    let stats = handle.stats();
                    emit_progress(&progress, stats.progress_bytes, Some(stats.total_bytes));
                    if stats.progress_bytes > last_progress_bytes {
                        last_progress_at = Instant::now();
                        last_progress_bytes = stats.progress_bytes;
                    } else if stats.total_bytes > 0
                        && stats.progress_bytes < stats.total_bytes
                        && last_progress_at.elapsed() >= TORRENT_STALL_TIMEOUT
                    {
                        session.stop().await;
                        return Err(DownloadError::TorrentStalled {
                            downloaded_bytes: stats.progress_bytes,
                            total_bytes: stats.total_bytes,
                            elapsed_secs: last_progress_at.elapsed().as_secs(),
                        });
                    }
                }
            }
        }

        let final_stats = handle.stats();
        emit_progress(
            &progress,
            final_stats.progress_bytes,
            Some(final_stats.total_bytes),
        );
        let (output_path, display_name) = handle.with_metadata(|metadata| {
            let file_paths = metadata
                .file_infos
                .iter()
                .filter(|file| !file.attrs.padding)
                .map(|file| file.relative_filename.clone())
                .collect::<Vec<_>>();
            torrent_output_details(&request.output_dir, metadata.name.as_deref(), &file_paths)
        })?;
        session.stop().await;

        Ok(DownloadSummary {
            protocol,
            backend: Backend::BuiltIn,
            output_path,
            display_name,
            bytes_written: final_stats.progress_bytes,
            resumed_from: 0,
            total_bytes: Some(final_stats.total_bytes),
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
        let spec = SftpDownloadSpec::from_url(&url, request.file_name.clone())?;
        let output_dir = request.output_dir.clone();
        let cancel_for_task = cancel.clone();
        let progress_for_task = progress.clone();
        let speed_limit_bps = options.speed_limit_bps;

        tokio::task::spawn_blocking(move || {
            download_sftp_blocking(
                output_dir,
                spec,
                progress_for_task,
                cancel_for_task,
                speed_limit_bps,
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

        let (media_playlist, media_playlist_url) = match playlist {
            m3u8_rs::Playlist::MediaPlaylist(media) => (media, playlist_url.clone()),
            m3u8_rs::Playlist::MasterPlaylist(master) => {
                let variant = master.variants.first().ok_or(DownloadError::InvalidM3u8)?;
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
                    m3u8_rs::Playlist::MediaPlaylist(media) => (media, variant_url),
                    _ => return Err(DownloadError::InvalidM3u8),
                }
            }
        };

        let file_name = request
            .file_name
            .map(|name| sanitize_download_file_name(&name, "stream.mp4"))
            .unwrap_or_else(|| infer_file_name(&playlist_url, "stream.mp4"));
        let requested_output_path = request.output_dir.join(file_name);
        let output_path = hls_mp4_output_name(&requested_output_path);
        let temp_ts_path = hls_temp_transport_path(&output_path);
        let fallback_ts_path = hls_transport_output_name(&requested_output_path);
        let mut output = File::create(&temp_ts_path).await?;
        let mut bytes_written = 0;
        let mut segments_written = 0;
        let mut current_hls_key = None;
        emit_progress(&progress, bytes_written, None);

        let mut segment_specs = Vec::with_capacity(media_playlist.segments.len());
        for (index, segment) in media_playlist.segments.iter().enumerate() {
            let segment_url = media_playlist_url
                .join(&segment.uri)
                .map_err(|_| DownloadError::InvalidM3u8)?;
            let segment_sequence = media_playlist.media_sequence + index as u64;
            if let Some(key) = &segment.key {
                current_hls_key = Some(key.clone());
            }
            segment_specs.push(HlsSegmentSpec {
                index,
                url: segment_url,
                media_sequence: segment_sequence,
                key: current_hls_key.clone(),
            });
        }

        let limiter = DownloadSpeedLimiter::new(options.speed_limit_bps);
        let downloaded = Arc::new(AtomicU64::new(0));
        let segment_results = stream::iter(segment_specs)
            .map(|segment| {
                let engine = self.clone();
                let playlist_url = media_playlist_url.clone();
                let cancel = cancel.clone();
                let progress = progress.clone();
                let downloaded = Arc::clone(&downloaded);
                let limiter = limiter.clone();
                async move {
                    if is_cancelled(&cancel) {
                        return Err(DownloadError::Paused);
                    }
                    let bytes = engine
                        .fetch_hls_segment_with_retry(
                            segment.url,
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
                    let total = downloaded.fetch_add(segment_bytes.len() as u64, Ordering::SeqCst)
                        + segment_bytes.len() as u64;
                    emit_progress(&progress, total, None);
                    Ok((segment.index, segment_bytes))
                }
            })
            .buffer_unordered(options.thread_count)
            .collect::<Vec<_>>()
            .await;

        let mut ordered_segments = Vec::with_capacity(segment_results.len());
        for result in segment_results {
            ordered_segments.push(result?);
        }
        ordered_segments.sort_by_key(|(index, _)| *index);

        for (_, segment_bytes) in ordered_segments {
            if is_cancelled(&cancel) {
                output.flush().await?;
                return Err(DownloadError::Paused);
            }
            output.write_all(&segment_bytes).await?;
            bytes_written += segment_bytes.len() as u64;
            segments_written += 1;
        }

        output.flush().await?;
        drop(output);

        let (output_path, output_bytes) =
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
                .fetch_hls_segment_bytes(url.clone(), limiter.clone(), cancel.clone())
                .await
            {
                Ok(bytes) => return Ok(bytes),
                Err(DownloadError::Paused) => return Err(DownloadError::Paused),
                Err(error) => {
                    last_error = Some(error);
                    if attempt + 1 < attempts {
                        // 作者: long
                        // HLS 分片常见于大量短连接，局域网或本机服务偶发 reset 时短重试能保住整条下载。
                        tokio::time::sleep(Duration::from_millis(150 * (attempt as u64 + 1))).await;
                    }
                }
            }
        }
        Err(last_error.expect("at least one HLS segment attempt has run"))
    }

    async fn fetch_hls_segment_bytes(
        &self,
        url: Url,
        limiter: DownloadSpeedLimiter,
        cancel: Option<CancelToken>,
    ) -> Result<Vec<u8>, DownloadError> {
        let response = self.client.get(url).send().await?.error_for_status()?;
        let mut stream = response.bytes_stream();
        let mut bytes = Vec::new();
        while let Some(chunk) = stream.next().await {
            if is_cancelled(&cancel) {
                return Err(DownloadError::Paused);
            }
            let chunk = chunk?;
            limiter.wait(chunk.len() as u64).await;
            bytes.extend_from_slice(&chunk);
        }
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
            limiter.wait(chunk.len() as u64).await;
            file.write_all(&chunk).await?;
            bytes_written += chunk.len() as u64;
            emit_progress(&progress, bytes_written, total_bytes);
        }

        file.flush().await?;

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

    async fn download_ipfs_gateway(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
        cancel: Option<CancelToken>,
        options: DownloadOptions,
    ) -> Result<DownloadSummary, DownloadError> {
        let gateway_url = ipfs_gateway_url(&request.source)?;
        let mut http_request = request;
        http_request.source = gateway_url;
        let mut summary = self
            .download_http(http_request, progress, cancel, options)
            .await?;
        summary.protocol = Protocol::Ipfs;
        Ok(summary)
    }
}

#[derive(Debug, Clone)]
struct HlsSegmentSpec {
    index: usize,
    url: Url,
    media_sequence: u64,
    key: Option<Key>,
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

    async fn wait(&self, bytes: u64) {
        let Some(inner) = &self.inner else {
            return;
        };
        if bytes == 0 {
            return;
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
        if !sleep_for.is_zero() {
            tokio::time::sleep(sleep_for).await;
        }
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

fn torrent_session_options(speed_limit_bps: Option<u64>) -> SessionOptions {
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
) -> (PathBuf, Option<String>) {
    if file_paths.len() == 1 {
        let output_path = output_dir.join(&file_paths[0]);
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
    Url::parse(source)
        .ok()
        .map(|url| infer_file_name(&url, "download.bin"))
        .unwrap_or_else(|| {
            source
                .split('?')
                .next()
                .unwrap_or(source)
                .rsplit('/')
                .next()
                .filter(|segment| !segment.is_empty())
                .unwrap_or("download.bin")
                .to_string()
        })
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

fn ipfs_gateway_url(source: &str) -> Result<String, DownloadError> {
    let url = Url::parse(source).map_err(|_| DownloadError::InvalidUrl(source.to_string()))?;
    if url.scheme() != "ipfs" {
        return Err(DownloadError::InvalidUrl(source.to_string()));
    }
    let cid = url
        .host_str()
        .filter(|host| !host.is_empty())
        .ok_or_else(|| DownloadError::InvalidUrl(source.to_string()))?;
    let source_query = url.query_pairs().collect::<Vec<_>>();
    let gateway_value = source_query
        .iter()
        .find_map(|(key, value)| {
            if key.eq_ignore_ascii_case("gateway") {
                Some(value.trim().to_string())
            } else {
                None
            }
        })
        .filter(|value| !value.is_empty());
    let mut gateway_url = match gateway_value {
        Some(value) => Url::parse(&value).map_err(|_| DownloadError::InvalidUrl(source.into()))?,
        None => Url::parse("https://ipfs.io").expect("default IPFS gateway URL is valid"),
    };
    if gateway_url.scheme() != "http" && gateway_url.scheme() != "https" {
        return Err(DownloadError::InvalidUrl(source.to_string()));
    }

    let mut path_segments = gateway_url
        .path_segments()
        .map(|segments| {
            segments
                .filter(|segment| !segment.is_empty())
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    path_segments.push("ipfs".to_string());
    path_segments.push(cid.to_string());
    if let Some(ipfs_segments) = url.path_segments() {
        path_segments.extend(
            ipfs_segments
                .filter(|segment| !segment.is_empty())
                .map(ToOwned::to_owned),
        );
    }

    {
        let mut output_segments = gateway_url
            .path_segments_mut()
            .map_err(|_| DownloadError::InvalidUrl(source.to_string()))?;
        output_segments.clear();
        for segment in &path_segments {
            output_segments.push(segment);
        }
    }

    let forwarded_query = source_query
        .into_iter()
        .filter(|(key, _)| !key.eq_ignore_ascii_case("gateway"))
        .collect::<Vec<_>>();
    if !forwarded_query.is_empty() {
        let mut output_query = gateway_url.query_pairs_mut();
        for (key, value) in forwarded_query {
            output_query.append_pair(&key, &value);
        }
    }

    Ok(gateway_url.to_string())
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
    // 本地实验室 HTTPS/WebDAVS/IPFS fixture 会使用临时自签证书；只有 URL 显式 opt-in 时才放宽校验，避免影响普通公网下载的 TLS 安全边界。
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
) -> Result<DownloadSummary, DownloadError> {
    std::fs::create_dir_all(&output_dir)?;
    let output_path = output_dir.join(&spec.file_name);
    let existing_bytes = std::fs::metadata(&output_path)
        .ok()
        .filter(|metadata| metadata.is_file())
        .map(|metadata| metadata.len())
        .unwrap_or(0);

    let tcp = TcpStream::connect(&spec.address)?;
    let mut session = SshSession::new()?;
    session.set_tcp_stream(tcp);
    session.handshake()?;
    session.userauth_password(&spec.username, &spec.password)?;
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
    Ok(DownloadSummary {
        protocol: Protocol::Sftp,
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

#[derive(Debug, Clone)]
struct SftpDownloadSpec {
    address: String,
    username: String,
    password: String,
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
        let password = url.password().ok_or_else(|| {
            DownloadError::InvalidSftpUrl("sftp url must include a password".to_string())
        })?;

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
            username: percent_decode(url.username()),
            password: percent_decode(password),
            remote_path: percent_decode(path),
            file_name,
        })
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
    fn torrent_output_details_use_single_file_name() {
        let temp_dir = tempfile::tempdir().unwrap();
        let files = vec![PathBuf::from("20260614.mp4")];

        let (output_path, display_name) =
            torrent_output_details(temp_dir.path(), Some("download.torrent"), &files);

        assert_eq!(output_path, temp_dir.path().join("20260614.mp4"));
        assert_eq!(display_name.as_deref(), Some("20260614.mp4"));
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
            torrent_output_details(temp_dir.path(), Some("metadata-name"), &files);

        assert_eq!(output_path, root);
        assert_eq!(display_name.as_deref(), Some("20260614_bundle"));
    }

    #[test]
    fn torrent_output_details_fall_back_to_metadata_name_without_common_root() {
        let temp_dir = tempfile::tempdir().unwrap();
        let files = vec![PathBuf::from("video.mp4"), PathBuf::from("readme.txt")];

        let (output_path, display_name) =
            torrent_output_details(temp_dir.path(), Some("loose-files"), &files);

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
            torrent_output_details(temp_dir.path(), Some("loose-files"), &files);

        assert_eq!(output_path, metadata_dir);
        assert_eq!(display_name.as_deref(), Some("loose-files"));
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
            expected_sha256: None,
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
        assert_eq!(spec.password, "p@ss");
        assert_eq!(spec.remote_path, "pub/releases/file one.bin");
        assert_eq!(spec.file_name, "file one.bin");
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
    fn maps_ipfs_urls_to_https_gateway_urls() {
        assert_eq!(
            ipfs_gateway_url("ipfs://bafybeigdyrzt/readme.txt").unwrap(),
            "https://ipfs.io/ipfs/bafybeigdyrzt/readme.txt",
        );
    }

    #[test]
    fn maps_ipfs_urls_to_custom_gateway() {
        assert_eq!(
            ipfs_gateway_url(
                "ipfs://bafybeigdyrzt/readme.txt?gateway=http%3A%2F%2F127.0.0.1%3A8765%2Flab&download=1"
            )
            .unwrap(),
            "http://127.0.0.1:8765/lab/ipfs/bafybeigdyrzt/readme.txt?download=1",
        );
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

    #[tokio::test]
    async fn speed_limiter_paces_initial_chunk() {
        let limiter = DownloadSpeedLimiter::new(Some(256 * 1024));
        let started = Instant::now();

        limiter.wait(64 * 1024).await;

        assert!(started.elapsed() >= Duration::from_millis(220));
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
}
