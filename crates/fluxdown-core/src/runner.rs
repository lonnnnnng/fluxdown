use crate::{
    CancelToken, DownloadEngine, DownloadError, DownloadProgress, DownloadState, DownloadTask,
    TaskStore, TaskStoreError,
};
use futures_util::stream::{self, StreamExt};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};
use thiserror::Error;
use tokio::sync::{Mutex, mpsc};

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
        let concurrency = concurrency.max(1);
        let queued = self
            .store
            .list()
            .await?
            .into_iter()
            .filter(|task| task.state == DownloadState::Queued)
            .collect::<Vec<_>>();
        let total_queued = queued.len();

        let write_lock = Arc::new(Mutex::new(()));
        let results = stream::iter(queued)
            .map(|task| {
                let store = self.store.clone();
                let engine = self.engine.clone();
                let write_lock = Arc::clone(&write_lock);
                async move {
                    run_one(store, engine, task, write_lock)
                        .await
                        .map(|report| report.task)
                }
            })
            .buffer_unordered(concurrency)
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
        let task = self.store.get(id).await?;
        run_one(
            self.store.clone(),
            self.engine.clone(),
            task,
            Arc::new(Mutex::new(())),
        )
        .await
    }
}

async fn run_one(
    store: TaskStore,
    engine: DownloadEngine,
    mut task: DownloadTask,
    write_lock: Arc<Mutex<()>>,
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
                match store
                    .set_progress_if_running(
                        &progress_task.id,
                        progress_task.downloaded_bytes,
                        progress_task.total_bytes,
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
        .download_with_control(task.request(), Some(progress_callback), Some(cancel))
        .await
    {
        Ok(summary) => {
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
    Ok(TaskRunReport {
        task: store.update(task).await?,
        summary,
    })
}

async fn partial_file_size(task: &DownloadTask) -> Option<u64> {
    let path = task
        .file_name
        .as_ref()
        .map(|file_name| task.output_dir.join(file_name))
        .or_else(|| infer_output_path(task));
    let path = path?;
    tokio::fs::metadata(path)
        .await
        .ok()
        .map(|metadata| metadata.len())
}

fn infer_output_path(task: &DownloadTask) -> Option<PathBuf> {
    let file_name = task
        .source
        .rsplit('/')
        .next()
        .filter(|segment| !segment.is_empty())?;
    Some(task.output_dir.join(file_name))
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
        assert!(report.summary.is_none());

        server.abort();
    }

    async fn wait_for_progress(store: &TaskStore, task_id: &str) {
        for _ in 0..50 {
            let task = store.get(task_id).await.unwrap();
            if task.state == DownloadState::Running && task.downloaded_bytes > 0 {
                return;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        panic!("timed out waiting for stored progress");
    }
}
