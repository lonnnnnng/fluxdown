use crate::{DownloadRequest, DownloadState, DownloadTask};
use serde::{Deserialize, Serialize};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::time::Duration;
use tempfile::NamedTempFile;
use thiserror::Error;
use tokio::fs;
use tokio::sync::Mutex;

static TASK_STORE_WRITE_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

#[derive(Debug, Error)]
pub enum TaskStoreError {
    #[error("task `{0}` was not found")]
    NotFound(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

#[derive(Debug, Clone)]
pub struct TaskStore {
    path: PathBuf,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
struct TaskStoreFile {
    tasks: Vec<DownloadTask>,
}

impl TaskStore {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub async fn list(&self) -> Result<Vec<DownloadTask>, TaskStoreError> {
        let _guard = TASK_STORE_WRITE_LOCK.lock().await;
        Ok(self.read_file().await?.tasks)
    }

    pub async fn enqueue(&self, request: DownloadRequest) -> Result<DownloadTask, TaskStoreError> {
        let _guard = TASK_STORE_WRITE_LOCK.lock().await;
        let mut file = self.read_file().await?;
        let task = DownloadTask::from_request(request);
        file.tasks.insert(0, task.clone());
        self.write_file(&file).await?;
        Ok(task)
    }

    pub async fn update(&self, task: DownloadTask) -> Result<DownloadTask, TaskStoreError> {
        let _guard = TASK_STORE_WRITE_LOCK.lock().await;
        let mut file = self.read_file().await?;
        let Some(existing) = file
            .tasks
            .iter_mut()
            .find(|candidate| candidate.id == task.id)
        else {
            return Err(TaskStoreError::NotFound(task.id));
        };
        *existing = task.clone();
        self.write_file(&file).await?;
        Ok(task)
    }

    pub async fn set_state(
        &self,
        id: &str,
        state: DownloadState,
    ) -> Result<DownloadTask, TaskStoreError> {
        let _guard = TASK_STORE_WRITE_LOCK.lock().await;
        let mut file = self.read_file().await?;
        let Some(task) = file.tasks.iter_mut().find(|candidate| candidate.id == id) else {
            return Err(TaskStoreError::NotFound(id.to_string()));
        };
        task.set_state(state);
        let updated = task.clone();
        self.write_file(&file).await?;
        Ok(updated)
    }

    pub async fn set_progress_if_running(
        &self,
        id: &str,
        downloaded_bytes: u64,
        total_bytes: Option<u64>,
        current_speed_bytes_per_second: u64,
    ) -> Result<Option<DownloadTask>, TaskStoreError> {
        let _guard = TASK_STORE_WRITE_LOCK.lock().await;
        let mut file = self.read_file().await?;
        let Some(task) = file.tasks.iter_mut().find(|candidate| candidate.id == id) else {
            return Err(TaskStoreError::NotFound(id.to_string()));
        };
        if task.state != DownloadState::Running {
            return Ok(None);
        }

        task.set_progress_with_speed(
            downloaded_bytes,
            total_bytes,
            current_speed_bytes_per_second,
        );
        let updated = task.clone();
        self.write_file(&file).await?;
        Ok(Some(updated))
    }

    pub async fn remove(&self, id: &str) -> Result<DownloadTask, TaskStoreError> {
        let _guard = TASK_STORE_WRITE_LOCK.lock().await;
        let mut file = self.read_file().await?;
        let Some(index) = file.tasks.iter().position(|candidate| candidate.id == id) else {
            return Err(TaskStoreError::NotFound(id.to_string()));
        };
        let removed = file.tasks.remove(index);
        self.write_file(&file).await?;
        Ok(removed)
    }

    pub async fn get(&self, id: &str) -> Result<DownloadTask, TaskStoreError> {
        let _guard = TASK_STORE_WRITE_LOCK.lock().await;
        self.read_file()
            .await?
            .tasks
            .into_iter()
            .find(|task| task.id == id)
            .ok_or_else(|| TaskStoreError::NotFound(id.to_string()))
    }

    pub async fn recover_stale_running(
        &self,
        max_age: Duration,
    ) -> Result<Vec<DownloadTask>, TaskStoreError> {
        let _guard = TASK_STORE_WRITE_LOCK.lock().await;
        let mut file = self.read_file().await?;
        let now = now_ms();
        let max_age_ms = max_age.as_millis();
        let mut recovered = Vec::new();

        for task in &mut file.tasks {
            if task.state != DownloadState::Running {
                continue;
            }
            if now.saturating_sub(task.updated_at_ms) < max_age_ms {
                continue;
            }

            task.pause_after_interruption();
            recovered.push(task.clone());
        }

        if !recovered.is_empty() {
            self.write_file(&file).await?;
        }

        Ok(recovered)
    }

    async fn read_file(&self) -> Result<TaskStoreFile, TaskStoreError> {
        if !self.path.exists() {
            if let Some(legacy_path) = legacy_default_store_path_for(&self.path)
                && legacy_path.exists()
            {
                return read_store_file(&legacy_path).await;
            }
            return Ok(TaskStoreFile::default());
        }

        read_store_file(&self.path).await
    }

    async fn write_file(&self, file: &TaskStoreFile) -> Result<(), TaskStoreError> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent).await?;
        }

        let bytes = serde_json::to_vec_pretty(file)?;
        let path = self.path.clone();
        tokio::task::spawn_blocking(move || persist_atomically(&path, &bytes))
            .await
            .map_err(|error| {
                std::io::Error::other(format!("task store write failed: {error}"))
            })??;
        Ok(())
    }
}

