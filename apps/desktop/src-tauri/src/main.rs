// 作者: long
// Windows 发行版按 GUI 程序启动，避免创建控制台及关闭控制台时连带终止下载；调试版保留控制台日志。
#![cfg_attr(
    all(target_os = "windows", not(debug_assertions)),
    windows_subsystem = "windows"
)]

use fluxdown_core::{
    DoctorReport, DownloadOptions, DownloadRequest, DownloadState, DownloadTask, Protocol,
    QueueRunReport, QueueRunner, QueueRunnerOptions, RuntimeSupportStatus, TaskRunReport,
    TaskStore, default_store_path, detect_protocol, doctor_report, hls_variants,
    runtime_support_status, sanitize_download_file_name, torrent_details, validate_sha256_text,
};
use serde::Deserialize;
#[cfg(any(target_os = "macos", test))]
use std::process::Command;
use std::{
    env,
    path::{Path, PathBuf},
    time::Duration,
};
// 作者: long
// Manager 在所有平台都要用（单实例回调、托盘菜单都通过它找主窗口）；
// WebviewWindowBuilder/URL 只有 Windows E2E 钩子使用，保持平台门控。
use tauri::Manager;
#[cfg(target_os = "windows")]
use tauri::{WebviewUrl, WebviewWindowBuilder};

const STALE_RUNNING_TASK_TIMEOUT: Duration = Duration::from_secs(5 * 60);
const MIN_CONCURRENCY: usize = 1;
const MAX_CONCURRENCY: usize = 30;
const DEFAULT_RETRY_ATTEMPTS: usize = 1;

#[derive(Debug, Default, Deserialize)]
struct AddPayload {
    source: String,
    output_dir: String,
    file_name: Option<String>,
    #[serde(default)]
    expected_sha256: Option<String>,
    #[serde(default)]
    torrent_file_indices: Vec<usize>,
    #[serde(default)]
    speed_limit_mbps: Option<f64>,
    #[serde(default)]
    hls_variant_index: Option<usize>,
    #[serde(default)]
    hls_keep_transport_stream: Option<bool>,
}

#[tauri::command]
fn detect(source: String) -> Protocol {
    detect_protocol(&source)
}

#[tauri::command]
async fn support(source: String) -> RuntimeSupportStatus {
    runtime_support_status(detect_protocol(&source)).await
}

#[tauri::command]
async fn doctor() -> DoctorReport {
    doctor_report().await
}

#[tauri::command]
fn default_output_dir() -> String {
    default_output_dir_path().to_string_lossy().into_owned()
}

#[tauri::command]
fn plan_download(source: String, output_dir: String) -> DownloadTask {
    DownloadTask::from_request(DownloadRequest::new(
        source,
        resolve_output_dir(&output_dir),
    ))
}

#[tauri::command]
async fn enqueue_download(payload: AddPayload) -> Result<DownloadTask, String> {
    let mut request = DownloadRequest::new(payload.source, resolve_output_dir(&payload.output_dir));
    request.file_name = payload.file_name;
    request.expected_sha256 = validated_expected_sha256(payload.expected_sha256)?;
    request.torrent_file_indices = payload.torrent_file_indices;
    request.speed_limit_mbps = payload.speed_limit_mbps.filter(|limit| limit.is_finite() && *limit > 0.0);
    request.hls_variant_index = payload.hls_variant_index;
    request.hls_keep_transport_stream = payload.hls_keep_transport_stream;
    TaskStore::new(default_store_path())
        .enqueue(request)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn list_hls_variants(source: String) -> Result<Vec<fluxdown_core::HlsVariantInfo>, String> {
    hls_variants(&source)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn torrent_task_details(task_id: Option<String>, source: String) -> Result<serde_json::Value, String> {
    let details = torrent_details(&source, task_id.as_deref())
        .await
        .map_err(|error| error.to_string())?;
    serde_json::to_value(details).map_err(|error| error.to_string())
}

#[tauri::command]
async fn list_downloads() -> Result<Vec<DownloadTask>, String> {
    let store = TaskStore::new(default_store_path());
    migrate_download_paths(&store)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn pause_download(id: String) -> Result<DownloadTask, String> {
    let store = TaskStore::new(default_store_path());
    // 作者: long
    // 桌面端可能在 App 重启后直接点暂停；先回收异常 running，才能给用户准确的中断状态。
    store
        .recover_stale_running(STALE_RUNNING_TASK_TIMEOUT)
        .await
        .map_err(|error| error.to_string())?;
    let task = store.get(&id).await.map_err(|error| error.to_string())?;
    if let Some(state) = pause_transition(task.state)? {
        store
            .set_state(&id, state)
            .await
            .map_err(|error| error.to_string())
    } else {
        Ok(task)
    }
}

#[tauri::command]
async fn resume_download(id: String) -> Result<DownloadTask, String> {
    let store = TaskStore::new(default_store_path());
    // 作者: long
    // 用户看到旧任务后可能直接点继续；先释放陈旧 running 槽位，避免误报“任务仍在下载中”。
    store
        .recover_stale_running(STALE_RUNNING_TASK_TIMEOUT)
        .await
        .map_err(|error| error.to_string())?;
    let task = store.get(&id).await.map_err(|error| error.to_string())?;
    if let Some(state) = resume_transition(task.state)? {
        store
            .set_state(&id, state)
            .await
            .map_err(|error| error.to_string())
    } else {
        Ok(task)
    }
}

fn pause_transition(state: DownloadState) -> Result<Option<DownloadState>, String> {
    // 作者: long
    // 桌面端点击暂停只应影响未结束任务，避免过期 UI 或直接命令把完成任务改坏。
    match state {
        DownloadState::Queued | DownloadState::Running => Ok(Some(DownloadState::Paused)),
        DownloadState::Paused => Ok(None),
        DownloadState::Finished | DownloadState::Failed => {
            Err("only queued or running tasks can be paused".to_string())
        }
    }
}

fn resume_transition(state: DownloadState) -> Result<Option<DownloadState>, String> {
    // 作者: long
    // 恢复只把暂停任务放回队列；已结束任务需要显式重新下载，不能悄悄排队。
    match state {
        DownloadState::Paused => Ok(Some(DownloadState::Queued)),
        DownloadState::Queued => Ok(None),
        DownloadState::Running => Err("running tasks do not need resume".to_string()),
        DownloadState::Finished | DownloadState::Failed => Err(
            "finished or failed tasks cannot be resumed; start them again explicitly".to_string(),
        ),
    }
}

#[tauri::command]
async fn remove_download(id: String) -> Result<DownloadTask, String> {
    let store = TaskStore::new(default_store_path());
    // 作者: long
    // 桌面删除旧 running 任务时也先恢复中断状态，属性面板和操作结果不会继续展示假下载中。
    store
        .recover_stale_running(STALE_RUNNING_TASK_TIMEOUT)
        .await
        .map_err(|error| error.to_string())?;
    store.remove(&id).await.map_err(|error| error.to_string())
}

#[tauri::command]
async fn task_output_path(id: String) -> Result<String, String> {
    let task = load_task(&id).await?;
    Ok(resolve_task_output_path(&task)
        .to_string_lossy()
        .into_owned())
}

#[tauri::command]
async fn open_task_output(id: String) -> Result<(), String> {
    let task = load_task(&id).await?;
    let path = existing_task_output_path(&task);
    open::that(path).map_err(|error| error.to_string())
}

#[tauri::command]
async fn reveal_task_output(id: String) -> Result<(), String> {
    let task = load_task(&id).await?;
    let path = existing_task_output_path(&task);
    reveal_path(&path)
}

#[tauri::command]
async fn start_download(
    id: String,
    concurrency: Option<usize>,
    retry_attempts: Option<usize>,
    thread_count: Option<usize>,
    speed_limit_mbps: Option<f64>,
    restart_existing: Option<bool>,
) -> Result<TaskRunReport, String> {
    let store = TaskStore::new(default_store_path());
    migrate_download_paths(&store)
        .await
        .map_err(|error| error.to_string())?;
    let task = store.get(&id).await.map_err(|error| error.to_string())?;
    let options = runner_options(
        retry_attempts,
        thread_count,
        speed_limit_mbps,
        restart_existing,
    );
    if let Some(task) =
        defer_direct_start_when_capacity_full(&store, task, concurrency, options.restart_existing)
            .await
            .map_err(|error| error.to_string())?
    {
        return Ok(TaskRunReport {
            task,
            summary: None,
        });
    }

    QueueRunner::new(store)
        .run_task_with_options(&id, options)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn run_queue(
    concurrency: usize,
    retry_attempts: Option<usize>,
    thread_count: Option<usize>,
    speed_limit_mbps: Option<f64>,
    restart_existing: Option<bool>,
) -> Result<QueueRunReport, String> {
    let store = TaskStore::new(default_store_path());
    migrate_download_paths(&store)
        .await
        .map_err(|error| error.to_string())?;
    QueueRunner::new(store)
        .run_queued_with_options(
            clamp_concurrency(concurrency),
            runner_options(
                retry_attempts,
                thread_count,
                speed_limit_mbps,
                restart_existing,
            ),
        )
        .await
        .map_err(|error| error.to_string())
}

fn runner_options(
    retry_attempts: Option<usize>,
    thread_count: Option<usize>,
    speed_limit_mbps: Option<f64>,
    restart_existing: Option<bool>,
) -> QueueRunnerOptions {
    QueueRunnerOptions {
        retry_attempts: retry_attempts.unwrap_or(DEFAULT_RETRY_ATTEMPTS).min(10),
        download: DownloadOptions::new(
            thread_count.unwrap_or(1).clamp(1, 32),
            speed_limit_mbps_to_bps(speed_limit_mbps),
        ),
        restart_existing: restart_existing.unwrap_or(false),
    }
}

fn validated_expected_sha256(value: Option<String>) -> Result<Option<String>, String> {
    value
        .and_then(|value| match value.trim() {
            "" => None,
            trimmed => Some(trimmed.to_string()),
        })
        .map(|value| validate_sha256_text(&value))
        .transpose()
}

fn speed_limit_mbps_to_bps(speed_limit_mbps: Option<f64>) -> Option<u64> {
    speed_limit_mbps
        .filter(|value| value.is_finite() && *value > 0.0)
        .map(|value| (value * 1024.0 * 1024.0).round() as u64)
        .filter(|value| *value > 0)
}

fn clamp_concurrency(concurrency: usize) -> usize {
    concurrency.clamp(MIN_CONCURRENCY, MAX_CONCURRENCY)
}

async fn defer_direct_start_when_capacity_full(
    store: &TaskStore,
    task: DownloadTask,
    concurrency: Option<usize>,
    restart_existing: bool,
) -> Result<Option<DownloadTask>, fluxdown_core::TaskStoreError> {
    if restart_existing || !matches!(task.state, DownloadState::Queued | DownloadState::Paused) {
        return Ok(None);
    }

    let concurrency = clamp_concurrency(concurrency.unwrap_or(1));
    let running = store
        .list()
        .await?
        .into_iter()
        .filter(|candidate| candidate.id != task.id && candidate.state == DownloadState::Running)
        .count();
    if running < concurrency {
        return Ok(None);
    }

    // 作者: long
    // 手动点击排队/暂停任务也要遵守并发下载数；容量已满时只放回队列，等正在下载的任务释放槽位。
    if task.state == DownloadState::Paused {
        return store
            .set_state(&task.id, DownloadState::Queued)
            .await
            .map(Some);
    }
    Ok(Some(task))
}

async fn load_task(id: &str) -> Result<DownloadTask, String> {
    let store = TaskStore::new(default_store_path());
    migrate_download_paths(&store)
        .await
        .map_err(|error| error.to_string())?;
    store.get(id).await.map_err(|error| error.to_string())
}

fn existing_task_output_path(task: &DownloadTask) -> PathBuf {
    let path = resolve_task_output_path(task);
    if path.exists() {
        path
    } else {
        task.output_dir.clone()
    }
}

fn resolve_task_output_path(task: &DownloadTask) -> PathBuf {
    let output_dir = resolve_stored_output_dir(&task.output_dir);
    if matches!(task.protocol, Protocol::Torrent | Protocol::Magnet) {
        return task
            .file_name
            .as_ref()
            .map(|file_name| {
                let file_name = sanitize_download_file_name(file_name, "download.bin");
                let direct = output_dir.join(&file_name);
                if direct.exists() {
                    direct
                } else {
                    find_existing_file_by_name(&output_dir, &file_name).unwrap_or(direct)
                }
            })
            .filter(|path| path.exists())
            .unwrap_or(output_dir);
    }

    let file_name = task
        .file_name
        .clone()
        .map(|file_name| sanitize_download_file_name(&file_name, "download.bin"))
        .unwrap_or_else(|| inferred_file_name_from_source(&task.source));
    if task.protocol == Protocol::M3u8 {
        let base = PathBuf::from(&file_name);
        let mp4 = output_dir.join(base.with_extension("mp4"));
        if mp4.exists() {
            return mp4;
        }
        let ts = output_dir.join(base.with_extension("ts"));
        if ts.exists() {
            return ts;
        }
        return mp4;
    }

    output_dir.join(file_name)
}

fn find_existing_file_by_name(root: &Path, file_name: &str) -> Option<PathBuf> {
    // 作者: long
    // 多文件 Torrent 会保留种子里的目录树，任务列表只展示最终文件名；打开文件时需要在保存目录下定位真实落盘文件。
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let entries = std::fs::read_dir(&dir).ok()?;
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file()
                && path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name == file_name)
            {
                return Some(path);
            }
            if path.is_dir() {
                stack.push(path);
            }
        }
    }
    None
}

fn inferred_file_name_from_source(source: &str) -> String {
    let inferred = source
        .rsplit('/')
        .next()
        .and_then(|segment| segment.split('?').next())
        .filter(|segment| !segment.is_empty())
        .unwrap_or("download.bin")
        .to_string();
    sanitize_download_file_name(&inferred, "download.bin")
}

fn reveal_path(path: &Path) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let status = Command::new("open")
            .arg("-R")
            .arg(path)
            .status()
            .map_err(|error| error.to_string())?;
        if status.success() {
            Ok(())
        } else {
            Err(format!("open -R failed with status {status}"))
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        let target = if path.is_dir() {
            path.to_path_buf()
        } else {
            path.parent().unwrap_or(path).to_path_buf()
        };
        open::that(target).map_err(|error| error.to_string())
    }
}

