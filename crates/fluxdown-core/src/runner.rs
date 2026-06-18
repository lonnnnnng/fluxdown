use crate::{
    CancelToken, DownloadEngine, DownloadError, DownloadOptions, DownloadProgress, DownloadState,
    DownloadTask, Protocol, TaskStore, TaskStoreError,
};
use futures_util::stream::{self, StreamExt};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};
use thiserror::Error;
use tokio::sync::{Mutex, mpsc};

const STALE_RUNNING_TASK_TIMEOUT: Duration = Duration::from_secs(5 * 60);

#[derive(Debug, Error)]
pub enum QueueRunnerError {
    #[error(transparent)]
    Store(#[from] TaskStoreError),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskRunReport {
    pub task: DownloadTask,
    pub summary: Option<crate::DownloadSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueueRunReport {
    pub total_queued: usize,
    pub started: usize,
    pub finished: usize,
    pub failed: usize,
    pub tasks: Vec<DownloadTask>,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct QueueRunnerOptions {
    pub retry_attempts: usize,
    pub download: DownloadOptions,
    pub restart_existing: bool,
}

#[derive(Debug, Clone)]
pub struct QueueRunner {
    store: TaskStore,
    engine: DownloadEngine,
}

impl QueueRunner {
    pub fn new(store: TaskStore) -> Self {
        Self {
            store,
            engine: DownloadEngine::new(),
        }
    }

    pub async fn run_queued(&self, concurrency: usize) -> Result<QueueRunReport, QueueRunnerError> {
        self.run_queued_with_options(concurrency, QueueRunnerOptions::default())
            .await
    }

    pub async fn run_queued_with_options(
        &self,
        concurrency: usize,
        options: QueueRunnerOptions,
    ) -> Result<QueueRunReport, QueueRunnerError> {
        let concurrency = concurrency.max(1);
        self.store
            .recover_stale_running(STALE_RUNNING_TASK_TIMEOUT)
            .await?;
        let tasks = self.store.list().await?;
        // 作者: long
        // 并发下载数约束的是全局正在执行的任务数量，已经运行的任务必须先占用槽位，新任务才会老实排队。
        let running = tasks
            .iter()
            .filter(|task| task.state == DownloadState::Running)
            .count();
        let queued = tasks
            .into_iter()
            .filter(|task| task.state == DownloadState::Queued)
            .collect::<Vec<_>>();
        let total_queued = queued.len();
        let available_slots = concurrency.saturating_sub(running);

        if available_slots == 0 {
            return Ok(QueueRunReport {
                total_queued,
                started: 0,
                finished: 0,
                failed: 0,
                tasks: Vec::new(),
            });
        }

        let write_lock = Arc::new(Mutex::new(()));
        let results = stream::iter(queued)
            .map(|task| {
                let store = self.store.clone();
                let engine = self.engine.clone();
                let write_lock = Arc::clone(&write_lock);
                async move {
                    run_one_with_retry(store, engine, task, write_lock, options)
                        .await
                        .map(|report| report.task)
                }
            })
            .buffer_unordered(available_slots)
            .collect::<Vec<_>>()
            .await;

        let mut tasks = Vec::with_capacity(results.len());
        let mut finished = 0;
        let mut failed = 0;

        for result in results {
            let task = result?;
            match task.state {
                DownloadState::Finished => finished += 1,
                DownloadState::Failed => failed += 1,
                _ => {}
            }
            tasks.push(task);
        }

        Ok(QueueRunReport {
            total_queued,
            started: tasks.len(),
            finished,
            failed,
            tasks,
        })
    }

    pub async fn run_task(&self, id: &str) -> Result<TaskRunReport, QueueRunnerError> {
        self.run_task_with_options(id, QueueRunnerOptions::default())
            .await
    }

    pub async fn run_task_with_options(
        &self,
        id: &str,
        options: QueueRunnerOptions,
    ) -> Result<TaskRunReport, QueueRunnerError> {
        self.store
            .recover_stale_running(STALE_RUNNING_TASK_TIMEOUT)
            .await?;
        let task = self.store.get(id).await?;
        if !options.restart_existing
            && matches!(task.state, DownloadState::Finished | DownloadState::Running)
        {
            return Ok(TaskRunReport {
                task,
                summary: None,
            });
        }
        run_one_with_retry(
            self.store.clone(),
            self.engine.clone(),
            task,
            Arc::new(Mutex::new(())),
            options,
        )
        .await
    }
}

async fn run_one_with_retry(
    store: TaskStore,
    engine: DownloadEngine,
    mut task: DownloadTask,
    write_lock: Arc<Mutex<()>>,
    options: QueueRunnerOptions,
) -> Result<TaskRunReport, QueueRunnerError> {
    let max_attempts = options.retry_attempts.saturating_add(1);
    if options.restart_existing {
        remove_existing_outputs(&task).await;
        task.reset_for_restart();
    }
    for attempt in 0..max_attempts {
        let report = run_one(
            store.clone(),
            engine.clone(),
            task,
            Arc::clone(&write_lock),
            options.download,
        )
        .await?;

        if report.task.state != DownloadState::Failed || attempt + 1 >= max_attempts {
            return Ok(report);
        }

        task = report.task;
        task.error = None;
    }

    unreachable!("retry loop always returns after the final attempt")
}

async fn run_one(
    store: TaskStore,
    engine: DownloadEngine,
    mut task: DownloadTask,
    write_lock: Arc<Mutex<()>>,
    download_options: DownloadOptions,
) -> Result<TaskRunReport, QueueRunnerError> {
    task.set_state(DownloadState::Running);
    {
        let _guard = write_lock.lock().await;
        store.update(task.clone()).await?;
    }

    let cancel = CancelToken::default();
    let (progress_tx, mut progress_rx) = mpsc::unbounded_channel::<DownloadProgress>();
    let progress_task = {
        let store = store.clone();
        let write_lock = Arc::clone(&write_lock);
        let mut progress_task = task.clone();
        let cancel = cancel.clone();
        tokio::spawn(async move {
            let mut last_persist = Instant::now() - Duration::from_millis(500);
            let mut last_speed_sample_at = Instant::now();
            let mut last_speed_sample_bytes = 0_u64;
            while let Some(progress) = progress_rx.recv().await {
                progress_task.set_progress(progress.downloaded_bytes, progress.total_bytes);
                if progress.downloaded_bytes == 0 {
                    continue;
                }
                if last_persist.elapsed() < Duration::from_millis(250) {
                    continue;
                }
                last_persist = Instant::now();
                let _guard = write_lock.lock().await;
                if let Ok(current) = store.get(&progress_task.id).await {
                    if current.state == DownloadState::Paused {
                        cancel.cancel();
                        continue;
                    }
                }
                let speed_elapsed = last_speed_sample_at.elapsed();
                let current_speed = if speed_elapsed.is_zero() {
                    0
                } else {
                    let delta = progress_task
                        .downloaded_bytes
                        .saturating_sub(last_speed_sample_bytes);
                    (delta as f64 / speed_elapsed.as_secs_f64()).round() as u64
                };
                last_speed_sample_at = Instant::now();
                last_speed_sample_bytes = progress_task.downloaded_bytes;
                match store
                    .set_progress_if_running(
                        &progress_task.id,
                        progress_task.downloaded_bytes,
                        progress_task.total_bytes,
                        current_speed,
                    )
                    .await
                {
                    Ok(Some(updated)) => {
                        progress_task = updated;
                    }
                    Ok(None) => {
                        cancel.cancel();
                    }
                    Err(_) => {}
                }
            }
        })
    };
    let cancel_task = {
        let store = store.clone();
        let task_id = task.id.clone();
        let cancel = cancel.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_millis(200));
            loop {
                interval.tick().await;
                if cancel.is_cancelled() {
                    break;
                }
                match store.get(&task_id).await {
                    Ok(current) if current.state == DownloadState::Paused => {
                        cancel.cancel();
                        break;
                    }
                    Err(TaskStoreError::NotFound(_)) => {
                        cancel.cancel();
                        break;
                    }
                    _ => {}
                }
            }
        })
    };