fn persist_atomically(path: &Path, bytes: &[u8]) -> Result<(), std::io::Error> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let mut temp_file = NamedTempFile::new_in(parent)?;
    temp_file.write_all(bytes)?;
    temp_file.flush()?;
    temp_file.as_file().sync_all()?;
    temp_file
        .persist(path)
        .map_err(|error| std::io::Error::new(error.error.kind(), error.error))?;
    Ok(())
}

fn now_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or_default()
}

pub fn default_store_path() -> PathBuf {
    default_store_path_from_env(
        env_path("XDG_DATA_HOME"),
        env_path("HOME"),
        env_path("APPDATA"),
    )
}

async fn read_store_file(path: &Path) -> Result<TaskStoreFile, TaskStoreError> {
    let bytes = fs::read(path).await?;
    if bytes.is_empty() {
        return Ok(TaskStoreFile::default());
    }

    Ok(serde_json::from_slice(&bytes)?)
}

fn default_store_path_from_env(
    xdg_data_home: Option<PathBuf>,
    home: Option<PathBuf>,
    appdata: Option<PathBuf>,
) -> PathBuf {
    if let Some(base) = non_empty_path(xdg_data_home) {
        return base.join("fluxdown").join("queue.json");
    }

    platform_default_store_path(non_empty_path(home), non_empty_path(appdata))
}

#[cfg(target_os = "macos")]
fn platform_default_store_path(home: Option<PathBuf>, _appdata: Option<PathBuf>) -> PathBuf {
    home.map(|home| {
        home.join("Library")
            .join("Application Support")
            .join("FluxDown")
            .join("queue.json")
    })
    .unwrap_or_else(|| PathBuf::from(".").join("fluxdown").join("queue.json"))
}

