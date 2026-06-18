use crate::{Protocol, SupportStatus, detect_protocol, support_status};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use url::Url;
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

    pub fn redacted_for_display(&self) -> Self {
        let mut task = self.clone();
        task.source = redact_url_credentials(&task.source);
        task.error = task.error.as_deref().map(redact_url_credentials_in_text);
        task
    }
}

pub fn redact_url_credentials(source: &str) -> String {
    let Ok(mut url) = Url::parse(source) else {
        return source.to_string();
    };
    let mut changed = redact_url_userinfo(&mut url);

    let query_pairs = url
        .query_pairs()
        .map(|(key, value)| {
            let redacted_value = redact_url_credentials(&value);
            if redacted_value != value {
                changed = true;
            }
            (key.into_owned(), redacted_value)
        })
        .collect::<Vec<_>>();

    if changed && !query_pairs.is_empty() {
        url.query_pairs_mut().clear().extend_pairs(query_pairs);
    }

    if changed {
        url.to_string()
    } else {
        source.to_string()
    }
}

pub fn redact_url_credentials_in_text(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let mut index = 0;

    while let Some(relative_scheme) = text[index..].find("://") {
        let scheme_index = index + relative_scheme;
        let start = text[..scheme_index]
            .rfind(|character: char| character.is_whitespace() || "\"'`(<[".contains(character))
            .map(|position| position + 1)
            .unwrap_or(0);
        let end = text[scheme_index..]
            .find(|character: char| character.is_whitespace() || "\"'`)>]".contains(character))
            .map(|position| scheme_index + position)
            .unwrap_or(text.len());

        output.push_str(&text[index..start]);

        let candidate = &text[start..end];
        let trimmed_end = candidate
            .trim_end_matches(|character: char| ".,;:".contains(character))
            .len();
        let (url_candidate, suffix) = candidate.split_at(trimmed_end);
        output.push_str(&redact_url_credentials(url_candidate));
        output.push_str(suffix);
        index = end;
    }

    output.push_str(&text[index..]);
    output
}

fn redact_url_userinfo(url: &mut Url) -> bool {
    let has_username = !url.username().is_empty();
    let has_password = url.password().is_some();
    if !has_username && !has_password {
        return false;
    }

    // 作者: long
    // 展示层只需要定位下载来源，用户名和密码都属于凭据，统一替换成占位符避免 CLI/GUI 输出泄漏。
    let _ = url.set_username("***");
    if has_password {
        let _ = url.set_password(Some("***"));
    } else {
        let _ = url.set_password(None);
    }
    true
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
    fn redacts_credentials_from_task_display_copy() {
        let mut task = DownloadTask::from_request(DownloadRequest::new(
            "sftp://user:p%40ss@example.com/private/file.bin",
            "/tmp",
        ));
        task.fail(
            "failed to download sftp://user:p%40ss@example.com/private/file.bin: permission denied",
        );

        let display_task = task.redacted_for_display();

        assert_eq!(
            display_task.source,
            "sftp://***:***@example.com/private/file.bin"
        );
        assert_eq!(
            display_task.error.as_deref(),
            Some(
                "failed to download sftp://***:***@example.com/private/file.bin: permission denied"
            )
        );
        assert!(task.source.contains("user:p%40ss"));
    }

    #[test]
    fn redacts_credentials_from_nested_gateway_urls() {
        let source = "ipfs://bafy/readme.txt?gateway=https%3A%2F%2Fuser%3Ap%2540ss%40gateway.example.com%2Froot";

        let redacted = redact_url_credentials(source);

        assert_eq!(
            redacted,
            "ipfs://bafy/readme.txt?gateway=https%3A%2F%2F***%3A***%40gateway.example.com%2Froot"
        );
        assert!(!redacted.contains("user"));
        assert!(!redacted.contains("p%2540ss"));
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