    let progress_callback = {
        let progress_tx = progress_tx.clone();
        Arc::new(move |progress: DownloadProgress| {
            let _ = progress_tx.send(progress);
        }) as Arc<dyn Fn(DownloadProgress) + Send + Sync>
    };

    let summary = match engine
        .download_with_control_and_options(
            task.request(),
            Some(progress_callback),
            Some(cancel),
            download_options,
        )
        .await
    {
        Ok(summary) => {
            if let Some(display_name) = summary.display_name.clone() {
                // 作者: long
                // 下载完成后以核心下载器确认的真实产物名刷新任务卡片，Torrent/Magnet 不再停留在种子文件名或 magnet-download。
                task.file_name = Some(display_name);
            }
            task.set_state(DownloadState::Finished);
            task.set_progress(summary.bytes_written, summary.total_bytes);
            task.error = None;
            Some(summary)
        }
        Err(DownloadError::Paused) => {
            if let Ok(current) = store.get(&task.id).await {
                task = current;
            }
            task.set_state(DownloadState::Paused);
            if let Some(size) = partial_file_size(&task).await {
                task.set_progress(size, task.total_bytes);
            }
            task.error = None;
            None
        }
        Err(error) => {
            task.fail(error.to_string());
            None
        }
    };

    drop(progress_tx);
    let _ = progress_task.await;
    cancel_task.abort();