#[cfg(target_os = "windows")]
fn platform_default_store_path(home: Option<PathBuf>, appdata: Option<PathBuf>) -> PathBuf {
    appdata
        .or_else(|| home.map(|home| home.join("AppData").join("Roaming")))
        .map(|base| base.join("FluxDown").join("queue.json"))
        .unwrap_or_else(|| PathBuf::from(".").join("fluxdown").join("queue.json"))
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn platform_default_store_path(home: Option<PathBuf>, _appdata: Option<PathBuf>) -> PathBuf {
    let base = home
        .map(|home| home.join(".local/share"))
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("fluxdown").join("queue.json")
}

fn legacy_default_store_path_for(path: &Path) -> Option<PathBuf> {
    if env_path("XDG_DATA_HOME").is_some() {
        return None;
    }
    let legacy_path = legacy_unix_default_store_path()?;
    if path == legacy_path {
        return None;
    }
    if path == default_store_path() {
        Some(legacy_path)
    } else {
        None
    }
}

fn legacy_unix_default_store_path() -> Option<PathBuf> {
    env_path("HOME").map(|home| {
        home.join(".local/share")
            .join("fluxdown")
            .join("queue.json")
    })
}

fn env_path(key: &str) -> Option<PathBuf> {
    std::env::var_os(key)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

fn non_empty_path(path: Option<PathBuf>) -> Option<PathBuf> {
    path.filter(|path| !path.as_os_str().is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;

    static STORE_ENV_LOCK: LazyLock<tokio::sync::Mutex<()>> =
        LazyLock::new(|| tokio::sync::Mutex::new(()));

    struct EnvVarGuard {
        key: &'static str,
        old_value: Option<OsString>,
    }

    impl EnvVarGuard {
        fn set(key: &'static str, value: impl AsRef<std::ffi::OsStr>) -> Self {
            let old_value = std::env::var_os(key);
            // 作者: long
            // 默认队列路径依赖进程环境变量；测试用临时 HOME/XDG 隔离真实用户队列，避免迁移逻辑读写本机数据。
            unsafe {
                std::env::set_var(key, value);
            }
            Self { key, old_value }
        }

        fn remove(key: &'static str) -> Self {
            let old_value = std::env::var_os(key);
            // 作者: long
            // XDG 显式覆盖会关闭旧路径迁移；测试迁移时必须临时移除它，才能验证 macOS 原生路径兼容旧队列。
            unsafe {
                std::env::remove_var(key);
            }
            Self { key, old_value }
        }
    }

    impl Drop for EnvVarGuard {
        fn drop(&mut self) {
            // 作者: long
            // 环境变量是进程级状态，恢复原值能避免并行测试之间互相污染默认路径。
            unsafe {
                if let Some(old_value) = &self.old_value {
                    std::env::set_var(self.key, old_value);
                } else {
                    std::env::remove_var(self.key);
                }
            }
        }
    }

    #[tokio::test]
    async fn persists_tasks() {
        let path =
            std::env::temp_dir().join(format!("fluxdown-store-{}.json", uuid::Uuid::new_v4()));
        let store = TaskStore::new(&path);
        let task = store
            .enqueue(DownloadRequest::new("https://example.com/file.bin", "/tmp"))
            .await
            .unwrap();

        assert_eq!(store.list().await.unwrap().len(), 1);
        let updated = store
            .set_state(&task.id, DownloadState::Paused)
            .await
            .unwrap();
        assert_eq!(updated.state, DownloadState::Paused);
        assert_eq!(
            store.get(&task.id).await.unwrap().state,
            DownloadState::Paused
        );
        store.remove(&task.id).await.unwrap();
        assert!(store.list().await.unwrap().is_empty());
        let _ = fs::remove_file(path).await;
    }

    #[tokio::test]
    async fn atomically_replaces_existing_store_file() {
        let temp_dir = tempfile::tempdir().unwrap();
        let path = temp_dir.path().join("queue.json");
        fs::write(&path, r#"{"tasks":[]}"#).await.unwrap();

        let store = TaskStore::new(&path);
        store
            .enqueue(DownloadRequest::new("https://example.com/file.bin", "/tmp"))
            .await
            .unwrap();

        let source = fs::read_to_string(&path).await.unwrap();
        assert!(source.contains("https://example.com/file.bin"));
        assert!(serde_json::from_str::<serde_json::Value>(&source).is_ok());

        let mut entries = fs::read_dir(temp_dir.path()).await.unwrap();
        let mut entry_count = 0;
        while entries.next_entry().await.unwrap().is_some() {
            entry_count += 1;
        }
        assert_eq!(entry_count, 1);
    }

    #[tokio::test]
    async fn recovers_stale_running_tasks_as_paused() {
        let temp_dir = tempfile::tempdir().unwrap();
        let store = TaskStore::new(temp_dir.path().join("queue.json"));
        let task = store
            .enqueue(DownloadRequest::new("https://example.com/file.bin", "/tmp"))
            .await
            .unwrap();
        let mut running = task;
        running.set_state(DownloadState::Running);
        running.updated_at_ms = running.updated_at_ms.saturating_sub(10_000);
        store.update(running.clone()).await.unwrap();

        let recovered = store
            .recover_stale_running(Duration::from_secs(1))
            .await
            .unwrap();
        let persisted = store.get(&running.id).await.unwrap();

        assert_eq!(recovered.len(), 1);
        assert_eq!(persisted.state, DownloadState::Paused);
        assert_eq!(persisted.current_speed_bytes_per_second, 0);
        assert!(persisted.error.unwrap().contains("任务中断"));
    }

    #[tokio::test]
    async fn keeps_recent_running_tasks_active() {
        let temp_dir = tempfile::tempdir().unwrap();
        let store = TaskStore::new(temp_dir.path().join("queue.json"));
        let task = store
            .enqueue(DownloadRequest::new("https://example.com/file.bin", "/tmp"))
            .await
            .unwrap();
        let mut running = task;
        running.set_state(DownloadState::Running);
        store.update(running.clone()).await.unwrap();

        let recovered = store
            .recover_stale_running(Duration::from_secs(60))
            .await
            .unwrap();
        let persisted = store.get(&running.id).await.unwrap();

        assert!(recovered.is_empty());
        assert_eq!(persisted.state, DownloadState::Running);
    }

    #[test]
    fn xdg_data_home_keeps_explicit_queue_override() {
        let xdg = PathBuf::from("/tmp/fluxdown-xdg-test");
        let home = PathBuf::from("/tmp/fluxdown-home-test");

        assert_eq!(
            default_store_path_from_env(Some(xdg.clone()), Some(home), None),
            xdg.join("fluxdown").join("queue.json")
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn empty_xdg_data_home_falls_back_to_macos_native_path() {
        let home = PathBuf::from("/Users/example");

        assert_eq!(
            default_store_path_from_env(Some(PathBuf::new()), Some(home.clone()), None),
            home.join("Library")
                .join("Application Support")
                .join("FluxDown")
                .join("queue.json")
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_default_store_path_uses_application_support() {
        let home = PathBuf::from("/Users/example");

        assert_eq!(
            default_store_path_from_env(None, Some(home.clone()), None),
            home.join("Library")
                .join("Application Support")
                .join("FluxDown")
                .join("queue.json")
        );
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn macos_default_store_reads_legacy_unix_queue_when_native_queue_is_missing() {
        let _guard = STORE_ENV_LOCK.lock().await;
        let temp_dir = tempfile::tempdir().unwrap();
        let home = temp_dir.path().join("home");
        let _home_guard = EnvVarGuard::set("HOME", &home);
        let _xdg_guard = EnvVarGuard::remove("XDG_DATA_HOME");
        let _appdata_guard = EnvVarGuard::remove("APPDATA");

        let legacy_path = home
            .join(".local/share")
            .join("fluxdown")
            .join("queue.json");
        let native_path = home
            .join("Library")
            .join("Application Support")
            .join("FluxDown")
            .join("queue.json");
        let legacy_store = TaskStore::new(&legacy_path);
        let legacy_task = legacy_store
            .enqueue(DownloadRequest::new(
                "https://example.com/legacy.bin",
                "/tmp",
            ))
            .await
            .unwrap();

        let default_store = TaskStore::new(default_store_path());

        let tasks = default_store.list().await.unwrap();
        assert_eq!(default_store.path(), native_path.as_path());
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].id, legacy_task.id);
        assert!(!native_path.exists());

        default_store
            .enqueue(DownloadRequest::new(
                "https://example.com/native.bin",
                "/tmp",
            ))
            .await
            .unwrap();

        assert!(native_path.exists());
        assert_eq!(default_store.list().await.unwrap().len(), 2);
    }
}