async fn migrate_download_paths(
    store: &TaskStore,
) -> Result<Vec<DownloadTask>, fluxdown_core::TaskStoreError> {
    store
        .recover_stale_running(STALE_RUNNING_TASK_TIMEOUT)
        .await?;
    let tasks = store.list().await?;
    let mut migrated = Vec::with_capacity(tasks.len());
    for mut task in tasks {
        let output_dir = resolve_stored_output_dir(&task.output_dir);
        if output_dir != task.output_dir {
            task.output_dir = output_dir;
            task = store.update(task).await?;
        }
        migrated.push(task);
    }
    Ok(migrated)
}

fn resolve_stored_output_dir(path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        resolve_output_dir(&path.to_string_lossy())
    }
}

fn resolve_output_dir(value: &str) -> PathBuf {
    let trimmed = value.trim();
    if is_legacy_output_dir(trimmed) {
        return default_output_dir_path();
    }

    let expanded = expand_home(trimmed);
    if expanded.is_absolute() {
        expanded
    } else {
        default_output_dir_path().join(expanded)
    }
}

fn is_legacy_output_dir(value: &str) -> bool {
    matches!(value, "" | "." | "./" | "downloads" | "./downloads")
}

fn expand_home(value: &str) -> PathBuf {
    if value == "~" {
        return home_dir().unwrap_or_else(default_output_dir_path);
    }
    if let Some(rest) = value.strip_prefix("~/")
        && let Some(home) = home_dir()
    {
        return home.join(rest);
    }
    PathBuf::from(value)
}

fn default_output_dir_path() -> PathBuf {
    home_dir()
        .map(|home| home.join("Downloads").join("FluxDown"))
        .unwrap_or_else(|| {
            env::current_dir()
                .unwrap_or_else(|_| env::temp_dir())
                .join("downloads")
        })
}

fn home_dir() -> Option<PathBuf> {
    env::var_os("HOME")
        .or_else(|| env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .or_else(|| {
            let drive = env::var_os("HOMEDRIVE")?;
            let path = env::var_os("HOMEPATH")?;
            Some(PathBuf::from(format!(
                "{}{}",
                drive.to_string_lossy(),
                path.to_string_lossy()
            )))
        })
}

// 桌面端检查更新走 GitHub Releases 公开接口；E2E 可用环境变量替换为本地 fixture。
const UPDATE_RELEASES_API_URL: &str =
    "https://api.github.com/repos/lonnnnnng/fluxdown/releases/latest";
const UPDATE_RELEASES_PAGE_URL: &str = "https://github.com/lonnnnnng/fluxdown/releases/latest";

#[derive(Debug, serde::Serialize)]
struct UpdateCheckReport {
    current_version: String,
    latest_version: String,
    has_update: bool,
    release_url: String,
    release_notes: Option<String>,
    published_at: Option<String>,
    download_url: Option<String>,
    download_file_name: Option<String>,
    download_size_bytes: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct GitHubRelease {
    tag_name: Option<String>,
    html_url: Option<String>,
    body: Option<String>,
    published_at: Option<String>,
    #[serde(default)]
    assets: Vec<GitHubReleaseAsset>,
}

#[derive(Debug, Deserialize)]
struct GitHubReleaseAsset {
    name: String,
    browser_download_url: String,
    size: Option<u64>,
}

#[tauri::command]
async fn check_update() -> Result<UpdateCheckReport, String> {
    let api_url = env::var("FLUXDOWN_UPDATE_API_URL")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| UPDATE_RELEASES_API_URL.to_string());
    fetch_latest_release(&api_url).await
}

// 作者: long
// E2E 专用：WebView2 的 browser 级 CDP 不提供窗口尺寸控制，桌面窗口尺寸持久化
// 的自动化验证改走该 command；只在 E2E 运行（存在 e2e webview 参数）时生效。
#[tauri::command]
async fn e2e_window_metrics(
    window: tauri::WebviewWindow,
    resize_width: Option<f64>,
    resize_height: Option<f64>,
) -> Result<serde_json::Value, String> {
    if env::var_os("FLUXDOWN_E2E_WEBVIEW2_ARGS").is_none() {
        return Err("e2e_window_metrics is only available during E2E runs".to_string());
    }
    if let (Some(width), Some(height)) = (resize_width, resize_height) {
        window
            .set_size(tauri::LogicalSize::new(width, height))
            .map_err(|error| error.to_string())?;
        // 作者: long
        // 给 window-state 插件一点时间收到 Resized 事件并更新内存状态。
        tokio::time::sleep(Duration::from_millis(600)).await;
    }
    let inner = window.inner_size().map_err(|error| error.to_string())?;
    let outer = window.outer_size().map_err(|error| error.to_string())?;
    let scale = window.scale_factor().map_err(|error| error.to_string())?;
    Ok(serde_json::json!({
        "inner_width": inner.width,
        "inner_height": inner.height,
        "outer_width": outer.width,
        "outer_height": outer.height,
        "scale_factor": scale,
    }))
}

// 作者: long
// E2E 专用退出入口：window.close() 在 WebView2 中会被忽略，而 window-state 插件
// 需要一次正常退出（RunEvent::Exit）才会把窗口状态写盘。
#[tauri::command]
async fn e2e_quit_app(app: tauri::AppHandle) -> Result<(), String> {
    if env::var_os("FLUXDOWN_E2E_WEBVIEW2_ARGS").is_none() {
        return Err("e2e_quit_app is only available during E2E runs".to_string());
    }
    app.exit(0);
    Ok(())
}

#[tauri::command]
fn open_download_page() -> Result<(), String> {
    open::that(UPDATE_RELEASES_PAGE_URL).map_err(|error| error.to_string())
}

#[tauri::command]
async fn download_and_install_update(
    app: tauri::AppHandle,
    url: String,
    file_name: String,
) -> Result<String, String> {
    let installer = download_update_installer(&url, &file_name).await?;
    if spawn_platform_installer(&installer)? {
        // 作者: long
        // 安装器已接管后，桌面应用延迟退出，避免退出太早导致安装器提示文件被占用。
        let app_for_exit = app.clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(Duration::from_millis(1500)).await;
            app_for_exit.exit(0);
        });
    }
    Ok(installer.to_string_lossy().into_owned())
}

