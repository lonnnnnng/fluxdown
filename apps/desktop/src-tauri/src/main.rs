use fluxdown_core::{
    DoctorReport, DownloadRequest, DownloadState, DownloadTask, Protocol, QueueRunReport,
    QueueRunner, QueueRunnerOptions, RuntimeSupportStatus, TaskRunReport, TaskStore,
    default_store_path, detect_protocol, doctor_report, runtime_support_status,
};
use serde::Deserialize;
use std::{
    env,
    path::{Path, PathBuf},
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
async fn start_download(
    id: String,
    retry_attempts: Option<usize>,
) -> Result<TaskRunReport, String> {
    let store = TaskStore::new(default_store_path());
    migrate_download_paths(&store)
        .await
        .map_err(|error| error.to_string())?;
    QueueRunner::new(store)
        .run_task_with_options(&id, runner_options(retry_attempts))
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn run_queue(
    concurrency: usize,
    retry_attempts: Option<usize>,
) -> Result<QueueRunReport, String> {
    let store = TaskStore::new(default_store_path());
    migrate_download_paths(&store)
        .await
        .map_err(|error| error.to_string())?;
    QueueRunner::new(store)
        .run_queued_with_options(concurrency, runner_options(retry_attempts))
        .await
        .map_err(|error| error.to_string())
}

fn runner_options(retry_attempts: Option<usize>) -> QueueRunnerOptions {
    QueueRunnerOptions {
        retry_attempts: retry_attempts.unwrap_or(0).min(10),
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
            start_download,
            run_queue
        ])
        .run(tauri::generate_context!())
        .expect("error while running FluxDown desktop app");
}
