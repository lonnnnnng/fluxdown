use crate::{Backend, DownloadRequest, Protocol, backend_availability};
use aes::cipher::{BlockDecryptMut, KeyIvInit, block_padding::Pkcs7};
use futures_util::StreamExt;
use librqbit::{AddTorrent, AddTorrentOptions, Session};
use m3u8_rs::{Key, KeyMethod};
use percent_encoding::percent_decode_str;
use reqwest::Client;
use reqwest::StatusCode;
use reqwest::header::{CONTENT_LENGTH, RANGE};
use serde::{Deserialize, Serialize};
use smb2::{ClientConfig, SmbClient};
use ssh2::Session as SshSession;
use std::collections::HashMap;
use std::io::{Read, Seek};
use std::net::{IpAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
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
use url::Url;

type Aes128CbcDec = cbc::Decryptor<aes::Aes128>;

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
    pub bytes_written: u64,
    pub resumed_from: u64,
    pub total_bytes: Option<u64>,
    pub segments_written: Option<usize>,
}

#[derive(Debug, Clone)]
pub struct DownloadEngine {
    client: Client,
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

    pub async fn download_with_progress(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
    ) -> Result<DownloadSummary, DownloadError> {
        self.download_with_control(request, progress, None).await
    }

    pub async fn download_with_control(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
        cancel: Option<CancelToken>,
    ) -> Result<DownloadSummary, DownloadError> {
        match request.protocol() {
            Protocol::Http | Protocol::Https => self.download_http(request, progress, cancel).await,
            Protocol::Webdav | Protocol::Webdavs => {
                self.download_webdav(request, progress, cancel).await
            }
            Protocol::Ftp | Protocol::Ftps => self.download_ftp(request, progress, cancel).await,
            Protocol::Torrent | Protocol::Magnet => {
                self.download_torrent(request, progress, cancel).await
            }
            Protocol::M3u8 => self.download_m3u8(request, progress, cancel).await,
            Protocol::Sftp => self.download_sftp(request, progress, cancel).await,
            Protocol::Ed2k => self.download_with_ed2k(request).await,
            Protocol::Smb => self.download_smb(request, progress, cancel).await,
            Protocol::Ipfs => self.download_ipfs_gateway(request, progress, cancel).await,
            protocol => Err(DownloadError::UnsupportedProtocol(protocol)),
        }
    }

    async fn download_http(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
        cancel: Option<CancelToken>,
    ) -> Result<DownloadSummary, DownloadError> {
        fs::create_dir_all(&request.output_dir).await?;
        let mut url = Url::parse(&request.source)
            .map_err(|_| DownloadError::InvalidUrl(request.source.clone()))?;
        let protocol = request.protocol();
        let file_name = request
            .file_name
            .unwrap_or_else(|| infer_file_name(&url, "download.bin"));
        let output_path = request.output_dir.join(file_name);
        let existing_bytes = existing_file_size(&output_path).await?;
        let credentials = url_credentials(&mut url)?;
        let mut builder = self.client.get(url);
        if let Some((username, password)) = credentials {
            builder = builder.basic_auth(username, password);
        }
        if existing_bytes > 0 {
            builder = builder.header(RANGE, format!("bytes={existing_bytes}-"));
        }

        let response = builder.send().await?.error_for_status()?;
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
            file.write_all(&chunk).await?;
            bytes_written += chunk.len() as u64;
            emit_progress(&progress, bytes_written, total_bytes);
        }

        file.flush().await?;