    let _guard = write_lock.lock().await;
    // 作者: long
    // 用户删除运行中任务时，删除动作本身就是取消并移出队列；下载协程收尾不能把任务重新写回，也不能让队列运行因为 NotFound 失败。
    let task = match store.update(task.clone()).await {
        Ok(task) => task,
        Err(TaskStoreError::NotFound(_)) => task,
        Err(error) => return Err(error.into()),
    };
    Ok(TaskRunReport { task, summary })
}

async fn partial_file_size(task: &DownloadTask) -> Option<u64> {
    for path in output_file_candidates(task) {
        if let Ok(metadata) = tokio::fs::metadata(path).await
            && metadata.is_file()
        {
            return Some(metadata.len());
        }
    }
    None
}

async fn remove_existing_outputs(task: &DownloadTask) {
    for path in output_file_candidates(task) {
        if path.is_file() {
            let _ = tokio::fs::remove_file(path).await;
        }
    }
}

fn output_file_candidates(task: &DownloadTask) -> Vec<PathBuf> {
    let file_name = task.file_name.clone().unwrap_or_else(|| {
        task.source
            .split('?')
            .next()
            .unwrap_or(&task.source)
            .rsplit('/')
            .next()
            .filter(|segment| !segment.is_empty())
            .unwrap_or("download.bin")
            .to_string()
    });
    let primary = task.output_dir.join(&file_name);
    let mut candidates = Vec::new();
    match task.protocol {
        Protocol::M3u8 => {
            let base = PathBuf::from(&file_name);
            candidates.push(task.output_dir.join(base.with_extension("mp4")));
            candidates.push(
                task.output_dir
                    .join(PathBuf::from(&file_name).with_extension("ts")),
            );
        }
        Protocol::Torrent | Protocol::Magnet => {
            if task.file_name.is_some() {
                candidates.push(primary.clone());
            }
        }
        _ => candidates.push(primary.clone()),
    }
    candidates.push(range_temp_output_path(&primary));
    candidates
}

