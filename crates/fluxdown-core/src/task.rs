use crate::{Protocol, SupportStatus, detect_protocol, support_status};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadRequest {
    pub source: String,
    pub output_dir: PathBuf,
    pub file_name: Option<String>,
}

impl DownloadRequest {
    pub fn new(source: impl Into<String>, output_dir: impl Into<PathBuf>) -> Self {
        Self {
            source: source.into(),
            output_dir: output_dir.into(),
            file_name: None,
        }
    }

    pub fn protocol(&self) -> Protocol {
        detect_protocol(&self.source)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DownloadState {
    Queued,
    Running,
    Finished,
    Failed,
    Paused,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadTask {
    pub id: String,
    pub source: String,
    pub protocol: Protocol,
    pub support: SupportStatus,
    pub state: DownloadState,
    pub output_dir: PathBuf,
    pub file_name: Option<String>,
    pub total_bytes: Option<u64>,
    pub downloaded_bytes: u64,
    #[serde(default)]
    pub current_speed_bytes_per_second: u64,
    pub error: Option<String>,
    pub created_at_ms: u128,
    pub updated_at_ms: u128,
    #[serde(default)]
    pub started_at_ms: Option<u128>,
    #[serde(default)]
    pub finished_at_ms: Option<u128>,
}

impl DownloadTask {
    pub fn from_request(request: DownloadRequest) -> Self {
        let millis = now_ms();

        Self {
            id: format!("task-{}", Uuid::new_v4()),
            protocol: request.protocol(),
            support: support_status(request.protocol()),
            source: request.source,
            state: DownloadState::Queued,
            output_dir: request.output_dir,
            file_name: request.file_name,
            total_bytes: None,
            downloaded_bytes: 0,
            current_speed_bytes_per_second: 0,
            error: None,
            created_at_ms: millis,
            updated_at_ms: millis,
            started_at_ms: None,
            finished_at_ms: None,
        }
    }

    pub fn request(&self) -> DownloadRequest {
        DownloadRequest {
            source: self.source.clone(),
            output_dir: self.output_dir.clone(),
            file_name: self.file_name.clone(),
        }
    }

    pub fn set_state(&mut self, state: DownloadState) {
        let millis = now_ms();
        self.state = state;
        match state {
            DownloadState::Running => {
                if self.started_at_ms.is_none() {
                    self.started_at_ms = Some(millis);
                }
                self.finished_at_ms = None;
            }
            DownloadState::Finished | DownloadState::Failed => {
                self.finished_at_ms = Some(millis);
                self.current_speed_bytes_per_second = 0;
            }
            DownloadState::Queued => {
                self.finished_at_ms = None;
                self.current_speed_bytes_per_second = 0;
            }
            DownloadState::Paused => {
                self.current_speed_bytes_per_second = 0;
            }
        }
        self.updated_at_ms = millis;
    }

    pub fn set_progress(&mut self, downloaded_bytes: u64, total_bytes: Option<u64>) {
        self.set_progress_with_speed(downloaded_bytes, total_bytes, 0);
    }

    pub fn set_progress_with_speed(
        &mut self,
        downloaded_bytes: u64,
        total_bytes: Option<u64>,
        current_speed_bytes_per_second: u64,
    ) {
        self.downloaded_bytes = downloaded_bytes;
        self.total_bytes = total_bytes;
        self.current_speed_bytes_per_second = current_speed_bytes_per_second;
        self.updated_at_ms = now_ms();
    }

    pub fn fail(&mut self, error: impl Into<String>) {
        self.set_state(DownloadState::Failed);
        self.error = Some(error.into());
    }

    pub fn pause_after_interruption(&mut self) {
        // 作者: long
        // 进程异常退出后持久化队列里会残留 running；恢复成 paused 能保留断点，同时释放并发槽位。
        self.set_state(DownloadState::Paused);
        self.error = Some("任务中断，已暂停，可继续下载".to_string());
    }

    pub fn reset_for_restart(&mut self) {
        self.downloaded_bytes = 0;
        self.total_bytes = None;
        self.current_speed_bytes_per_second = 0;
        self.error = None;
        self.started_at_ms = None;
        self.finished_at_ms = None;
        self.updated_at_ms = now_ms();
    }
}

fn now_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deserializes_legacy_task_without_runtime_metrics() {
        let task = DownloadTask::from_request(DownloadRequest::new(
            "https://example.com/file.bin",
            "/tmp",
        ));
        let mut value = serde_json::to_value(task).unwrap();
        let object = value.as_object_mut().unwrap();
        object.remove("current_speed_bytes_per_second");
        object.remove("started_at_ms");
        object.remove("finished_at_ms");

        let restored: DownloadTask = serde_json::from_value(value).unwrap();

        assert_eq!(restored.current_speed_bytes_per_second, 0);
        assert_eq!(restored.started_at_ms, None);
        assert_eq!(restored.finished_at_ms, None);
    }

    #[test]
    fn records_real_start_and_finish_timestamps() {
        let mut task = DownloadTask::from_request(DownloadRequest::new(
            "https://example.com/file.bin",
            "/tmp",
        ));

        task.set_state(DownloadState::Running);
        assert!(task.started_at_ms.is_some());
        assert_eq!(task.finished_at_ms, None);

        task.set_state(DownloadState::Finished);
        assert!(task.finished_at_ms.is_some());
        assert!(task.finished_at_ms >= task.started_at_ms);
        assert_eq!(task.current_speed_bytes_per_second, 0);
    }

    #[test]
    fn retry_keeps_first_start_time_until_explicit_restart() {
        let mut task = DownloadTask::from_request(DownloadRequest::new(
            "https://example.com/file.bin",
            "/tmp",
        ));

        task.set_state(DownloadState::Running);
        let first_started_at = task.started_at_ms;
        task.fail("temporary failure");

        task.set_state(DownloadState::Running);
        assert_eq!(task.started_at_ms, first_started_at);
        assert_eq!(task.finished_at_ms, None);

        task.reset_for_restart();
        assert_eq!(task.downloaded_bytes, 0);
        assert_eq!(task.total_bytes, None);
        assert_eq!(task.error, None);
        assert_eq!(task.started_at_ms, None);
        assert_eq!(task.finished_at_ms, None);
    }
}