        Ok(DownloadSummary {
            protocol,
            backend: Backend::BuiltIn,
            output_path,
            bytes_written,
            resumed_from,
            total_bytes,
            segments_written: None,
        })
    }

    async fn download_webdav(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
        cancel: Option<CancelToken>,
    ) -> Result<DownloadSummary, DownloadError> {
        let protocol = request.protocol();
        let mut http_request = request;
        http_request.source = webdav_http_url(&http_request.source)?;
        let mut summary = self.download_http(http_request, progress, cancel).await?;
        summary.protocol = protocol;
        Ok(summary)
    }

    async fn download_ftp(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
        cancel: Option<CancelToken>,
    ) -> Result<DownloadSummary, DownloadError> {
        fs::create_dir_all(&request.output_dir).await?;
        let url = Url::parse(&request.source)
            .map_err(|_| DownloadError::InvalidUrl(request.source.clone()))?;
        let protocol = request.protocol();
        let spec = FtpDownloadSpec::from_url(&url, request.file_name.clone())?;
        if protocol == Protocol::Ftps {
            let ftp = connect_ftps(&spec).await?;
            return self
                .download_ftp_stream(ftp, request.output_dir, spec, protocol, progress, cancel)
                .await;
        }

        let ftp = AsyncFtpStream::connect(spec.address.clone()).await?;
        self.download_ftp_stream(ftp, request.output_dir, spec, protocol, progress, cancel)
            .await
    }

    async fn download_ftp_stream<T>(
        &self,
        mut ftp: ImplAsyncFtpStream<T>,
        output_dir: PathBuf,
        spec: FtpDownloadSpec,
        protocol: Protocol,
        progress: Option<ProgressCallback>,
        cancel: Option<CancelToken>,
    ) -> Result<DownloadSummary, DownloadError>
    where
        T: TokioTlsStream + Send,
    {
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
            output_path,
            bytes_written,
            resumed_from: existing_bytes,
            total_bytes,
            segments_written: None,
        })
    }

    async fn download_torrent(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
        cancel: Option<CancelToken>,
    ) -> Result<DownloadSummary, DownloadError> {
        fs::create_dir_all(&request.output_dir).await?;
        let protocol = request.protocol();
        let add_torrent = torrent_source(&request.source, protocol).await?;
        let session = Session::new(request.output_dir.clone()).await?;
        let handle = session
            .add_torrent(
                add_torrent,
                Some(AddTorrentOptions {
                    overwrite: true,
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
                }
            }
        }

        let final_stats = handle.stats();
        emit_progress(
            &progress,
            final_stats.progress_bytes,
            Some(final_stats.total_bytes),
        );
        session.stop().await;

        Ok(DownloadSummary {
            protocol,
            backend: Backend::BuiltIn,
            output_path: request.output_dir,
            bytes_written: final_stats.progress_bytes,
            resumed_from: 0,
            total_bytes: Some(final_stats.total_bytes),
            segments_written: None,
        })
    }

    async fn download_sftp(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
        cancel: Option<CancelToken>,
    ) -> Result<DownloadSummary, DownloadError> {
        fs::create_dir_all(&request.output_dir).await?;
        let url = Url::parse(&request.source)
            .map_err(|_| DownloadError::InvalidSftpUrl(request.source.clone()))?;
        let spec = SftpDownloadSpec::from_url(&url, request.file_name.clone())?;
        let output_dir = request.output_dir.clone();
        let cancel_for_task = cancel.clone();
        let progress_for_task = progress.clone();

        tokio::task::spawn_blocking(move || {
            download_sftp_blocking(output_dir, spec, progress_for_task, cancel_for_task)
        })
        .await
        .map_err(|error| anyhow::anyhow!("sftp task failed: {error}"))?
    }

    async fn download_m3u8(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
        cancel: Option<CancelToken>,
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
            .unwrap_or_else(|| infer_file_name(&playlist_url, "stream.ts"));
        let output_path = normalize_hls_output_name(&request.output_dir.join(file_name));
        let mut output = File::create(&output_path).await?;
        let mut bytes_written = 0;
        let mut segments_written = 0;
        let mut key_cache = HashMap::new();
        let mut current_hls_key = None;
        emit_progress(&progress, bytes_written, None);

        for (index, segment) in media_playlist.segments.iter().enumerate() {
            if is_cancelled(&cancel) {
                output.flush().await?;
                return Err(DownloadError::Paused);
            }
            let segment_url = media_playlist_url
                .join(&segment.uri)
                .map_err(|_| DownloadError::InvalidM3u8)?;
            let bytes = self
                .client
                .get(segment_url)
                .send()
                .await?
                .error_for_status()?
                .bytes()
                .await?;
            let segment_sequence = media_playlist.media_sequence + index as u64;
            if let Some(key) = &segment.key {
                current_hls_key = Some(key.clone());
            }
            let segment_bytes = self
                .decode_hls_segment(
                    &media_playlist_url,
                    current_hls_key.as_ref(),
                    bytes.as_ref(),
                    segment_sequence,
                    &mut key_cache,
                )
                .await?;
            output.write_all(&segment_bytes).await?;
            bytes_written += segment_bytes.len() as u64;
            segments_written += 1;
            emit_progress(&progress, bytes_written, None);
        }

        output.flush().await?;

        Ok(DownloadSummary {
            protocol: Protocol::M3u8,
            backend: Backend::BuiltIn,
            output_path,
            bytes_written,
            resumed_from: 0,
            total_bytes: Some(bytes_written),
            segments_written: Some(segments_written),
        })
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
            bytes_written: 0,
            resumed_from: 0,
            total_bytes: None,
            segments_written: None,
        })
    }

    async fn download_smb(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
        cancel: Option<CancelToken>,
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
        emit_progress(&progress, bytes_written, total_bytes);

        while let Some(chunk) = download.next_chunk().await {
            if is_cancelled(&cancel) {
                file.flush().await?;
                return Err(DownloadError::Paused);
            }

            let chunk = chunk?;
            file.write_all(&chunk).await?;
            bytes_written += chunk.len() as u64;
            emit_progress(&progress, bytes_written, total_bytes);
        }

        file.flush().await?;

        Ok(DownloadSummary {
            protocol: Protocol::Smb,
            backend: Backend::BuiltIn,
            output_path,
            bytes_written,
            resumed_from: 0,
            total_bytes,
            segments_written: None,
        })
    }

    async fn download_ipfs_gateway(
        &self,
        request: DownloadRequest,
        progress: Option<ProgressCallback>,
        cancel: Option<CancelToken>,
    ) -> Result<DownloadSummary, DownloadError> {
        let gateway_url = ipfs_gateway_url(&request.source)?;
        let mut http_request = request;
        http_request.source = gateway_url;
        let mut summary = self.download_http(http_request, progress, cancel).await?;
        summary.protocol = Protocol::Ipfs;
        Ok(summary)
    }
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