fn range_temp_output_path(output_path: &PathBuf) -> PathBuf {
    let file_name = output_path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("download.bin");
    output_path.with_file_name(format!(".{file_name}.part"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::DownloadRequest;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    #[tokio::test]
    async fn run_empty_queue() {
        let path =
            std::env::temp_dir().join(format!("fluxdown-runner-{}.json", uuid::Uuid::new_v4()));
        let store = TaskStore::new(&path);
        let report = QueueRunner::new(store).run_queued(2).await.unwrap();
        assert_eq!(report.total_queued, 0);
        assert_eq!(report.started, 0);
        let _ = tokio::fs::remove_file(path).await;
    }

    #[tokio::test]
    async fn run_queue_respects_already_running_tasks() {
        let path =
            std::env::temp_dir().join(format!("fluxdown-runner-{}.json", uuid::Uuid::new_v4()));
        let store = TaskStore::new(&path);
        let running = store
            .enqueue(DownloadRequest::new(
                "http://127.0.0.1:9/running.bin",
                "/tmp",
            ))
            .await
            .unwrap();
        let queued = store
            .enqueue(DownloadRequest::new(
                "http://127.0.0.1:9/queued.bin",
                "/tmp",
            ))
            .await
            .unwrap();
        let mut running_task = running.clone();
        running_task.set_state(DownloadState::Running);
        store.update(running_task).await.unwrap();

        let report = QueueRunner::new(store.clone()).run_queued(1).await.unwrap();
        let still_queued = store.get(&queued.id).await.unwrap();

        assert_eq!(report.total_queued, 1);
        assert_eq!(report.started, 0);
        assert_eq!(still_queued.state, DownloadState::Queued);
        let _ = tokio::fs::remove_file(path).await;
    }

    #[tokio::test]
    async fn run_queue_recovers_stale_running_tasks_before_scheduling() {
        let path =
            std::env::temp_dir().join(format!("fluxdown-runner-{}.json", uuid::Uuid::new_v4()));
        let store = TaskStore::new(&path);
        let running = store
            .enqueue(DownloadRequest::new("http://127.0.0.1:9/stale.bin", "/tmp"))
            .await
            .unwrap();
        store
            .enqueue(DownloadRequest::new("unknown://example", "/tmp"))
            .await
            .unwrap();
        let mut running_task = running.clone();
        running_task.set_state(DownloadState::Running);
        running_task.updated_at_ms = running_task.updated_at_ms.saturating_sub(10 * 60 * 1000);
        store.update(running_task).await.unwrap();

        let report = QueueRunner::new(store.clone()).run_queued(1).await.unwrap();
        let recovered = store.get(&running.id).await.unwrap();

        assert_eq!(report.total_queued, 1);
        assert_eq!(report.started, 1);
        assert_eq!(report.failed, 1);
        assert_eq!(recovered.state, DownloadState::Paused);
        assert!(recovered.error.unwrap().contains("任务中断"));
        let _ = tokio::fs::remove_file(path).await;
    }

    #[tokio::test]
    async fn marks_unsupported_task_failed() {
        let path =
            std::env::temp_dir().join(format!("fluxdown-runner-{}.json", uuid::Uuid::new_v4()));
        let store = TaskStore::new(&path);
        store
            .enqueue(DownloadRequest::new("unknown://example", "/tmp"))
            .await
            .unwrap();

        let report = QueueRunner::new(store.clone()).run_queued(1).await.unwrap();
        assert_eq!(report.total_queued, 1);
        assert_eq!(report.failed, 1);
        assert_eq!(store.list().await.unwrap()[0].state, DownloadState::Failed);
        let _ = tokio::fs::remove_file(path).await;
    }

    #[tokio::test]
    async fn run_task_persists_progress_and_respects_pause() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut buffer = [0; 1024];
            let _ = stream.read(&mut buffer).await;

            let chunk = vec![b'x'; 8192];
            let chunks = 80;
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                chunk.len() * chunks
            );
            stream.write_all(response.as_bytes()).await.unwrap();
            for _ in 0..chunks {
                if stream.write_all(&chunk).await.is_err() {
                    break;
                }
                let _ = stream.flush().await;
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        });

        let temp_dir = tempfile::tempdir().unwrap();
        let store = TaskStore::new(temp_dir.path().join("queue.json"));
        let task = store
            .enqueue(DownloadRequest::new(
                format!("http://{address}/slow.bin"),
                temp_dir.path().join("downloads"),
            ))
            .await
            .unwrap();

        let runner = QueueRunner::new(store.clone());
        let task_id = task.id.clone();
        let run = tokio::spawn(async move { runner.run_task(&task_id).await.unwrap() });

        wait_for_progress(&store, &task.id).await;
        assert!(
            store
                .get(&task.id)
                .await
                .unwrap()
                .current_speed_bytes_per_second
                > 0
        );
        store
            .set_state(&task.id, DownloadState::Paused)
            .await
            .unwrap();

        let report = tokio::time::timeout(Duration::from_secs(5), run)
            .await
            .unwrap()
            .unwrap();

        assert_eq!(report.task.state, DownloadState::Paused);
        assert!(report.task.downloaded_bytes > 0);
        assert_eq!(report.task.current_speed_bytes_per_second, 0);
        assert!(report.task.started_at_ms.is_some());
        assert_eq!(report.task.finished_at_ms, None);
        assert!(report.summary.is_none());

        server.abort();
    }

    #[tokio::test]
    async fn restart_existing_removes_old_output_before_download() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut buffer = [0; 1024];
            let read = stream.read(&mut buffer).await.unwrap();
            let request = String::from_utf8_lossy(&buffer[..read]);
            assert!(!request.to_ascii_lowercase().contains("range:"));

            let payload = b"fresh restart payload";
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                payload.len()
            );
            stream.write_all(response.as_bytes()).await.unwrap();
            stream.write_all(payload).await.unwrap();
        });

        let temp_dir = tempfile::tempdir().unwrap();
        let output_dir = temp_dir.path().join("downloads");
        tokio::fs::create_dir_all(&output_dir).await.unwrap();
        tokio::fs::write(output_dir.join("file.bin"), b"stale complete file")
            .await
            .unwrap();
        let store = TaskStore::new(temp_dir.path().join("queue.json"));
        let mut request = DownloadRequest::new(format!("http://{address}/file.bin"), &output_dir);
        request.file_name = Some("file.bin".to_string());
        let task = store.enqueue(request).await.unwrap();

        let report = QueueRunner::new(store)
            .run_task_with_options(
                &task.id,
                QueueRunnerOptions {
                    restart_existing: true,
                    ..Default::default()
                },
            )
            .await
            .unwrap();

        assert_eq!(report.task.state, DownloadState::Finished);
        assert!(report.task.started_at_ms.is_some());
        assert!(report.task.finished_at_ms >= report.task.started_at_ms);
        assert_eq!(
            tokio::fs::read(output_dir.join("file.bin")).await.unwrap(),
            b"fresh restart payload"
        );
        server.await.unwrap();
    }

    #[tokio::test]
    async fn start_finished_task_without_restart_is_noop() {
        let temp_dir = tempfile::tempdir().unwrap();
        let store = TaskStore::new(temp_dir.path().join("queue.json"));
        let task = store
            .enqueue(DownloadRequest::new(
                "http://127.0.0.1:9/finished.bin",
                temp_dir.path().join("downloads"),
            ))
            .await
            .unwrap();
        let mut finished = task.clone();
        finished.set_state(DownloadState::Finished);
        finished.set_progress(100, Some(100));
        store.update(finished.clone()).await.unwrap();

        let report = QueueRunner::new(store.clone())
            .run_task_with_options(&task.id, QueueRunnerOptions::default())
            .await
            .unwrap();
        let persisted = store.get(&task.id).await.unwrap();

        assert!(report.summary.is_none());
        assert_eq!(report.task.state, DownloadState::Finished);
        assert_eq!(persisted.state, DownloadState::Finished);
        assert_eq!(persisted.downloaded_bytes, 100);
    }

    #[tokio::test]
    async fn start_running_task_without_restart_is_noop() {
        let temp_dir = tempfile::tempdir().unwrap();
        let store = TaskStore::new(temp_dir.path().join("queue.json"));
        let task = store
            .enqueue(DownloadRequest::new(
                "http://127.0.0.1:9/running.bin",
                temp_dir.path().join("downloads"),
            ))
            .await
            .unwrap();
        let mut running = task.clone();
        running.set_state(DownloadState::Running);
        store.update(running).await.unwrap();

        let report = QueueRunner::new(store.clone())
            .run_task_with_options(&task.id, QueueRunnerOptions::default())
            .await
            .unwrap();
        let persisted = store.get(&task.id).await.unwrap();

        assert!(report.summary.is_none());
        assert_eq!(report.task.state, DownloadState::Running);
        assert_eq!(persisted.state, DownloadState::Running);
    }

    #[tokio::test]
    async fn start_stale_running_task_recovers_before_running() {
        let temp_dir = tempfile::tempdir().unwrap();
        let store = TaskStore::new(temp_dir.path().join("queue.json"));
        let task = store
            .enqueue(DownloadRequest::new("unknown://example", temp_dir.path()))
            .await
            .unwrap();
        let mut running = task.clone();
        running.set_state(DownloadState::Running);
        running.updated_at_ms = running.updated_at_ms.saturating_sub(10 * 60 * 1000);
        store.update(running).await.unwrap();

        let report = QueueRunner::new(store.clone())
            .run_task_with_options(&task.id, QueueRunnerOptions::default())
            .await
            .unwrap();
        let persisted = store.get(&task.id).await.unwrap();

        assert!(report.summary.is_none());
        assert_eq!(report.task.state, DownloadState::Failed);
        assert_eq!(persisted.state, DownloadState::Failed);
    }

    async fn wait_for_progress(store: &TaskStore, task_id: &str) {
        for _ in 0..50 {
            let task = store.get(task_id).await.unwrap();
            if task.state == DownloadState::Running
                && task.downloaded_bytes > 0
                && task.current_speed_bytes_per_second > 0
            {
                return;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        panic!("timed out waiting for stored progress");
    }
}
