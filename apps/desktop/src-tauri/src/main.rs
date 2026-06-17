use fluxdown_core::{
    DoctorReport, DownloadOptions, DownloadRequest, DownloadState, DownloadTask, Protocol,
    QueueRunReport, QueueRunner, QueueRunnerOptions, RuntimeSupportStatus, TaskRunReport,
    TaskStore, default_store_path, detect_protocol, doctor_report, runtime_support_status,
};
use serde::Deserialize;
use std::{
    env,
    path::{Path, PathBuf},
    process::Command,
    time::Duration,
};

const STALE_RUNNING_TASK_TIMEOUT: Duration = Duration::from_secs(5 * 60);

#[derive(Debug, Deserialize)]
struct AddPayload {
    source: String,
    output_dir: String,
    file_name: Option<String>,
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
    TaskStore::new(default_store_path())
        .enqueue(request)
        .await
        .map_err(|error| error.to_string())
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
    TaskStore::new(default_store_path())
        .remove(&id)
        .await
        .map_err(|error| error.to_string())
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
            concurrency,
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
        retry_attempts: retry_attempts.unwrap_or(0).min(10),
        download: DownloadOptions::new(
            thread_count.unwrap_or(1).clamp(1, 32),
            speed_limit_mbps_to_bps(speed_limit_mbps),
        ),
        restart_existing: restart_existing.unwrap_or(false),
    }
}

fn speed_limit_mbps_to_bps(speed_limit_mbps: Option<f64>) -> Option<u64> {
    speed_limit_mbps
        .filter(|value| value.is_finite() && *value > 0.0)
        .map(|value| (value * 1024.0 * 1024.0).round() as u64)
        .filter(|value| *value > 0)
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

    let concurrency = concurrency.unwrap_or(1).clamp(1, 30);
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
            .map(|file_name| output_dir.join(file_name))
            .filter(|path| path.exists())
            .unwrap_or(output_dir);
    }

    let file_name = task
        .file_name
        .clone()
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

fn inferred_file_name_from_source(source: &str) -> String {
    source
        .rsplit('/')
        .next()
        .and_then(|segment| segment.split('?').next())
        .filter(|segment| !segment.is_empty())
        .unwrap_or("download.bin")
        .to_string()
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
    if let Some(rest) = value.strip_prefix("~/") {
        if let Some(home) = home_dir() {
            return home.join(rest);
        }
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

#[cfg(test)]
mod tests {
    use super::*;

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

fn main() {
    tauri::Builder::default()
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
            run_queue
        ])
        .run(tauri::generate_context!())
        .expect("error while running FluxDown desktop app");
}