async fn fetch_latest_release(api_url: &str) -> Result<UpdateCheckReport, String> {
    let client = reqwest::Client::builder()
        .user_agent(concat!("FluxDown/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|error| error.to_string())?;
    let response = client
        .get(api_url)
        .header("Accept", "application/vnd.github+json")
        .send()
        .await
        .map_err(|error| format!("无法连接更新服务器: {error}"))?
        .error_for_status()
        .map_err(|error| format!("更新服务器返回错误: {error}"))?;
    let release: GitHubRelease = response
        .json()
        .await
        .map_err(|error| format!("无法解析更新信息: {error}"))?;

    let current_version = env!("CARGO_PKG_VERSION").to_string();
    let latest_version = release
        .tag_name
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.trim_start_matches(['v', 'V']).to_string())
        .ok_or_else(|| "更新信息缺少版本号".to_string())?;
    let asset = release
        .assets
        .iter()
        .find(|asset| matches_platform_asset(&asset.name));

    Ok(UpdateCheckReport {
        has_update: compare_versions(&latest_version, &current_version) == std::cmp::Ordering::Greater,
        current_version,
        latest_version,
        release_url: release
            .html_url
            .unwrap_or_else(|| UPDATE_RELEASES_PAGE_URL.to_string()),
        release_notes: release.body,
        published_at: release.published_at,
        download_url: asset.map(|asset| asset.browser_download_url.clone()),
        download_file_name: asset.map(|asset| asset.name.clone()),
        download_size_bytes: asset.and_then(|asset| asset.size),
    })
}

async fn download_update_installer(url: &str, file_name: &str) -> Result<PathBuf, String> {
    if !is_trusted_download_url(url) {
        return Err(format!("拒绝下载不受信任的更新地址: {url}"));
    }
    let safe_name = sanitize_download_file_name(file_name, "FluxDown-setup.exe");
    let target = env::temp_dir().join(format!("fluxdown-update-{safe_name}"));
    let client = reqwest::Client::builder()
        .user_agent(concat!("FluxDown/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|error| error.to_string())?;
    let mut response = client
        .get(url)
        .send()
        .await
        .map_err(|error| format!("下载更新失败: {error}"))?
        .error_for_status()
        .map_err(|error| format!("下载更新失败: {error}"))?;
    let mut file = tokio::fs::File::create(&target)
        .await
        .map_err(|error| format!("无法创建安装包文件: {error}"))?;
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|error| format!("下载更新中断: {error}"))?
    {
        tokio::io::AsyncWriteExt::write_all(&mut file, &chunk)
            .await
            .map_err(|error| format!("写入安装包失败: {error}"))?;
    }
    tokio::io::AsyncWriteExt::flush(&mut file)
        .await
        .map_err(|error| format!("写入安装包失败: {error}"))?;
    Ok(target)
}

fn spawn_platform_installer(path: &Path) -> Result<bool, String> {
    // 作者: long
    // 按安装包类型交给系统默认安装流程；返回 false 表示当前平台没有对应安装方式，
    // 此时前端引导用户改用“打开下载页”。
    let Some(extension) = path
        .extension()
        .and_then(|value| value.to_str())
        .map(|value| value.to_ascii_lowercase())
    else {
        return Ok(false);
    };
    match extension.as_str() {
        "exe" => std::process::Command::new(path)
            .spawn()
            .map(|_| true)
            .map_err(|error| format!("启动安装器失败: {error}")),
        "msi" => std::process::Command::new("msiexec")
            .args(["/i"])
            .arg(path)
            .spawn()
            .map(|_| true)
            .map_err(|error| format!("启动安装器失败: {error}")),
        "dmg" | "deb" | "rpm" => {
            // 作者: long
            // open::that_in_background 返回 JoinHandle，交给系统后台打开即可，无需等待。
            open::that_in_background(path);
            Ok(true)
        }
        _ => Ok(false),
    }
}

fn is_trusted_download_url(value: &str) -> bool {
    // 作者: long
    // 更新包只允许来自 GitHub 官方发布域；回环地址保留给 E2E fixture。
    let Ok(parsed) = url::Url::parse(value) else {
        return false;
    };
    if !matches!(parsed.scheme(), "https" | "http") {
        return false;
    }
    let Some(host) = parsed.host_str().map(|host| host.to_ascii_lowercase()) else {
        return false;
    };
    matches!(
        host.as_str(),
        "github.com"
            | "api.github.com"
            | "objects.githubusercontent.com"
            | "release-assets.githubusercontent.com"
    ) || host == "127.0.0.1"
        || host == "localhost"
        || host == "[::1]"
}

fn compare_versions(left: &str, right: &str) -> std::cmp::Ordering {
    fn parts(version: &str) -> Vec<u64> {
        version
            .trim()
            .trim_start_matches(['v', 'V'])
            .split('.')
            .map(|part| {
                part.trim()
                    .parse::<u64>()
                    .unwrap_or(0)
            })
            .collect()
    }
    let left = parts(left);
    let right = parts(right);
    for index in 0..left.len().max(right.len()) {
        let l = left.get(index).copied().unwrap_or(0);
        let r = right.get(index).copied().unwrap_or(0);
        if l != r {
            return l.cmp(&r);
        }
    }
    std::cmp::Ordering::Equal
}

fn matches_platform_asset(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    if cfg!(target_os = "windows") {
        cfg!(target_arch = "x86_64") && lower.contains("windows-x86_64-setup.exe")
    } else if cfg!(target_os = "macos") {
        if cfg!(target_arch = "aarch64") {
            lower.contains("macos-aarch64.dmg")
        } else {
            lower.contains("macos-x86_64.dmg")
        }
    } else if cfg!(target_os = "linux") {
        if cfg!(target_arch = "aarch64") {
            lower.contains("linux-aarch64.deb")
        } else {
            lower.contains("linux-amd64.deb")
        }
    } else {
        false
    }
}

// 作者: long
// 托盘：左键单击唤起主窗口；菜单提供显示/退出。主窗口关闭时隐藏到托盘，
// 下载继续进行，用户从托盘回到界面——这是下载器常驻体验的核心。
fn setup_tray(app: &mut tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    use tauri::{
        menu::{Menu, MenuItem},
        tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
        Manager,
    };

    let show_item = MenuItem::with_id(app, "show", "显示 FluxDown", true, None::<&str>)?;
    let quit_item = MenuItem::with_id(app, "quit", "退出 FluxDown", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&show_item, &quit_item])?;

    let mut tray = TrayIconBuilder::with_id("fluxdown-tray")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .tooltip("FluxDown")
        .on_menu_event(|app, event| match event.id().as_ref() {
            "show" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.unminimize();
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
            "quit" => {
                app.exit(0);
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            // 作者: long
            // 左键单击切换主窗口可见性；系统托盘是用户唯一常驻入口，双击语义不必要。
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                if let Some(window) = tray.app_handle().get_webview_window("main") {
                    if window.is_visible().unwrap_or(false) && window.is_focused().unwrap_or(false) {
                        let _ = window.hide();
                    } else {
                        let _ = window.unminimize();
                        let _ = window.show();
                        let _ = window.set_focus();
                    }
                }
            }
        });
    if let Some(icon) = app.default_window_icon() {
        tray = tray.icon(icon.clone());
    }
    tray.build(app)?;

    // 主窗口关闭请求转为隐藏（驻留托盘，下载继续），真正的退出只走托盘菜单。
    if let Some(window) = app.get_webview_window("main") {
        let handle = window.clone();
        window.on_window_event(move |event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = handle.hide();
            }
        });
    }
    Ok(())
}

/// 发送系统通知；Windows 上未安装（dev 运行无 AppUserModelID）时静默失败，
/// 不把通知错误反馈到下载主流程。
#[tauri::command]
fn send_notification(app: tauri::AppHandle, title: String, body: String) -> Result<bool, String> {
    use tauri_plugin_notification::NotificationExt;
    match app
        .notification()
        .builder()
        .title(title)
        .body(body)
        .show()
    {
        Ok(_) => Ok(true),
        Err(_error) => {
            #[cfg(debug_assertions)]
            eprintln!("notification failed: {_error}");
            Ok(false)
        }
    }
}

/// 读取系统剪贴板文本（供前端轮询剪贴板监听使用；Rust 端读取不受浏览器权限限制）。
#[tauri::command]
fn read_clipboard_text(app: tauri::AppHandle) -> Result<Option<String>, String> {
    use tauri_plugin_clipboard_manager::ClipboardExt;
    match app.clipboard().read_text() {
        Ok(text) => {
            let trimmed = text.trim().to_string();
            if trimmed.is_empty() {
                Ok(None)
            } else {
                Ok(Some(trimmed))
            }
        }
        Err(_) => Ok(None),
    }
}

/// 写入系统剪贴板文本（E2E 注入测试链接用，也可供后续“复制”功能统一走此路径）。
#[tauri::command]
fn write_clipboard_text(app: tauri::AppHandle, text: String) -> Result<(), String> {
    use tauri_plugin_clipboard_manager::ClipboardExt;
    app.clipboard().write_text(text).map_err(|error| error.to_string())
}

fn main() {
    tauri::Builder::default()
        // 作者: long
        // 单实例必须是第一个插件：重复启动时把已有主窗口带到前台并退出新进程，
        // 避免两个进程并发写同一个 JSON 队列。
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.unminimize();
                let _ = window.show();
                let _ = window.set_focus();
            }
        }))
        // 作者: long
        // 窗口大小/位置由官方 window-state 插件在窗口变化与退出时持久化，下次启动自动恢复。
        .plugin(tauri_plugin_window_state::Builder::default().build())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .setup(|_app| {
            #[cfg(target_os = "windows")]
            setup_e2e_webview(_app)?;
            setup_tray(_app)?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            detect,
            support,
            doctor,
            default_output_dir,
            plan_download,
            enqueue_download,
            list_downloads,
            pause_download,
            resume_download,
            remove_download,
            task_output_path,
            open_task_output,
            reveal_task_output,
            start_download,
            run_queue,
            check_update,
            open_download_page,
            download_and_install_update,
            list_hls_variants,
            torrent_task_details,
            send_notification,
            read_clipboard_text,
            write_clipboard_text,
            e2e_window_metrics,
            e2e_quit_app
        ])
        .run(tauri::generate_context!())
        .expect("error while running FluxDown desktop app");
}