fn infer_total_bytes(
    content_length: Option<&reqwest::header::HeaderValue>,
    resumed_from: u64,
) -> Option<u64> {
    content_length
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok())
        .map(|length| length + resumed_from)
}

fn infer_file_name(url: &Url, fallback: &str) -> String {
    url.path_segments()
        .and_then(|mut segments| segments.next_back())
        .filter(|segment| !segment.is_empty())
        .unwrap_or(fallback)
        .to_string()
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
    let mut path = cid.to_string();
    if !url.path().is_empty() {
        path.push_str(url.path());
    }
    if let Some(query) = url.query() {
        path.push('?');
        path.push_str(query);
    }
    Ok(format!("https://ipfs.io/ipfs/{path}"))
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
    let root_store = tokio_rustls::rustls::RootCertStore::from_iter(
        webpki_roots::TLS_SERVER_ROOTS.iter().cloned(),
    );
    let config = tokio_rustls::rustls::ClientConfig::builder()
        .with_root_certificates(root_store)
        .with_no_client_auth();
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

fn download_sftp_blocking(
    output_dir: PathBuf,
    spec: SftpDownloadSpec,
    progress: Option<ProgressCallback>,
    cancel: Option<CancelToken>,
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

    loop {
        if is_cancelled(&cancel) {
            std::io::Write::flush(&mut local)?;
            return Err(DownloadError::Paused);
        }

        let read = remote.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        std::io::Write::write_all(&mut local, &buffer[..read])?;
        bytes_written += read as u64;
        emit_progress(&progress, bytes_written, total_bytes);
    }

    std::io::Write::flush(&mut local)?;
    Ok(DownloadSummary {
        protocol: Protocol::Sftp,
        backend: Backend::BuiltIn,
        output_path,
        bytes_written,
        resumed_from: existing_bytes,
        total_bytes,
        segments_written: None,
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

        let file_name = requested_file_name.unwrap_or_else(|| {
            path.rsplit('/')
                .next()
                .filter(|segment| !segment.is_empty())
                .map(percent_decode)
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
        let file_name = requested_file_name.unwrap_or_else(|| {
            path_segments
                .last()
                .filter(|segment| !segment.is_empty())
                .cloned()
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

        let file_name = requested_file_name.unwrap_or_else(|| {
            path.rsplit('/')
                .next()
                .filter(|segment| !segment.is_empty())
                .map(percent_decode)
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
        bytes_written: 0,
        resumed_from: 0,
        total_bytes: None,
        segments_written: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use aes::cipher::{BlockEncryptMut, block_padding::Pkcs7};
    use std::fs as std_fs;
    use std::sync::{Mutex, OnceLock};
    use tokio::net::TcpListener;

    type Aes128CbcEnc = cbc::Encryptor<aes::Aes128>;

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
        static PATH_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        let _guard = PATH_LOCK.get_or_init(|| Mutex::new(())).lock().unwrap();
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

fn normalize_hls_output_name(path: &Path) -> PathBuf {
    if path
        .extension()
        .is_some_and(|extension| extension == "m3u8")
    {
        path.with_extension("ts")
    } else {
        path.to_path_buf()
    }
}
