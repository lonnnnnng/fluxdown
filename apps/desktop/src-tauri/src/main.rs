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
};

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
    TaskStore::new(default_store_path())
        .set_state(&id, DownloadState::Paused)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn resume_download(id: String) -> Result<DownloadTask, String> {
    TaskStore::new(default_store_path())
        .set_state(&id, DownloadState::Queued)
        .await
        .map_err(|error| error.to_string())
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
    retry_attempts: Option<usize>,
    thread_count: Option<usize>,
    speed_limit_mbps: Option<f64>,
    restart_existing: Option<bool>,
) -> Result<TaskRunReport, String> {
    let store = TaskStore::new(default_store_path());
    migrate_download_paths(&store)
        .await
        .map_err(|error| error.to_string())?;
    QueueRunner::new(store)
        .run_task_with_options(
            &id,
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
