//! Torrent 详情：文件列表、tracker、peer 聚合计数与实时速率。
//!
//! 运行中的下载会把会话句柄注册到进程内注册表，详情查询优先走运行时快照；
//! 任务不在运行时回退到静态解析（.torrent 本地文件或 URL 下载）；magnet
//! 链接会在未运行时使用零文件选择的临时 session 尝试获取 metadata，失败时保留
//! info-hash/name 提示，不创建实际下载任务。

use std::{
    collections::HashMap,
    sync::{Arc, Mutex, OnceLock},
    time::Duration,
};

use librqbit::{AddTorrent, AddTorrentOptions, ManagedTorrent, Session};
use serde::Serialize;
use url::Url;

use crate::downloader::DownloadError;

/// 运行中种子的会话句柄。
type TorrentHandle = Arc<ManagedTorrent>;

fn torrent_file_name(path: &str) -> String {
    path.replace('\\', "/")
        .rsplit('/')
        .find(|part| !part.trim().is_empty())
        .unwrap_or(path)
        .to_string()
}

fn is_streamable_path(path: &str) -> bool {
    matches!(
        path.rsplit('.')
            .next()
            .map(str::to_ascii_lowercase)
            .as_deref(),
        Some(
            "mp4" | "mkv" | "avi" | "mov" | "m4v" | "webm" | "ts" | "mp3" | "m4a" | "aac" | "flac"
        )
    )
}

#[derive(Debug, Clone, Serialize)]
pub struct TorrentDetailsFile {
    pub index: usize,
    pub path: String,
    pub name: String,
    pub size: u64,
    pub is_streamable: bool,
    pub progress_bytes: Option<u64>,
}