#[cfg(target_os = "windows")]
fn setup_e2e_webview(app: &mut tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    let Ok(browser_args) = env::var("FLUXDOWN_E2E_WEBVIEW2_ARGS") else {
        return Ok(());
    };
    let data_dir = env::var_os("FLUXDOWN_E2E_WEBVIEW2_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| env::temp_dir().join("fluxdown-e2e-webview2"));
    let url = env::var("FLUXDOWN_E2E_DEV_URL")
        .ok()
        .and_then(|value| value.parse().ok())
        .map(WebviewUrl::External)
        .unwrap_or_else(|| WebviewUrl::App("index.html".into()));

    // 作者: long
    // Windows GUI E2E 需要连接真实 WebView2 的 CDP 端口；额外窗口使用独立 data directory，
    // 避免已打开的日常窗口复用浏览器进程后吞掉 remote-debugging 参数。
    let e2e_window = WebviewWindowBuilder::new(app, "e2e", url)
        .title("FluxDown")
        .inner_size(1280.0, 820.0)
        .min_inner_size(980.0, 680.0)
        .additional_browser_args(&browser_args)
        .data_directory(data_dir)
        .build()?;
    e2e_window.set_focus()?;

    if let Some(main_window) = app.get_webview_window("main") {
        let _ = main_window.close();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::TcpListener;
    use std::sync::{
        Arc, LazyLock,
        atomic::{AtomicUsize, Ordering},
    };
    use std::thread;
    use std::time::Instant;

    static DESKTOP_COMMAND_ENV_LOCK: LazyLock<tokio::sync::Mutex<()>> =
        LazyLock::new(|| tokio::sync::Mutex::new(()));

    struct EnvVarGuard {
        key: &'static str,
        old_value: Option<OsString>,
    }

    impl EnvVarGuard {
        fn set(key: &'static str, value: impl AsRef<std::ffi::OsStr>) -> Self {
            let old_value = std::env::var_os(key);
            // 作者: long
            // 桌面 command 使用默认队列路径；测试时临时改 XDG_DATA_HOME，把真实用户队列和 E2E 队列隔离开。
            unsafe {
                std::env::set_var(key, value);
            }
            Self { key, old_value }
        }
    }

    impl Drop for EnvVarGuard {
        fn drop(&mut self) {
            // 作者: long
            // 环境变量是进程级状态，测试退出时必须恢复，避免影响同一测试进程里的后续用例。
            unsafe {
                if let Some(old_value) = &self.old_value {
                    std::env::set_var(self.key, old_value);
                } else {
                    std::env::remove_var(self.key);
                }
            }
        }
    }

    fn spawn_single_file_http_server(payload: &'static [u8]) -> String {
        spawn_checked_http_server(payload, "/fixture.txt")
    }

    #[test]
    fn compare_versions_handles_semver_segments() {
        use std::cmp::Ordering;
        assert_eq!(compare_versions("1.0.11", "1.0.10"), Ordering::Greater);
        assert_eq!(compare_versions("v1.0.11", "1.0.11"), Ordering::Equal);
        assert_eq!(compare_versions("1.0", "1.0.0"), Ordering::Equal);
        assert_eq!(compare_versions("0.9.9", "1.0.0"), Ordering::Less);
        assert_eq!(compare_versions("2.0", "1.99.99"), Ordering::Greater);
        // 预发布段无法按数字解析，按 0 处理，因此排在对应正式版之前。
        assert_eq!(compare_versions("1.0.11-beta", "1.0.11"), Ordering::Less);
    }

    #[test]
    fn matches_platform_asset_selects_platform_installer() {
        // 作者: long
        // 断言跟随编译目标平台，保证每台机器上匹配到的都是自己平台的安装包。
        let expected = if cfg!(target_os = "windows") {
            "FluxDown-1.0.12-windows-x86_64-setup.exe"
        } else if cfg!(target_os = "macos") {
            "FluxDown-1.0.12-macos-aarch64.dmg"
        } else if cfg!(target_os = "linux") {
            "FluxDown-1.0.12-linux-amd64.deb"
        } else {
            return;
        };
        assert!(matches_platform_asset(expected));
        assert!(!matches_platform_asset("FluxDown-1.0.12-android-release.apk"));
        if cfg!(target_os = "windows") {
            assert!(!matches_platform_asset(
                "FluxDown-1.0.12-macos-aarch64.dmg"
            ));
        }
    }

    #[test]
    fn trusted_download_urls_whitelist_github_and_loopback() {
        assert!(is_trusted_download_url(
            "https://github.com/lonnnnnng/fluxdown/releases/download/v1.0.12/setup.exe"
        ));
        assert!(is_trusted_download_url(
            "https://objects.githubusercontent.com/fluxdown/setup.exe"
        ));
        assert!(is_trusted_download_url(
            "http://127.0.0.1:45321/FluxDown-99.0.0-windows-x86_64-setup.exe"
        ));
        assert!(!is_trusted_download_url(
            "https://evil.example.com/github.com/setup.exe"
        ));
        assert!(!is_trusted_download_url(
            "ftp://github.com/lonnnnnng/setup.exe"
        ));
        assert!(!is_trusted_download_url("not a url"));
    }

    fn spawn_checked_http_server(payload: &'static [u8], expected_path: &'static str) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buffer = [0; 1024];
            let read = stream.read(&mut buffer).unwrap();
            let request = String::from_utf8_lossy(&buffer[..read]);
            assert!(request.starts_with(&format!("GET {expected_path} ")));
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                payload.len()
            );
            stream.write_all(response.as_bytes()).unwrap();
            stream.write_all(payload).unwrap();
        });
        format!("http://{address}/fixture.txt")
    }

    fn spawn_flaky_http_server(
        payload: &'static [u8],
        expected_path: &'static str,
    ) -> (String, Arc<AtomicUsize>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let attempts = Arc::new(AtomicUsize::new(0));
        let server_attempts = Arc::clone(&attempts);
        thread::spawn(move || {
            for _ in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                let mut buffer = [0; 1024];
                let read = stream.read(&mut buffer).unwrap();
                let request = String::from_utf8_lossy(&buffer[..read]);
                assert!(request.starts_with(&format!("GET {expected_path} ")));
                let attempt = server_attempts.fetch_add(1, Ordering::SeqCst) + 1;
                if attempt == 1 {
                    let body = b"temporary desktop retry failure";
                    let response = format!(
                        "HTTP/1.1 500 Internal Server Error\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    );
                    stream.write_all(response.as_bytes()).unwrap();
                    stream.write_all(body).unwrap();
                    continue;
                }
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    payload.len()
                );
                stream.write_all(response.as_bytes()).unwrap();
                stream.write_all(payload).unwrap();
            }
        });
        (format!("http://{address}{expected_path}"), attempts)
    }

    fn spawn_restart_http_server(payload: &'static [u8], expected_path: &'static str) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buffer = [0; 2048];
            let read = stream.read(&mut buffer).unwrap();
            let request = String::from_utf8_lossy(&buffer[..read]);
            assert!(request.starts_with(&format!("GET {expected_path} ")));
            assert!(!request.to_ascii_lowercase().contains("range:"));
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                payload.len()
            );
            stream.write_all(response.as_bytes()).unwrap();
            stream.write_all(payload).unwrap();
        });
        format!("http://{address}{expected_path}")
    }

    fn spawn_streaming_http_server(payload: Vec<u8>, path: &'static str) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buffer = [0; 1024];
            let read = stream.read(&mut buffer).unwrap();
            let request = String::from_utf8_lossy(&buffer[..read]);
            assert!(request.starts_with(&format!("GET {path} ")));
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                payload.len()
            );
            if stream.write_all(response.as_bytes()).is_err() {
                return;
            }
            for chunk in payload.chunks(16 * 1024) {
                if stream.write_all(chunk).is_err() {
                    break;
                }
            }
        });
        format!("http://{address}{path}")
    }

    fn spawn_resumable_streaming_http_server(
        payload: Vec<u8>,
        path: &'static str,
        requests: usize,
    ) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        thread::spawn(move || {
            for _ in 0..requests {
                let (mut stream, _) = listener.accept().unwrap();
                let mut buffer = Vec::with_capacity(2048);
                let mut chunk = [0; 512];
                loop {
                    let read = stream.read(&mut chunk).unwrap();
                    if read == 0 {
                        break;
                    }
                    buffer.extend_from_slice(&chunk[..read]);
                    if buffer.windows(4).any(|window| window == b"\r\n\r\n") {
                        break;
                    }
                }
                let request = String::from_utf8_lossy(&buffer);
                assert!(request.starts_with(&format!("GET {path} ")));

                let (start, end) = request
                    .lines()
                    .find_map(|line| {
                        let (name, value) = line.split_once(':')?;
                        if name.eq_ignore_ascii_case("range") {
                            value.trim().strip_prefix("bytes=")
                        } else {
                            None
                        }
                    })
                    .and_then(|range| {
                        let (start, end) = range.split_once('-')?;
                        Some((
                            start.parse::<usize>().ok()?,
                            end.parse::<usize>().ok().unwrap_or(payload.len() - 1),
                        ))
                    })
                    .map(|(start, end)| (start, end.min(payload.len() - 1)))
                    .unwrap_or((0, payload.len() - 1));
                let status = if start == 0 && end + 1 == payload.len() {
                    "200 OK"
                } else {
                    "206 Partial Content"
                };
                let body = &payload[start..=end];
                let content_range = if status.starts_with("206") {
                    format!("Content-Range: bytes {start}-{end}/{}\r\n", payload.len())
                } else {
                    String::new()
                };
                let response = format!(
                    "HTTP/1.1 {status}\r\n{content_range}Accept-Ranges: bytes\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                if stream.write_all(response.as_bytes()).is_err() {
                    continue;
                }
                // 作者: long
                // 暂停/继续验证依赖首轮传输保持可取消，第二轮再通过 Range 续传补齐同一个目标文件。
                for (index, chunk) in body.chunks(8 * 1024).enumerate() {
                    if stream.write_all(chunk).is_err() {
                        break;
                    }
                    if index + 1 < body.len().div_ceil(8 * 1024) {
                        thread::sleep(Duration::from_millis(20));
                    }
                }
            }
        });
        format!("http://{address}{path}")
    }

    fn spawn_ftp_server(
        payload: &'static [u8],
        expected_path: &'static str,
    ) -> (String, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut control, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(control.try_clone().unwrap());
            let mut passive_listener: Option<TcpListener> = None;
            control.write_all(b"220 FluxDown test FTP\r\n").unwrap();

            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap() == 0 {
                    break;
                }
                let command = line.trim_end_matches(['\r', '\n']);
                let upper = command.to_ascii_uppercase();
                if upper.starts_with("USER ") {
                    control.write_all(b"331 Password required\r\n").unwrap();
                } else if upper.starts_with("PASS ") {
                    control.write_all(b"230 Logged in\r\n").unwrap();
                } else if upper == "SYST" {
                    control.write_all(b"215 UNIX Type: L8\r\n").unwrap();
                } else if upper == "FEAT" {
                    control.write_all(b"211 End\r\n").unwrap();
                } else if upper.starts_with("OPTS ") || upper.starts_with("TYPE ") {
                    control.write_all(b"200 OK\r\n").unwrap();
                } else if upper.starts_with("SIZE ") {
                    let path = command.split_once(' ').map(|(_, path)| path).unwrap_or("");
                    assert_eq!(
                        path.trim_start_matches('/'),
                        expected_path.trim_start_matches('/')
                    );
                    control
                        .write_all(format!("213 {}\r\n", payload.len()).as_bytes())
                        .unwrap();
                } else if upper.starts_with("REST ") {
                    control
                        .write_all(b"350 Restarting at requested offset\r\n")
                        .unwrap();
                } else if upper == "EPSV" {
                    // 作者: long
                    // FTP 下载必须经历被动数据连接，fixture 真实打开数据端口，才能覆盖桌面客户端实际传输路径。
                    let data_listener = TcpListener::bind("127.0.0.1:0").unwrap();
                    let port = data_listener.local_addr().unwrap().port();
                    passive_listener = Some(data_listener);
                    control
                        .write_all(
                            format!("229 Entering Extended Passive Mode (|||{port}|)\r\n")
                                .as_bytes(),
                        )
                        .unwrap();
                } else if upper.starts_with("RETR ") {
                    let path = command.split_once(' ').map(|(_, path)| path).unwrap_or("");
                    assert_eq!(
                        path.trim_start_matches('/'),
                        expected_path.trim_start_matches('/')
                    );
                    control
                        .write_all(b"150 Opening data connection\r\n")
                        .unwrap();
                    // 作者: long
                    // RETR 阶段才写入文件内容，确保测试验证的是控制连接协商后的真实落盘，而不是绕过协议栈。
                    let listener = passive_listener
                        .take()
                        .expect("RETR should follow EPSV in the desktop FTP fixture");
                    let (mut data, _) = listener.accept().unwrap();
                    data.write_all(payload).unwrap();
                    let _ = data.shutdown(std::net::Shutdown::Both);
                    control.write_all(b"226 Transfer complete\r\n").unwrap();
                } else if upper == "QUIT" {
                    control.write_all(b"221 Bye\r\n").unwrap();
                    break;
                } else {
                    control.write_all(b"200 OK\r\n").unwrap();
                }
            }
        });
        (
            format!("ftp://flux:fluxpass@{address}{expected_path}"),
            server,
        )
    }

    fn spawn_hls_http_server() -> (String, Vec<u8>) {
        let first_segment = b"desktop command hls first segment".to_vec();
        let second_segment = b"desktop command hls second segment".to_vec();
        let expected = [first_segment.clone(), second_segment.clone()].concat();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        thread::spawn(move || {
            for _ in 0..3 {
                let (mut stream, _) = listener.accept().unwrap();
                let mut buffer = [0; 1024];
                let read = stream.read(&mut buffer).unwrap();
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
                        b"#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:1,\nseg-1.ts\n#EXTINF:1,\nseg-2.ts\n#EXT-X-ENDLIST\n"
                            .to_vec(),
                    ),
                    "/seg-1.ts" => ("200 OK", "video/mp2t", first_segment.clone()),
                    "/seg-2.ts" => ("200 OK", "video/mp2t", second_segment.clone()),
                    _ => ("404 Not Found", "text/plain", b"not found".to_vec()),
                };
                let header = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                stream.write_all(header.as_bytes()).unwrap();
                stream.write_all(&body).unwrap();
            }
        });
        (format!("http://{address}/playlist.m3u8"), expected)
    }

    fn spawn_hls_byte_range_http_server() -> (String, Vec<u8>) {
        let first_segment = b"desktop command byte range hls first".to_vec();
        let second_segment = b"desktop command byte range hls second".to_vec();
        let expected = [first_segment.clone(), second_segment.clone()].concat();
        let media = expected.clone();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        thread::spawn(move || {
            for _ in 0..3 {
                let (mut stream, _) = listener.accept().unwrap();
                let mut buffer = [0; 2048];
                let read = stream.read(&mut buffer).unwrap();
                let request = String::from_utf8_lossy(&buffer[..read]);
                let path = request
                    .lines()
                    .next()
                    .and_then(|line| line.split_whitespace().nth(1))
                    .unwrap_or("/");
                let range = request.lines().find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    if name.eq_ignore_ascii_case("range") {
                        value.trim().strip_prefix("bytes=")
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
                                first_segment.len(),
                                second_segment.len()
                            )
                            .into_bytes(),
                        ),
                        "/media.ts" => {
                            let (start, end) = range
                                .and_then(|value| value.split_once('-'))
                                .and_then(|(start, end)| {
                                    Some((start.parse::<usize>().ok()?, end.parse::<usize>().ok()?))
                                })
                                .expect("HLS BYTERANGE media requests must include Range");
                            (
                                "206 Partial Content",
                                "video/mp2t",
                                format!("Content-Range: bytes {start}-{end}/{}\r\n", media.len()),
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
                stream.write_all(header.as_bytes()).unwrap();
                stream.write_all(&body).unwrap();
            }
        });
        (format!("http://{address}/playlist.m3u8"), expected)
    }

    async fn wait_for_desktop_running_progress(id: &str) -> DownloadTask {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(task) = list_downloads()
                .await
                .unwrap()
                .into_iter()
                .find(|task| task.id == id)
                && task.state == DownloadState::Running
                && task.downloaded_bytes > 0
            {
                return task;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for desktop task {id} to enter running progress"
            );
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    fn server_address(source: &str) -> &str {
        source
            .strip_prefix("http://")
            .expect("test server source should use http")
            .split('/')
            .next()
            .expect("test server source should include an address")
    }

    fn manual_fixture(name: &str, script: &str) -> String {
        std::env::var(name).unwrap_or_else(|_| panic!("{name} is required; run {script} instead"))
    }

    #[test]
    fn resolves_regular_task_output_path() {
        let temp_dir = tempfile::tempdir().unwrap();
        let mut task = DownloadTask::from_request(DownloadRequest::new(
            "https://example.com/archive.zip",
            temp_dir.path(),
        ));
        task.file_name = Some("renamed.zip".to_string());

        assert_eq!(
            resolve_task_output_path(&task),
            temp_dir.path().join("renamed.zip")
        );
    }

    #[test]
    fn resolves_legacy_unsafe_file_name_inside_output_dir() {
        let temp_dir = tempfile::tempdir().unwrap();
        let mut task = DownloadTask::from_request(DownloadRequest::new(
            "https://example.com/archive.zip",
            temp_dir.path(),
        ));
        task.file_name = Some("../legacy:name.zip".to_string());

        assert_eq!(
            resolve_task_output_path(&task),
            temp_dir.path().join("_legacy_name.zip")
        );
    }

    #[test]
    fn resolves_hls_output_to_existing_mp4() {
        let temp_dir = tempfile::tempdir().unwrap();
        std::fs::write(temp_dir.path().join("index.mp4"), b"mp4").unwrap();
        let mut task = DownloadTask::from_request(DownloadRequest::new(
            "https://example.com/index.m3u8",
            temp_dir.path(),
        ));
        task.file_name = Some("index.m3u8".to_string());

        assert_eq!(
            resolve_task_output_path(&task),
            temp_dir.path().join("index.mp4")
        );
    }

    #[test]
    fn resolves_torrent_output_to_folder_when_file_is_unknown() {
        let temp_dir = tempfile::tempdir().unwrap();
        let task = DownloadTask::from_request(DownloadRequest::new(
            "magnet:?xt=urn:btih:0123456789012345678901234567890123456789",
            temp_dir.path(),
        ));

        assert_eq!(resolve_task_output_path(&task), temp_dir.path());
    }

    #[tokio::test]
    async fn desktop_commands_download_hls_task_through_queue() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");
        let (source, expected_payload) = spawn_hls_http_server();

        let task = enqueue_download(AddPayload {
            source,
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some("desktop-hls.m3u8".to_string()),
            expected_sha256: None,
            torrent_file_indices: Vec::new(),
        ..Default::default()
}        )
        .await
        .unwrap();
        assert_eq!(task.protocol, Protocol::M3u8);

        let report = run_queue(1, Some(1), Some(1), None, Some(false))
            .await
            .unwrap();
        assert_eq!(report.started, 1);
        assert_eq!(report.finished, 1);
        assert_eq!(report.failed, 0);

        let tasks = list_downloads().await.unwrap();
        assert_eq!(tasks[0].state, DownloadState::Finished);
        let file_name = tasks[0].file_name.as_deref().unwrap();
        assert!(matches!(file_name, "desktop-hls.ts" | "desktop-hls.mp4"));
        let output_path = PathBuf::from(task_output_path(tasks[0].id.clone()).await.unwrap());
        assert_eq!(
            output_path.file_name().and_then(|name| name.to_str()),
            Some(file_name)
        );
        // 作者: long
        // 桌面队列必须能把 HLS 任务收敛成一个真实本地文件，列表和打开文件动作都依赖这个最终产物路径。
        assert_eq!(std::fs::read(output_path).unwrap(), expected_payload);
    }

    #[tokio::test]
    async fn desktop_commands_download_hls_byte_range_task_through_queue() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");
        let (source, expected_payload) = spawn_hls_byte_range_http_server();

        let task = enqueue_download(AddPayload {
            source,
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some("desktop-hls-byte-range.m3u8".to_string()),
            expected_sha256: None,
            torrent_file_indices: Vec::new(),
        ..Default::default()
}        )
        .await
        .unwrap();
        assert_eq!(task.protocol, Protocol::M3u8);

        let report = run_queue(1, Some(1), Some(1), None, Some(false))
            .await
            .unwrap();
        assert_eq!(report.started, 1);
        assert_eq!(report.finished, 1);
        assert_eq!(report.failed, 0);

        let tasks = list_downloads().await.unwrap();
        assert_eq!(tasks[0].state, DownloadState::Finished);
        let file_name = tasks[0].file_name.as_deref().unwrap();
        assert!(matches!(
            file_name,
            "desktop-hls-byte-range.ts" | "desktop-hls-byte-range.mp4"
        ));
        let output_path = PathBuf::from(task_output_path(tasks[0].id.clone()).await.unwrap());
        assert_eq!(
            output_path.file_name().and_then(|name| name.to_str()),
            Some(file_name)
        );
        assert_eq!(std::fs::read(output_path).unwrap(), expected_payload);
    }

    #[tokio::test]
    async fn desktop_commands_download_http_task_through_queue() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");
        let payload = b"fluxdown-desktop-command-e2e";
        let expected_sha256 = "0b2fd11b5c64fcd641e4bbe9d769400f2be35768f511848ef02906e6433a752e";
        let source = spawn_single_file_http_server(payload);

        let task = enqueue_download(AddPayload {
            source,
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some("desktop-command.txt".to_string()),
            expected_sha256: Some(format!("sha256:{expected_sha256}")),
            torrent_file_indices: Vec::new(),
        ..Default::default()
}        )
        .await
        .unwrap();
        assert_eq!(task.state, DownloadState::Queued);
        assert_eq!(task.expected_sha256.as_deref(), Some(expected_sha256));
        assert_eq!(list_downloads().await.unwrap().len(), 1);

        let report = run_queue(1, Some(1), Some(1), None, Some(false))
            .await
            .unwrap();
        assert_eq!(report.started, 1);
        assert_eq!(report.finished, 1);
        assert_eq!(report.failed, 0);

        let tasks = list_downloads().await.unwrap();
        assert_eq!(tasks[0].state, DownloadState::Finished);
        assert_eq!(tasks[0].file_name.as_deref(), Some("desktop-command.txt"));
        assert_eq!(tasks[0].expected_sha256.as_deref(), Some(expected_sha256));
        let output_path = output_dir.join("desktop-command.txt");
        assert_eq!(
            task_output_path(tasks[0].id.clone()).await.unwrap(),
            output_path.to_string_lossy()
        );
        assert_eq!(std::fs::read(&output_path).unwrap(), payload);

        let removed = remove_download(tasks[0].id.clone()).await.unwrap();
        assert_eq!(removed.id, tasks[0].id);
        assert!(list_downloads().await.unwrap().is_empty());
        assert_eq!(std::fs::read(output_path).unwrap(), payload);
    }

    #[tokio::test]
    async fn desktop_queue_marks_sha256_mismatch_as_failed() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");
        let payload = b"fluxdown-desktop-command-e2e";
        let wrong_sha256 = "8810ad581e59f2bc3928b261707a71308f7e139eb04820366dc4d5c18d980225";
        let source = spawn_single_file_http_server(payload);

        let task = enqueue_download(AddPayload {
            source,
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some("desktop-command.txt".to_string()),
            expected_sha256: Some(wrong_sha256.to_string()),
            torrent_file_indices: Vec::new(),
        ..Default::default()
}        )
        .await
        .unwrap();
        assert_eq!(task.expected_sha256.as_deref(), Some(wrong_sha256));

        let report = run_queue(1, Some(0), Some(1), None, Some(false))
            .await
            .unwrap();
        assert_eq!(report.started, 1);
        assert_eq!(report.finished, 0);
        assert_eq!(report.failed, 1);
        assert_eq!(report.tasks[0].state, DownloadState::Failed);
        let error = report.tasks[0].error.as_deref().unwrap_or_default();
        assert!(error.contains("SHA-256 mismatch"), "{error}");
        assert!(error.contains(wrong_sha256), "{error}");
    }

    #[tokio::test]
    async fn desktop_queue_retries_failed_http_task() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");
        let payload = b"fluxdown-desktop-retry-success";
        let (source, attempts) = spawn_flaky_http_server(payload, "/retry.txt");

        let task = enqueue_download(AddPayload {
            source,
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some("desktop-retry.txt".to_string()),
            expected_sha256: None,
            torrent_file_indices: Vec::new(),
        ..Default::default()
}        )
        .await
        .unwrap();

        let report = run_queue(1, Some(1), Some(1), None, Some(false))
            .await
            .unwrap();
        assert_eq!(report.started, 1);
        assert_eq!(report.finished, 1);
        assert_eq!(report.failed, 0);
        assert_eq!(attempts.load(Ordering::SeqCst), 2);

        let tasks = list_downloads().await.unwrap();
        assert_eq!(tasks[0].id, task.id);
        assert_eq!(tasks[0].state, DownloadState::Finished);
        assert_eq!(tasks[0].file_name.as_deref(), Some("desktop-retry.txt"));
        // 作者: long
        // 桌面设置里的自动重试要真正驱动队列重新发起下载，不能只停留在参数保存或失败状态展示。
        assert_eq!(
            std::fs::read(output_dir.join("desktop-retry.txt")).unwrap(),
            payload
        );
    }

    #[tokio::test]
    async fn desktop_enqueue_rejects_invalid_sha256_without_writing_queue() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");

        let error = enqueue_download(AddPayload {
            source: "http://127.0.0.1:9/desktop-command.txt".to_string(),
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some("desktop-command.txt".to_string()),
            expected_sha256: Some("not-a-sha256".to_string()),
            torrent_file_indices: Vec::new(),
        ..Default::default()
}        )
        .await
        .unwrap_err();

        assert!(error.contains("invalid SHA-256 checksum"), "{error}");
        assert!(list_downloads().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn desktop_enqueue_persists_torrent_file_indices() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");

        let task = enqueue_download(AddPayload {
            source: "/tmp/multi-file.torrent".to_string(),
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some("multi-file.torrent".to_string()),
            expected_sha256: None,
            torrent_file_indices: vec![4, 1, 4],
            ..Default::default()
        })
        .await
        .unwrap();

        assert_eq!(task.protocol, Protocol::Torrent);
        assert_eq!(task.torrent_file_indices, vec![1, 4]);
        let tasks = list_downloads().await.unwrap();
        assert_eq!(tasks[0].torrent_file_indices, vec![1, 4]);
    }

    #[tokio::test]
    async fn desktop_commands_download_ftp_task_through_queue() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");
        let payload = b"fluxdown-desktop-ftp-e2e";
        let (source, server) = spawn_ftp_server(payload, "/files/desktop-ftp.bin");

        let task = enqueue_download(AddPayload {
            source,
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some("desktop-ftp.txt".to_string()),
            expected_sha256: None,
            torrent_file_indices: Vec::new(),
        ..Default::default()
}        )
        .await
        .unwrap();
        assert_eq!(task.protocol, Protocol::Ftp);

        let report = run_queue(1, Some(1), Some(1), None, Some(false))
            .await
            .unwrap();
        server.join().unwrap();
        assert_eq!(report.started, 1);
        assert_eq!(report.finished, 1);
        assert_eq!(report.failed, 0);

        let tasks = list_downloads().await.unwrap();
        assert_eq!(tasks[0].state, DownloadState::Finished);
        assert_eq!(tasks[0].file_name.as_deref(), Some("desktop-ftp.txt"));
        assert_eq!(
            std::fs::read(output_dir.join("desktop-ftp.txt")).unwrap(),
            payload
        );
    }

    #[tokio::test]
    async fn desktop_start_download_runs_single_http_task() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");
        let payload = b"fluxdown-desktop-direct-start";
        let source = spawn_single_file_http_server(payload);

        let task = enqueue_download(AddPayload {
            source,
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some("desktop-start.txt".to_string()),
            expected_sha256: None,
            torrent_file_indices: Vec::new(),
        ..Default::default()
}        )
        .await
        .unwrap();

        let report = start_download(
            task.id.clone(),
            Some(1),
            Some(1),
            Some(1),
            None,
            Some(false),
        )
        .await
        .unwrap();
        assert_eq!(report.task.state, DownloadState::Finished);
        assert_eq!(report.task.file_name.as_deref(), Some("desktop-start.txt"));
        assert_eq!(report.task.downloaded_bytes, payload.len() as u64);
        assert_eq!(report.summary.unwrap().bytes_written, payload.len() as u64);

        let tasks = list_downloads().await.unwrap();
        assert_eq!(tasks[0].state, DownloadState::Finished);
        let output_path = output_dir.join("desktop-start.txt");
        // 作者: long
        // 点击单个任务开始下载走 start_download，不经过 run_queue；这里保证主列表的单项操作也能真实落盘。
        assert_eq!(
            task_output_path(task.id.clone()).await.unwrap(),
            output_path.to_string_lossy()
        );
        assert_eq!(std::fs::read(output_path).unwrap(), payload);
    }

    #[tokio::test]
    async fn desktop_start_download_restart_replaces_finished_output() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");
        std::fs::create_dir_all(&output_dir).unwrap();
        std::fs::write(
            output_dir.join("desktop-restart.txt"),
            b"stale complete file",
        )
        .unwrap();
        let payload = b"fluxdown-desktop-restarted-download";
        let source = spawn_restart_http_server(payload, "/restart.txt");

        let task = enqueue_download(AddPayload {
            source,
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some("desktop-restart.txt".to_string()),
            expected_sha256: None,
            torrent_file_indices: Vec::new(),
        ..Default::default()
}        )
        .await
        .unwrap();
        TaskStore::new(default_store_path())
            .set_state(&task.id, DownloadState::Finished)
            .await
            .unwrap();

        let report = start_download(task.id.clone(), Some(1), Some(1), Some(1), None, Some(true))
            .await
            .unwrap();
        assert_eq!(report.task.state, DownloadState::Finished);
        assert_eq!(report.task.downloaded_bytes, payload.len() as u64);
        assert!(report.task.started_at_ms.is_some());
        assert!(report.task.finished_at_ms >= report.task.started_at_ms);
        // 作者: long
        // 重新下载已完成任务要丢弃旧文件重新拉取，避免把上一次的完整文件当作断点继续。
        assert_eq!(
            std::fs::read(output_dir.join("desktop-restart.txt")).unwrap(),
            payload
        );
    }

    #[tokio::test]
    async fn desktop_start_download_runs_single_ftp_task() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");
        let payload = b"fluxdown-desktop-start-ftp";
        let (source, server) = spawn_ftp_server(payload, "/files/start-ftp.bin");

        let task = enqueue_download(AddPayload {
            source,
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some("desktop-start-ftp.txt".to_string()),
            expected_sha256: None,
            torrent_file_indices: Vec::new(),
        ..Default::default()
}        )
        .await
        .unwrap();
        assert_eq!(task.protocol, Protocol::Ftp);

        let report = start_download(
            task.id.clone(),
            Some(1),
            Some(1),
            Some(1),
            None,
            Some(false),
        )
        .await
        .unwrap();
        server.join().unwrap();
        assert_eq!(report.task.state, DownloadState::Finished);
        assert_eq!(
            report.task.file_name.as_deref(),
            Some("desktop-start-ftp.txt")
        );
        assert_eq!(report.task.downloaded_bytes, payload.len() as u64);

        let output_path = output_dir.join("desktop-start-ftp.txt");
        // 作者: long
        // FTP 单任务启动要覆盖真实控制连接和数据连接，确保桌面列表点击开始不是只验证了 HTTP 快路径。
        assert_eq!(
            task_output_path(task.id.clone()).await.unwrap(),
            output_path.to_string_lossy()
        );
        assert_eq!(std::fs::read(output_path).unwrap(), payload);
    }

    #[tokio::test]
    async fn desktop_start_download_runs_single_hls_task() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");
        let (source, expected_payload) = spawn_hls_http_server();

        let task = enqueue_download(AddPayload {
            source,
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some("desktop-start-hls.m3u8".to_string()),
            expected_sha256: None,
            torrent_file_indices: Vec::new(),
        ..Default::default()
}        )
        .await
        .unwrap();

        let report = start_download(
            task.id.clone(),
            Some(1),
            Some(1),
            Some(1),
            None,
            Some(false),
        )
        .await
        .unwrap();
        assert_eq!(report.task.state, DownloadState::Finished);
        let file_name = report.task.file_name.as_deref().unwrap();
        assert!(matches!(
            file_name,
            "desktop-start-hls.ts" | "desktop-start-hls.mp4"
        ));
        assert_eq!(report.task.downloaded_bytes, expected_payload.len() as u64);
        assert_eq!(report.summary.unwrap().segments_written, Some(2));

        let tasks = list_downloads().await.unwrap();
        assert_eq!(tasks[0].state, DownloadState::Finished);
        let output_path = PathBuf::from(task_output_path(task.id.clone()).await.unwrap());
        assert_eq!(
            output_path.file_name().and_then(|name| name.to_str()),
            Some(file_name)
        );
        // 作者: long
        // HLS 单任务启动要和队列启动一样回写最终产物名，确保列表点击下载和批量运行得到一致结果。
        assert_eq!(std::fs::read(output_path).unwrap(), expected_payload);
    }

    #[tokio::test]
    async fn desktop_start_download_runs_single_webdav_task() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");
        let payload = b"fluxdown-desktop-start-webdav";
        let source = spawn_checked_http_server(payload, "/remote.php/dav/files/start-webdav.bin");
        let address = server_address(&source);

        let task = enqueue_download(AddPayload {
            source: format!("webdav://{address}/remote.php/dav/files/start-webdav.bin"),
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some("desktop-start-webdav.txt".to_string()),
            expected_sha256: None,
            torrent_file_indices: Vec::new(),
        ..Default::default()
}        )
        .await
        .unwrap();
        assert_eq!(task.protocol, Protocol::Webdav);

        let report = start_download(
            task.id.clone(),
            Some(1),
            Some(1),
            Some(1),
            None,
            Some(false),
        )
        .await
        .unwrap();
        assert_eq!(report.task.state, DownloadState::Finished);
        assert_eq!(
            report.task.file_name.as_deref(),
            Some("desktop-start-webdav.txt")
        );
        assert_eq!(report.task.downloaded_bytes, payload.len() as u64);

        let output_path = output_dir.join("desktop-start-webdav.txt");
        // 作者: long
        // WebDAV 单任务启动同样要走协议映射，避免列表点击开始和队列运行出现不同下载路径。
        assert_eq!(
            task_output_path(task.id.clone()).await.unwrap(),
            output_path.to_string_lossy()
        );
        assert_eq!(std::fs::read(output_path).unwrap(), payload);
    }

    #[tokio::test]
    async fn desktop_commands_can_remove_running_task_during_queue_run() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");
        let payload = vec![b'd'; 512 * 1024];
        let total_bytes = payload.len() as u64;
        let source = spawn_streaming_http_server(payload, "/delete-running.bin");

        let task = enqueue_download(AddPayload {
            source,
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some("delete-running.bin".to_string()),
            expected_sha256: None,
            torrent_file_indices: Vec::new(),
        ..Default::default()
}        )
        .await
        .unwrap();
        let task_id = task.id.clone();

        let run =
            tokio::spawn(async { run_queue(1, Some(0), Some(1), Some(0.05), Some(false)).await });

        let running = wait_for_desktop_running_progress(&task_id).await;
        assert!(running.downloaded_bytes < total_bytes);

        let removed = remove_download(task_id.clone()).await.unwrap();
        assert_eq!(removed.id, task_id);
        assert_eq!(removed.state, DownloadState::Running);

        let report = tokio::time::timeout(Duration::from_secs(5), run)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(report.started, 1);
        assert_eq!(report.finished, 0);
        assert_eq!(report.failed, 0);
        assert_eq!(report.tasks[0].id, task_id);
        assert_eq!(report.tasks[0].state, DownloadState::Paused);
        assert!(list_downloads().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn desktop_commands_can_pause_and_resume_running_task_during_queue_run() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");
        let payload = vec![b'p'; 768 * 1024];
        let total_bytes = payload.len() as u64;
        let source =
            spawn_resumable_streaming_http_server(payload.clone(), "/pause-running.bin", 2);

        let task = enqueue_download(AddPayload {
            source,
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some("pause-running.bin".to_string()),
            expected_sha256: None,
            torrent_file_indices: Vec::new(),
        ..Default::default()
}        )
        .await
        .unwrap();
        let task_id = task.id.clone();

        let run =
            tokio::spawn(async { run_queue(1, Some(0), Some(1), Some(0.05), Some(false)).await });

        let running = wait_for_desktop_running_progress(&task_id).await;
        assert!(running.downloaded_bytes < total_bytes);
        let paused = pause_download(task_id.clone()).await.unwrap();
        assert_eq!(paused.state, DownloadState::Paused);

        let report = tokio::time::timeout(Duration::from_secs(5), run)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(report.started, 1);
        assert_eq!(report.finished, 0);
        assert_eq!(report.failed, 0);
        assert_eq!(report.tasks[0].state, DownloadState::Paused);

        let paused_task = list_downloads()
            .await
            .unwrap()
            .into_iter()
            .find(|task| task.id == task_id)
            .unwrap();
        assert_eq!(paused_task.state, DownloadState::Paused);
        assert!(paused_task.downloaded_bytes > 0);
        assert!(paused_task.downloaded_bytes < total_bytes);

        let resumed = resume_download(task_id.clone()).await.unwrap();
        assert_eq!(resumed.state, DownloadState::Queued);
        let report = run_queue(1, Some(0), Some(1), None, Some(false))
            .await
            .unwrap();
        assert_eq!(report.started, 1);
        assert_eq!(report.finished, 1);
        assert_eq!(report.failed, 0);

        let tasks = list_downloads().await.unwrap();
        assert_eq!(tasks[0].state, DownloadState::Finished);
        assert_eq!(tasks[0].downloaded_bytes, total_bytes);
        assert_eq!(
            task_output_path(task_id).await.unwrap(),
            output_dir.join("pause-running.bin").to_string_lossy()
        );
        // 作者: long
        // 桌面端暂停后恢复必须复用同一个本地文件继续写完，最终内容要和源数据逐字节一致。
        assert_eq!(
            std::fs::read(output_dir.join("pause-running.bin")).unwrap(),
            payload
        );
    }

    #[tokio::test]
    async fn desktop_commands_download_webdav_task_through_queue() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");
        let payload = b"fluxdown-desktop-webdav-e2e";
        let source = spawn_checked_http_server(payload, "/remote.php/dav/files/payload.bin");
        let address = server_address(&source);

        let task = enqueue_download(AddPayload {
            source: format!("webdav://{address}/remote.php/dav/files/payload.bin"),
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some("desktop-webdav.txt".to_string()),
            expected_sha256: None,
            torrent_file_indices: Vec::new(),
        ..Default::default()
}        )
        .await
        .unwrap();
        assert_eq!(task.protocol, Protocol::Webdav);

        let report = run_queue(1, Some(1), Some(1), None, Some(false))
            .await
            .unwrap();
        assert_eq!(report.started, 1);
        assert_eq!(report.finished, 1);
        assert_eq!(report.failed, 0);

        let tasks = list_downloads().await.unwrap();
        assert_eq!(tasks[0].state, DownloadState::Finished);
        assert_eq!(
            std::fs::read(output_dir.join("desktop-webdav.txt")).unwrap(),
            payload
        );
    }

    #[tokio::test]
    #[ignore = "requires a live local SFTP fixture; run scripts/verify-macos-desktop-sftp.sh"]
    async fn desktop_manual_downloads_sftp_task_through_queue() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");
        let source = manual_fixture(
            "FLUXDOWN_DESKTOP_SFTP_SOURCE",
            "scripts/verify-macos-desktop-sftp.sh",
        );
        let expected_name = manual_fixture(
            "FLUXDOWN_DESKTOP_SFTP_FILE_NAME",
            "scripts/verify-macos-desktop-sftp.sh",
        );
        let expected_sha256 = manual_fixture(
            "FLUXDOWN_DESKTOP_SFTP_SHA256",
            "scripts/verify-macos-desktop-sftp.sh",
        );

        let task = enqueue_download(AddPayload {
            source,
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some(expected_name.clone()),
            expected_sha256: None,
            torrent_file_indices: Vec::new(),
        ..Default::default()
}        )
        .await
        .unwrap();
        assert_eq!(task.protocol, Protocol::Sftp);

        let report = run_queue(1, Some(1), Some(1), None, Some(false))
            .await
            .unwrap();
        assert_eq!(report.started, 1);
        assert_eq!(report.finished, 1);
        assert_eq!(report.failed, 0);

        let tasks = list_downloads().await.unwrap();
        assert_eq!(tasks[0].state, DownloadState::Finished);
        assert_eq!(tasks[0].file_name.as_deref(), Some(expected_name.as_str()));
        let output_path = PathBuf::from(task_output_path(tasks[0].id.clone()).await.unwrap());
        // 作者: long
        // SFTP 是远程登录文件传输场景，桌面队列必须通过真实服务落盘，才能证明保存路径和属性面板路径可用。
        assert_eq!(sha256_file(&output_path), expected_sha256);
    }

    #[tokio::test]
    #[ignore = "requires a live local FTPS fixture; run scripts/verify-macos-desktop-ftps.sh"]
    async fn desktop_manual_downloads_ftps_task_through_queue() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");
        let source = manual_fixture(
            "FLUXDOWN_DESKTOP_FTPS_SOURCE",
            "scripts/verify-macos-desktop-ftps.sh",
        );
        let expected_name = manual_fixture(
            "FLUXDOWN_DESKTOP_FTPS_FILE_NAME",
            "scripts/verify-macos-desktop-ftps.sh",
        );
        let expected_sha256 = manual_fixture(
            "FLUXDOWN_DESKTOP_FTPS_SHA256",
            "scripts/verify-macos-desktop-ftps.sh",
        );

        let task = enqueue_download(AddPayload {
            source,
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some(expected_name.clone()),
            expected_sha256: None,
            torrent_file_indices: Vec::new(),
        ..Default::default()
}        )
        .await
        .unwrap();
        assert_eq!(task.protocol, Protocol::Ftps);

        let report = run_queue(1, Some(1), Some(1), None, Some(false))
            .await
            .unwrap();
        assert_eq!(report.started, 1);
        assert_eq!(report.finished, 1);
        assert_eq!(report.failed, 0);

        let tasks = list_downloads().await.unwrap();
        assert_eq!(tasks[0].state, DownloadState::Finished);
        assert_eq!(tasks[0].file_name.as_deref(), Some(expected_name.as_str()));
        let output_path = PathBuf::from(task_output_path(tasks[0].id.clone()).await.unwrap());
        // 作者: long
        // FTPS 队列必须覆盖加密控制连接和加密数据连接，确保桌面后端不是只验证了明文 FTP。
        assert_eq!(sha256_file(&output_path), expected_sha256);
    }

    #[tokio::test]
    #[ignore = "requires a live local Samba fixture; run scripts/verify-macos-desktop-smb.sh"]
    async fn desktop_manual_downloads_smb_task_through_queue() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");
        let source = manual_fixture(
            "FLUXDOWN_DESKTOP_SMB_SOURCE",
            "scripts/verify-macos-desktop-smb.sh",
        );
        let expected_name = manual_fixture(
            "FLUXDOWN_DESKTOP_SMB_FILE_NAME",
            "scripts/verify-macos-desktop-smb.sh",
        );
        let expected_sha256 = manual_fixture(
            "FLUXDOWN_DESKTOP_SMB_SHA256",
            "scripts/verify-macos-desktop-smb.sh",
        );

        let task = enqueue_download(AddPayload {
            source,
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some(expected_name.clone()),
            expected_sha256: None,
            torrent_file_indices: Vec::new(),
        ..Default::default()
}        )
        .await
        .unwrap();
        assert_eq!(task.protocol, Protocol::Smb);

        let report = run_queue(1, Some(1), Some(1), None, Some(false))
            .await
            .unwrap();
        assert_eq!(report.started, 1);
        assert_eq!(report.finished, 1);
        assert_eq!(report.failed, 0);

        let tasks = list_downloads().await.unwrap();
        assert_eq!(tasks[0].state, DownloadState::Finished);
        assert_eq!(tasks[0].file_name.as_deref(), Some(expected_name.as_str()));
        let output_path = PathBuf::from(task_output_path(tasks[0].id.clone()).await.unwrap());
        // 作者: long
        // SMB 是内网文件共享场景，桌面队列必须通过真实 Samba 服务落盘，才能证明保存路径和属性面板路径可用。
        assert_eq!(sha256_file(&output_path), expected_sha256);
    }

    #[tokio::test]
    #[ignore = "requires a live local tracker and seeder; use scripts/verify-macos-desktop-p2p.sh"]
    async fn desktop_manual_downloads_single_file_torrent_through_queue() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");
        let source = manual_fixture(
            "FLUXDOWN_DESKTOP_P2P_TORRENT",
            "scripts/verify-macos-desktop-p2p.sh",
        );
        let expected_name = manual_fixture(
            "FLUXDOWN_DESKTOP_P2P_FILE_NAME",
            "scripts/verify-macos-desktop-p2p.sh",
        );
        let expected_sha256 = manual_fixture(
            "FLUXDOWN_DESKTOP_P2P_SHA256",
            "scripts/verify-macos-desktop-p2p.sh",
        );

        let task = enqueue_download(AddPayload {
            source,
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some("queued-sample.torrent".to_string()),
            expected_sha256: None,
            torrent_file_indices: Vec::new(),
        ..Default::default()
}        )
        .await
        .unwrap();
        assert_eq!(task.protocol, Protocol::Torrent);

        let report = run_queue(1, Some(1), Some(1), None, Some(false))
            .await
            .unwrap();
        assert_eq!(report.started, 1);
        assert_eq!(report.finished, 1);
        assert_eq!(report.failed, 0);

        let tasks = list_downloads().await.unwrap();
        assert_eq!(tasks[0].state, DownloadState::Finished);
        assert_eq!(tasks[0].file_name.as_deref(), Some(expected_name.as_str()));
        let output_path = PathBuf::from(task_output_path(tasks[0].id.clone()).await.unwrap());
        assert_eq!(
            output_path.file_name().and_then(|name| name.to_str()),
            Some(expected_name.as_str())
        );
        // 作者: long
        // Torrent metadata 到达后必须把任务卡片名从 .torrent 临时名更新为真实文件名，打开文件也要指向真实产物。
        assert_eq!(sha256_file(&output_path), expected_sha256);
    }

    #[tokio::test]
    #[ignore = "requires a live local tracker and seeder; use scripts/verify-macos-desktop-p2p.sh"]
    async fn desktop_manual_starts_single_file_magnet_task() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");
        let source = manual_fixture(
            "FLUXDOWN_DESKTOP_P2P_MAGNET",
            "scripts/verify-macos-desktop-p2p.sh",
        );
        let expected_name = manual_fixture(
            "FLUXDOWN_DESKTOP_P2P_FILE_NAME",
            "scripts/verify-macos-desktop-p2p.sh",
        );
        let expected_sha256 = manual_fixture(
            "FLUXDOWN_DESKTOP_P2P_SHA256",
            "scripts/verify-macos-desktop-p2p.sh",
        );

        let task = enqueue_download(AddPayload {
            source,
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some("magnet-download".to_string()),
            expected_sha256: None,
            torrent_file_indices: Vec::new(),
        ..Default::default()
}        )
        .await
        .unwrap();
        assert_eq!(task.protocol, Protocol::Magnet);

        let report = start_download(
            task.id.clone(),
            Some(1),
            Some(1),
            Some(1),
            None,
            Some(false),
        )
        .await
        .unwrap();
        assert_eq!(report.task.state, DownloadState::Finished);
        assert_eq!(
            report.task.file_name.as_deref(),
            Some(expected_name.as_str())
        );

        let output_path = PathBuf::from(task_output_path(task.id.clone()).await.unwrap());
        assert_eq!(
            output_path.file_name().and_then(|name| name.to_str()),
            Some(expected_name.as_str())
        );
        // 作者: long
        // Magnet 初始没有文件名，metadata 到达后要回写真实产物名，避免桌面列表长期显示 magnet-download。
        assert_eq!(sha256_file(&output_path), expected_sha256);
    }

    #[tokio::test]
    #[ignore = "requires a live local tracker and seeder; use scripts/verify-macos-desktop-p2p.sh"]
    async fn desktop_manual_downloads_selected_torrent_file_through_queue() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");
        let source = manual_fixture(
            "FLUXDOWN_DESKTOP_P2P_MULTI_TORRENT",
            "scripts/verify-macos-desktop-p2p.sh",
        );
        let root = manual_fixture(
            "FLUXDOWN_DESKTOP_P2P_MULTI_ROOT",
            "scripts/verify-macos-desktop-p2p.sh",
        );
        let selected_name = manual_fixture(
            "FLUXDOWN_DESKTOP_P2P_SELECTED_NAME",
            "scripts/verify-macos-desktop-p2p.sh",
        );
        let skipped_name = manual_fixture(
            "FLUXDOWN_DESKTOP_P2P_SKIPPED_NAME",
            "scripts/verify-macos-desktop-p2p.sh",
        );
        let selected_sha256 = manual_fixture(
            "FLUXDOWN_DESKTOP_P2P_SELECTED_SHA256",
            "scripts/verify-macos-desktop-p2p.sh",
        );

        let task = enqueue_download(AddPayload {
            source,
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some("selected-bundle.torrent".to_string()),
            expected_sha256: None,
            torrent_file_indices: vec![0],
        ..Default::default()
}        )
        .await
        .unwrap();
        assert_eq!(task.protocol, Protocol::Torrent);
        assert_eq!(task.torrent_file_indices, vec![0]);

        let report = run_queue(1, Some(1), Some(1), None, Some(false))
            .await
            .unwrap();
        assert_eq!(report.started, 1);
        assert_eq!(report.finished, 1);
        assert_eq!(report.failed, 0);

        let tasks = list_downloads().await.unwrap();
        assert_eq!(tasks[0].state, DownloadState::Finished);
        assert_eq!(tasks[0].file_name.as_deref(), Some(selected_name.as_str()));
        let output_path = PathBuf::from(task_output_path(tasks[0].id.clone()).await.unwrap());
        assert_eq!(
            output_path.file_name().and_then(|name| name.to_str()),
            Some(selected_name.as_str())
        );
        // 作者: long
        // 多文件种子选择只下载用户挑中的文件，任务卡片也必须展示最终真实文件名，而不是临时 .torrent 名。
        assert_eq!(sha256_file(&output_path), selected_sha256);
        let skipped_path = output_dir.join(root).join(skipped_name);
        assert!(
            !skipped_path.exists()
                || std::fs::metadata(&skipped_path)
                    .map(|metadata| metadata.len() == 0)
                    .unwrap_or(false),
            "unselected torrent file was written: {}",
            skipped_path.display()
        );
    }

    #[tokio::test]
    #[ignore = "requires a live local tracker and seeder; use scripts/verify-macos-desktop-p2p.sh"]
    async fn desktop_manual_downloads_selected_magnet_file_through_queue() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let output_dir = temp_dir.path().join("downloads");
        let source = manual_fixture(
            "FLUXDOWN_DESKTOP_P2P_MULTI_MAGNET",
            "scripts/verify-macos-desktop-p2p.sh",
        );
        let root = manual_fixture(
            "FLUXDOWN_DESKTOP_P2P_MULTI_ROOT",
            "scripts/verify-macos-desktop-p2p.sh",
        );
        let selected_name = manual_fixture(
            "FLUXDOWN_DESKTOP_P2P_SELECTED_NAME",
            "scripts/verify-macos-desktop-p2p.sh",
        );
        let skipped_name = manual_fixture(
            "FLUXDOWN_DESKTOP_P2P_SKIPPED_NAME",
            "scripts/verify-macos-desktop-p2p.sh",
        );
        let selected_sha256 = manual_fixture(
            "FLUXDOWN_DESKTOP_P2P_SELECTED_SHA256",
            "scripts/verify-macos-desktop-p2p.sh",
        );

        let task = enqueue_download(AddPayload {
            source,
            output_dir: output_dir.to_string_lossy().into_owned(),
            file_name: Some("selected-magnet".to_string()),
            expected_sha256: None,
            torrent_file_indices: vec![0],
        ..Default::default()
}        )
        .await
        .unwrap();
        assert_eq!(task.protocol, Protocol::Magnet);
        assert_eq!(task.torrent_file_indices, vec![0]);

        let report = run_queue(1, Some(1), Some(1), None, Some(false))
            .await
            .unwrap();
        assert_eq!(report.started, 1);
        assert_eq!(report.finished, 1);
        assert_eq!(report.failed, 0);

        let tasks = list_downloads().await.unwrap();
        assert_eq!(tasks[0].state, DownloadState::Finished);
        assert_eq!(tasks[0].file_name.as_deref(), Some(selected_name.as_str()));
        let output_path = PathBuf::from(task_output_path(tasks[0].id.clone()).await.unwrap());
        assert_eq!(
            output_path.file_name().and_then(|name| name.to_str()),
            Some(selected_name.as_str())
        );
        // 作者: long
        // 多文件 Magnet 初始只有 metadata hash，选中文件下载完成后仍要用真实文件名和真实落盘路径驱动任务卡片、打开和分享。
        assert_eq!(sha256_file(&output_path), selected_sha256);
        let skipped_path = output_dir.join(root).join(skipped_name);
        assert!(
            !skipped_path.exists()
                || std::fs::metadata(&skipped_path)
                    .map(|metadata| metadata.len() == 0)
                    .unwrap_or(false),
            "unselected magnet file was written: {}",
            skipped_path.display()
        );
    }

    fn sha256_file(path: &Path) -> String {
        let output = Command::new("shasum")
            .args(["-a", "256"])
            .arg(path)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout)
            .split_whitespace()
            .next()
            .unwrap()
            .to_string()
    }

    #[test]
    fn desktop_pause_resume_transitions_match_cli_boundaries() {
        assert_eq!(
            pause_transition(DownloadState::Queued).unwrap(),
            Some(DownloadState::Paused)
        );
        assert_eq!(
            pause_transition(DownloadState::Running).unwrap(),
            Some(DownloadState::Paused)
        );
        assert_eq!(pause_transition(DownloadState::Paused).unwrap(), None);
        assert!(pause_transition(DownloadState::Finished).is_err());
        assert!(pause_transition(DownloadState::Failed).is_err());

        assert_eq!(
            resume_transition(DownloadState::Paused).unwrap(),
            Some(DownloadState::Queued)
        );
        assert_eq!(resume_transition(DownloadState::Queued).unwrap(), None);
        assert!(resume_transition(DownloadState::Running).is_err());
        assert!(resume_transition(DownloadState::Finished).is_err());
        assert!(resume_transition(DownloadState::Failed).is_err());
    }

    #[test]
    fn desktop_runner_options_clamp_settings_to_product_limits() {
        let options = runner_options(Some(99), Some(99), Some(1.5), Some(true));

        assert_eq!(clamp_concurrency(0), 1);
        assert_eq!(clamp_concurrency(31), 30);
        assert_eq!(options.retry_attempts, 10);
        assert_eq!(options.download.thread_count, 32);
        assert_eq!(options.download.speed_limit_bps, Some(1_572_864));
        assert!(options.restart_existing);

        let unlimited = runner_options(Some(0), Some(0), Some(0.0), Some(false));
        assert_eq!(unlimited.retry_attempts, 0);
        assert_eq!(unlimited.download.thread_count, 1);
        assert_eq!(unlimited.download.speed_limit_bps, None);
        assert!(!unlimited.restart_existing);

        let defaults = runner_options(None, None, None, None);
        assert_eq!(defaults.retry_attempts, 1);
        assert_eq!(defaults.download.thread_count, 1);
        assert_eq!(defaults.download.speed_limit_bps, None);
        assert!(!defaults.restart_existing);
    }

    #[test]
    fn desktop_output_dir_resolution_keeps_settings_predictable() {
        let default_dir = default_output_dir_path();

        assert_eq!(resolve_output_dir(""), default_dir);
        assert_eq!(resolve_output_dir("./downloads"), default_dir);
        assert_eq!(resolve_output_dir("movies"), default_dir.join("movies"));

        if let Some(home) = home_dir() {
            assert_eq!(
                resolve_output_dir("~/FluxDownTest"),
                home.join("FluxDownTest")
            );
        }
    }

    #[tokio::test]
    async fn desktop_list_downloads_recovers_stale_running_tasks() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let store = TaskStore::new(default_store_path());
        let task = store
            .enqueue(DownloadRequest::new(
                "http://127.0.0.1:9/stale.bin",
                temp_dir.path(),
            ))
            .await
            .unwrap();
        let mut running_task = task;
        running_task.set_state(DownloadState::Running);
        running_task.set_progress_with_speed(512, Some(1024), 256);
        running_task.updated_at_ms = 0;
        store.update(running_task.clone()).await.unwrap();

        let listed = list_downloads().await.unwrap();
        let recovered = listed
            .iter()
            .find(|candidate| candidate.id == running_task.id)
            .unwrap();

        // 作者: long
        // 客户端启动后首先刷新列表；这里必须释放异常残留的 running 槽位，否则用户会看到无法继续调度的假下载中任务。
        assert_eq!(recovered.state, DownloadState::Paused);
        assert_eq!(recovered.downloaded_bytes, 512);
        assert_eq!(recovered.current_speed_bytes_per_second, 0);
        assert_eq!(
            recovered.error.as_deref(),
            Some("任务中断，已暂停，可继续下载")
        );
        assert_eq!(
            store.get(&running_task.id).await.unwrap().state,
            DownloadState::Paused
        );
    }

    #[tokio::test]
    async fn desktop_resume_download_recovers_stale_running_task_before_transition() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let store = TaskStore::new(default_store_path());
        let task = store
            .enqueue(DownloadRequest::new(
                "http://127.0.0.1:9/stale-resume.bin",
                temp_dir.path(),
            ))
            .await
            .unwrap();
        let mut running_task = task;
        running_task.set_state(DownloadState::Running);
        running_task.set_progress_with_speed(512, Some(2048), 512);
        running_task.updated_at_ms = 0;
        store.update(running_task.clone()).await.unwrap();

        let resumed = resume_download(running_task.id.clone()).await.unwrap();

        // 作者: long
        // 桌面继续按钮要能直接接管异常中断任务，避免用户先刷新列表才能把任务重新排队。
        assert_eq!(resumed.state, DownloadState::Queued);
        assert_eq!(resumed.downloaded_bytes, 512);
        assert_eq!(resumed.error, None);
        assert_eq!(
            store.get(&running_task.id).await.unwrap().state,
            DownloadState::Queued
        );
    }

    #[tokio::test]
    async fn desktop_pause_download_recovers_stale_running_task_before_transition() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let store = TaskStore::new(default_store_path());
        let task = store
            .enqueue(DownloadRequest::new(
                "http://127.0.0.1:9/stale-pause.bin",
                temp_dir.path(),
            ))
            .await
            .unwrap();
        let mut running_task = task;
        running_task.set_state(DownloadState::Running);
        running_task.set_progress_with_speed(768, Some(2048), 384);
        running_task.updated_at_ms = 0;
        store.update(running_task.clone()).await.unwrap();

        let paused = pause_download(running_task.id.clone()).await.unwrap();

        // 作者: long
        // 桌面暂停按钮也要能直接接管异常中断任务，避免旧 running 状态卡住队列调度。
        assert_eq!(paused.state, DownloadState::Paused);
        assert_eq!(paused.downloaded_bytes, 768);
        assert_eq!(
            paused.error.as_deref(),
            Some("任务中断，已暂停，可继续下载")
        );
        assert_eq!(
            store.get(&running_task.id).await.unwrap().state,
            DownloadState::Paused
        );
    }

    #[tokio::test]
    async fn desktop_remove_download_recovers_stale_running_task_before_removal() {
        let _guard = DESKTOP_COMMAND_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let _xdg_guard = EnvVarGuard::set("XDG_DATA_HOME", temp_dir.path().join("xdg"));
        let store = TaskStore::new(default_store_path());
        let task = store
            .enqueue(DownloadRequest::new(
                "http://127.0.0.1:9/stale-remove.bin",
                temp_dir.path(),
            ))
            .await
            .unwrap();
        let mut running_task = task;
        running_task.set_state(DownloadState::Running);
        running_task.set_progress_with_speed(896, Some(2048), 448);
        running_task.updated_at_ms = 0;
        store.update(running_task.clone()).await.unwrap();

        let removed = remove_download(running_task.id.clone()).await.unwrap();

        // 作者: long
        // 删除入口返回的是操作结果；陈旧 running 要先恢复成中断态，再从队列移除，避免 UI 继续显示假运行。
        assert_eq!(removed.state, DownloadState::Paused);
        assert_eq!(removed.downloaded_bytes, 896);
        assert_eq!(
            removed.error.as_deref(),
            Some("任务中断，已暂停，可继续下载")
        );
        assert!(list_downloads().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn direct_start_defers_queued_task_when_capacity_is_full() {
        let temp_dir = tempfile::tempdir().unwrap();
        let store = TaskStore::new(temp_dir.path().join("queue.json"));
        let running = store
            .enqueue(DownloadRequest::new(
                "http://127.0.0.1:9/running.bin",
                temp_dir.path(),
            ))
            .await
            .unwrap();
        let queued = store
            .enqueue(DownloadRequest::new(
                "http://127.0.0.1:9/queued.bin",
                temp_dir.path(),
            ))
            .await
            .unwrap();
        let mut running_task = running;
        running_task.set_state(DownloadState::Running);
        store.update(running_task).await.unwrap();

        let deferred = defer_direct_start_when_capacity_full(&store, queued, Some(1), false)
            .await
            .unwrap()
            .unwrap();

        assert_eq!(deferred.state, DownloadState::Queued);
    }

    #[tokio::test]
    async fn direct_start_requeues_paused_task_when_capacity_is_full() {
        let temp_dir = tempfile::tempdir().unwrap();
        let store = TaskStore::new(temp_dir.path().join("queue.json"));
        let running = store
            .enqueue(DownloadRequest::new(
                "http://127.0.0.1:9/running.bin",
                temp_dir.path(),
            ))
            .await
            .unwrap();
        let paused = store
            .enqueue(DownloadRequest::new(
                "http://127.0.0.1:9/paused.bin",
                temp_dir.path(),
            ))
            .await
            .unwrap();
        let mut running_task = running;
        running_task.set_state(DownloadState::Running);
        store.update(running_task).await.unwrap();
        store
            .set_state(&paused.id, DownloadState::Paused)
            .await
            .unwrap();
        let paused = store.get(&paused.id).await.unwrap();

        let deferred = defer_direct_start_when_capacity_full(&store, paused, Some(1), false)
            .await
            .unwrap()
            .unwrap();

        assert_eq!(deferred.state, DownloadState::Queued);
        assert_eq!(
            store.get(&deferred.id).await.unwrap().state,
            DownloadState::Queued
        );
    }

    #[tokio::test]
    async fn direct_start_allows_task_when_capacity_is_available() {
        let temp_dir = tempfile::tempdir().unwrap();
        let store = TaskStore::new(temp_dir.path().join("queue.json"));
        let task = store
            .enqueue(DownloadRequest::new(
                "http://127.0.0.1:9/queued.bin",
                temp_dir.path(),
            ))
            .await
            .unwrap();

        let deferred = defer_direct_start_when_capacity_full(&store, task, Some(1), false)
            .await
            .unwrap();

        assert!(deferred.is_none());
    }
}
