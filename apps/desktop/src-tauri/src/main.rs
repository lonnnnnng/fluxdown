use fluxdown_core::{
    DoctorReport, DownloadRequest, DownloadState, DownloadTask, Protocol, QueueRunReport,
    QueueRunner, RuntimeSupportStatus, TaskRunReport, TaskStore, default_store_path,
    detect_protocol, doctor_report, runtime_support_status,
};
use serde::Deserialize;
use std::path::PathBuf;

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
fn plan_download(source: String, output_dir: String) -> DownloadTask {
    DownloadTask::from_request(DownloadRequest::new(source, PathBuf::from(output_dir)))
}

#[tauri::command]
async fn enqueue_download(payload: AddPayload) -> Result<DownloadTask, String> {
    let mut request = DownloadRequest::new(payload.source, PathBuf::from(payload.output_dir));
    request.file_name = payload.file_name;
    TaskStore::new(default_store_path())
        .enqueue(request)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn list_downloads() -> Result<Vec<DownloadTask>, String> {
    TaskStore::new(default_store_path())
        .list()
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
async fn start_download(id: String) -> Result<TaskRunReport, String> {
    QueueRunner::new(TaskStore::new(default_store_path()))
        .run_task(&id)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn run_queue(concurrency: usize) -> Result<QueueRunReport, String> {
    QueueRunner::new(TaskStore::new(default_store_path()))
        .run_queued(concurrency)
        .await
        .map_err(|error| error.to_string())
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            detect,
            support,
            doctor,
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