#[derive(Debug, Clone, Copy, Serialize)]
pub struct TorrentPeerSummary {
    pub live: usize,
    pub connecting: usize,
    pub queued: usize,
    pub seen: usize,
    pub dead: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct TorrentDetails {
    /// true 表示详情来自正在运行的下载会话（含实时速率与 peer 计数）。
    pub runtime: bool,
    pub name: Option<String>,
    pub info_hash: Option<String>,
    pub files: Vec<TorrentDetailsFile>,
    pub trackers: Vec<String>,
    pub total_bytes: Option<u64>,
    pub progress_bytes: Option<u64>,
    pub uploaded_bytes: Option<u64>,
    /// 下载速率（字节/秒）。
    pub download_speed_bps: Option<f64>,
    /// 上传速率（字节/秒）。
    pub upload_speed_bps: Option<f64>,
    /// 预计剩余秒数（按 (total-progress)/download_speed 估算）。
    pub eta_seconds: Option<u64>,
    pub peers: Option<TorrentPeerSummary>,
    pub error: Option<String>,
}

fn runtime_handles() -> &'static Mutex<HashMap<String, TorrentHandle>> {
    static RUNTIME: OnceLock<Mutex<HashMap<String, TorrentHandle>>> = OnceLock::new();
    RUNTIME.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(crate) fn register_runtime_handle(task_id: &str, handle: TorrentHandle) {
    if let Ok(mut guard) = runtime_handles().lock() {
        guard.insert(task_id.to_string(), handle);
    }
}

pub(crate) fn unregister_runtime_handle(task_id: &str) {
    if let Ok(mut guard) = runtime_handles().lock() {
        guard.remove(task_id);
    }
}

fn runtime_details(task_id: &str) -> Option<TorrentDetails> {
    let handle = {
        let guard = runtime_handles().lock().ok()?;
        guard.get(task_id)?.clone()
    };
    let stats = handle.stats();
    let mut trackers = handle
        .shared()
        .trackers
        .iter()
        .map(|url| url.to_string())
        .collect::<Vec<_>>();
    trackers.sort();

    let name = handle.name();
    let (files, metadata_total) = handle
        .with_metadata(|metadata| {
            let files = metadata
                .file_infos
                .iter()
                .enumerate()
                .filter(|(_, file)| !file.attrs.padding)
                .map(|(index, file)| {
                    let path = file.relative_filename.to_string_lossy().into_owned();
                    TorrentDetailsFile {
                        index,
                        name: torrent_file_name(&path),
                        is_streamable: is_streamable_path(&path),
                        path,
                        size: file.len,
                        progress_bytes: stats.file_progress.get(index).copied(),
                    }
                })
                .collect::<Vec<_>>();
            let total = files.iter().map(|file| file.size).sum::<u64>();
            (files, total)
        })
        .ok()
        .unwrap_or_else(|| (Vec::new(), 0));

    let peers = stats.live.as_ref().map(|live| TorrentPeerSummary {
        live: live.snapshot.peer_stats.live,
        connecting: live.snapshot.peer_stats.connecting,
        queued: live.snapshot.peer_stats.queued,
        seen: live.snapshot.peer_stats.seen,
        dead: live.snapshot.peer_stats.dead,
    });

    let download_speed_bps = stats
        .live
        .as_ref()
        .map(|live| live.download_speed.mbps * 1024.0 * 1024.0);
    let eta_seconds = match (metadata_total, stats.progress_bytes, download_speed_bps) {
        (total, progress, Some(speed)) if total > progress && speed > 0.0 && total > 0 => {
            Some(((total - progress) as f64 / speed).ceil() as u64)
        }
        _ => None,
    };

    Some(TorrentDetails {
        runtime: true,
        name,
        info_hash: Some(handle.info_hash().as_string()),
        files,
        trackers,
        total_bytes: Some(if metadata_total > 0 {
            metadata_total
        } else {
            stats.total_bytes
        }),
        progress_bytes: Some(stats.progress_bytes),
        uploaded_bytes: Some(stats.uploaded_bytes),
        download_speed_bps,
        upload_speed_bps: stats
            .live
            .as_ref()
            .map(|live| live.upload_speed.mbps * 1024.0 * 1024.0),
        eta_seconds,
        peers,
        error: stats.error.clone(),
    })
}

/// 静态解析 .torrent 的名称、文件列表和 tracker（本地文件或 URL 下载的字节）。
fn static_details_from_torrent_bytes(bytes: &[u8]) -> Result<TorrentDetails, DownloadError> {
    use librqbit_bencode::BencodeValue;

    let value = librqbit_bencode::dyn_from_bytes::<Vec<u8>>(bytes).map_err(|error| {
        DownloadError::TorrentSourceUnreadable(format!("种子文件不是有效的 bencode: {error}"))
    })?;
    let BencodeValue::Dict(top) = &value else {
        return Err(DownloadError::TorrentSourceUnreadable(
            "种子顶层必须是字典".into(),
        ));
    };

    fn bytes_to_string(value: &[u8]) -> String {
        String::from_utf8_lossy(value).into_owned()
    }

    // name 位于 info 字典内（顶层 name 不属于标准，但个别种子会带，作回退）。
    let info = top.get(b"info".as_slice());
    let name = info
        .and_then(|value| match value {
            BencodeValue::Dict(info) => info.get(b"name".as_slice()),
            _ => None,
        })
        .or_else(|| top.get(b"name".as_slice()))
        .and_then(|value| match value {
            BencodeValue::Bytes(bytes) => Some(bytes_to_string(bytes)),
            _ => None,
        });

    let mut trackers = Vec::new();
    if let Some(BencodeValue::Bytes(announce)) = top.get(b"announce".as_slice()) {
        trackers.push(bytes_to_string(announce));
    }
    if let Some(BencodeValue::List(list)) = top.get(b"announce-list".as_slice()) {
        for tier in list {
            if let BencodeValue::List(urls) = tier {
                for url in urls {
                    if let BencodeValue::Bytes(bytes) = url {
                        let tracker = bytes_to_string(bytes);
                        if !tracker.is_empty() && !trackers.contains(&tracker) {
                            trackers.push(tracker);
                        }
                    }
                }
            }
        }
    }

    let mut files = Vec::new();
    let mut total_bytes = 0_u64;
    if let Some(BencodeValue::Dict(info)) = top.get(b"info".as_slice()) {
        match info.get(b"files".as_slice()) {
            // 多文件种子
            Some(BencodeValue::List(entries)) => {
                for (index, entry) in entries.iter().enumerate() {
                    if let BencodeValue::Dict(entry) = entry {
                        let size = match entry.get(b"length".as_slice()) {
                            Some(BencodeValue::Integer(length)) => (*length).max(0) as u64,
                            _ => 0,
                        };
                        let path = match entry.get(b"path".as_slice()) {
                            Some(BencodeValue::List(parts)) => parts
                                .iter()
                                .filter_map(|part| match part {
                                    BencodeValue::Bytes(bytes) => Some(bytes_to_string(bytes)),
                                    _ => None,
                                })
                                .collect::<Vec<_>>()
                                .join("/"),
                            _ => String::new(),
                        };
                        total_bytes += size;
                        files.push(TorrentDetailsFile {
                            index,
                            name: torrent_file_name(&path),
                            is_streamable: is_streamable_path(&path),
                            path,
                            size,
                            progress_bytes: None,
                        });
                    }
                }
            }
            // 单文件种子
            _ => {
                if let Some(BencodeValue::Integer(length)) = info.get(b"length".as_slice()) {
                    total_bytes = (*length).max(0) as u64;
                    files.push(TorrentDetailsFile {
                        index: 0,
                        name: name.as_deref().map(torrent_file_name).unwrap_or_default(),
                        is_streamable: name.as_deref().map(is_streamable_path).unwrap_or(false),
                        path: name.clone().unwrap_or_default(),
                        size: total_bytes,
                        progress_bytes: None,
                    });
                }
            }
        }
    }

    Ok(TorrentDetails {
        runtime: false,
        name,
        info_hash: None,
        files,
        trackers,
        total_bytes: if total_bytes > 0 {
            Some(total_bytes)
        } else {
            None
        },
        progress_bytes: None,
        uploaded_bytes: None,
        download_speed_bps: None,
        upload_speed_bps: None,
        eta_seconds: None,
        peers: None,
        error: None,
    })
}

fn static_details_from_magnet(source: &str) -> TorrentDetails {
    let name = Url::parse(source).ok().and_then(|url| {
        url.query_pairs()
            .find(|(key, _)| key == "dn")
            .map(|(_, value)| value.into_owned())
    });
    TorrentDetails {
        runtime: false,
        name,
        info_hash: source
            .split("urn:btih:")
            .nth(1)
            .and_then(|rest| rest.split('&').next().map(|hash| hash.to_lowercase())),
        files: Vec::new(),
        trackers: Vec::new(),
        total_bytes: None,
        progress_bytes: None,
        uploaded_bytes: None,
        download_speed_bps: None,
        upload_speed_bps: None,
        eta_seconds: None,
        peers: None,
        error: Some("magnet 元数据需要联网解析，任务运行后可查看文件列表与实时状态".into()),
    }
}

/// 只解析 magnet 的 metadata，不创建可下载任务。
///
/// 作者: long
/// 新建任务需要先看到真实文件树再选择内容；librqbit 的 list_only 会用 port=0
/// 请求 tracker，部分 tracker 会拒绝。零文件选择保留正常 peer 发现但不下载内容，
/// 获取 metadata 后停止会话，临时目录仅容纳引擎创建的空占位文件并自动释放。
async fn metadata_details_from_magnet(source: &str) -> Result<TorrentDetails, DownloadError> {
    let metadata_dir = tempfile::tempdir()?;
    let session = Session::new_with_opts(
        metadata_dir.path().to_path_buf(),
        crate::downloader::torrent_session_options(None),
    )
    .await
    .map_err(|error| {
        DownloadError::TorrentSourceUnreadable(format!("初始化 magnet 解析失败: {error}"))
    })?;

    let response = tokio::time::timeout(
        Duration::from_secs(30),
        session.add_torrent(
            AddTorrent::from_url(source.to_string()),
            Some(AddTorrentOptions {
                only_files: Some(Vec::new()),
                ..Default::default()
            }),
        ),
    )
    .await;
    // 作者: long
    // metadata 预览不应把临时 session 留在后台；无论获取成功、失败还是文件列表解析失败，
    // 都先停止 session，再把原始错误交给上层回退为可保存任务。
    let _ = session.stop().await;
    let response = response
        .map_err(|_| {
            DownloadError::TorrentSourceUnreadable(
                "Magnet 元数据解析超时，请检查 tracker 或网络后重试".into(),
            )
        })?
        .map_err(|error| {
            DownloadError::TorrentSourceUnreadable(format!("解析 magnet 元数据失败: {error}"))
        })?;

    let handle = response.into_handle().ok_or_else(|| {
        DownloadError::TorrentSourceUnreadable("Magnet metadata 会话未返回文件列表".into())
    })?;
    let mut details = handle
        .with_metadata(|metadata| static_details_from_torrent_bytes(&metadata.torrent_bytes))??;
    details.info_hash = Some(handle.info_hash().as_string());
    Ok(details)
}

pub async fn torrent_details(
    source: &str,
    task_id: Option<&str>,
) -> Result<TorrentDetails, DownloadError> {
    if let Some(task_id) = task_id
        && let Some(details) = runtime_details(task_id)
    {
        return Ok(details);
    }

    let trimmed = source.trim();
    if trimmed.starts_with("magnet:") {
        // 已有运行任务优先走 runtime_details；未运行时尝试获取 metadata，
        // 网络或 tracker 不可用则保留 hash/name 提示，用户仍可先保存任务。
        return match metadata_details_from_magnet(trimmed).await {
            Ok(details) => Ok(details),
            Err(error) => {
                let mut details = static_details_from_magnet(trimmed);
                details.error = Some(error.to_string());
                Ok(details)
            }
        };
    }
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        let bytes = crate::downloader::read_torrent_bytes_from_url(trimmed).await?;
        return static_details_from_torrent_bytes(&bytes);
    }
    let local_path = trimmed.strip_prefix("file://").unwrap_or(trimmed);
    let bytes = tokio::fs::read(local_path).await.map_err(|error| {
        DownloadError::TorrentSourceUnreadable(format!("读取种子文件失败: {error}"))
    })?;
    static_details_from_torrent_bytes(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    // 手工 bencode 编码的最小多文件种子：
    // announce=http://tracker.example/announce，info 内两个文件（3B + 2B）。
    const SAMPLE_TORRENT: &[u8] = b"d8:announce31:http://tracker.example/announce\
4:infod5:filesl\
d6:lengthi3e4:pathl4:a.tsee\
d6:lengthi2e4:pathl4:b.tsee\
e4:name4:demoe\
e";

    #[test]
    fn parses_static_torrent_files_and_trackers() {
        let details = static_details_from_torrent_bytes(SAMPLE_TORRENT).unwrap();

        assert!(!details.runtime);
        assert_eq!(details.name.as_deref(), Some("demo"));
        assert_eq!(
            details.trackers,
            vec!["http://tracker.example/announce".to_string()]
        );
        assert_eq!(details.files.len(), 2);
        assert_eq!(details.files[0].path, "a.ts");
        assert_eq!(details.files[0].size, 3);
        assert_eq!(details.files[1].path, "b.ts");
        assert_eq!(details.files[1].size, 2);
        assert_eq!(details.total_bytes, Some(5));
    }

    #[test]
    fn magnet_details_carry_infohash_hint() {
        let details = static_details_from_magnet(
            "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=demo",
        );

        assert!(!details.runtime);
        assert_eq!(
            details.info_hash.as_deref(),
            Some("0123456789abcdef0123456789abcdef01234567")
        );
        assert!(details.files.is_empty());
        assert!(details.error.is_some());
    }
}
