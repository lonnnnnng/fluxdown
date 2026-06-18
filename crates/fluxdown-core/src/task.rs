use crate::{Protocol, SupportStatus, detect_protocol, support_status};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::path::PathBuf;
use url::Url;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadRequest {
    pub source: String,
    pub output_dir: PathBuf,
    pub file_name: Option<String>,
    #[serde(default)]
    pub expected_sha256: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub torrent_file_indices: Vec<usize>,
}

impl DownloadRequest {
    pub fn new(source: impl Into<String>, output_dir: impl Into<PathBuf>) -> Self {
        Self {
            source: source.into(),
            output_dir: output_dir.into(),
            file_name: None,
            expected_sha256: None,
            torrent_file_indices: Vec::new(),
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
    #[serde(default)]
    pub expected_sha256: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub torrent_file_indices: Vec<usize>,
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
        let protocol = request.protocol();
        let file_name = request
            .file_name
            .map(|name| sanitize_download_file_name(&name, "download.bin"));

        Self {
            id: format!("task-{}", Uuid::new_v4()),
            protocol,
            support: support_status(protocol),
            source: request.source,
            state: DownloadState::Queued,
            output_dir: request.output_dir,
            file_name,
            expected_sha256: request
                .expected_sha256
                .as_deref()
                .map(normalize_sha256_text),
            torrent_file_indices: normalize_torrent_file_indices(request.torrent_file_indices),
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
            file_name: self
                .file_name
                .as_deref()
                .map(|name| sanitize_download_file_name(name, "download.bin")),
            expected_sha256: self.expected_sha256.as_deref().map(normalize_sha256_text),
            torrent_file_indices: normalize_torrent_file_indices(self.torrent_file_indices.clone()),
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
                self.error = None;
            }
            DownloadState::Finished | DownloadState::Failed => {
                self.finished_at_ms = Some(millis);
                self.current_speed_bytes_per_second = 0;
                if state == DownloadState::Finished {
                    self.error = None;
                }
            }
            DownloadState::Queued => {
                self.finished_at_ms = None;
                self.current_speed_bytes_per_second = 0;
                self.error = None;
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

pub fn normalize_torrent_file_indices(indices: Vec<usize>) -> Vec<usize> {
    // 作者: long
    // 多文件种子的选择会直接传给下载引擎，排序去重后持久化，避免重复索引让 CLI/GUI 的展示和实际下载范围不一致。
    indices
        .into_iter()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

pub fn normalize_sha256_text(value: &str) -> String {
    value
        .trim()
        .strip_prefix("sha256:")
        .unwrap_or_else(|| value.trim())
        .trim()
        .to_ascii_lowercase()
}

pub fn validate_sha256_text(value: &str) -> Result<String, String> {
    let normalized = normalize_sha256_text(value);
    if normalized.len() == 64
        && normalized
            .chars()
            .all(|character| character.is_ascii_hexdigit())
    {
        Ok(normalized)
    } else {
        Err(format!(
            "invalid SHA-256 checksum `{value}`; expected 64 hex characters"
        ))
    }
}

pub fn sanitize_download_file_name(name: &str, fallback: &str) -> String {
    let candidate = name
        .trim()
        .chars()
        .map(|character| {
            if character.is_control()
                || matches!(
                    character,
                    '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|'
                )
            {
                '_'
            } else {
                character
            }
        })
        .collect::<String>()
        .trim_matches(|character: char| character.is_whitespace() || character == '.')
        .to_string();

    // 作者: long
    // 下载文件名最终会和保存目录拼成本地路径，空名、当前目录和上级目录都要回退，避免 CLI/桌面任务写出用户选择的目录。
    if candidate.is_empty() || candidate == "." || candidate == ".." {
        sanitize_download_file_name(fallback, "download.bin")
    } else {
        candidate
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

    while let Some(next_url) = next_redactable_url(text, index) {
        let start = next_url.start;
        let end = text[next_url.marker..]
            .find(|character: char| character.is_whitespace() || "\"'`)>]".contains(character))
            .map(|position| next_url.marker + position)
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

struct RedactableUrl {
    start: usize,
    marker: usize,
}

fn next_redactable_url(text: &str, index: usize) -> Option<RedactableUrl> {
    let remaining = &text[index..];
    let with_authority = remaining.find("://").map(|relative| {
        let marker = index + relative;
        let start = text[..marker]
            .rfind(|character: char| character.is_whitespace() || "\"'`(<[".contains(character))
            .map(|position| position + 1)
            .unwrap_or(0);
        RedactableUrl { start, marker }
    });
    let magnet = remaining
        .to_ascii_lowercase()
        .find("magnet:?")
        .map(|relative| {
            let start = index + relative;
            RedactableUrl {
                start,
                marker: start,
            }
        });

    match (with_authority, magnet) {
        (Some(authority), Some(magnet)) => {
            if authority.start <= magnet.start {
                Some(authority)
            } else {
                Some(magnet)
            }
        }
        (Some(authority), None) => Some(authority),
        (None, Some(magnet)) => Some(magnet),
        (None, None) => None,
    }
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
        object.remove("expected_sha256");

        let restored: DownloadTask = serde_json::from_value(value).unwrap();

        assert_eq!(restored.current_speed_bytes_per_second, 0);
        assert_eq!(restored.started_at_ms, None);
        assert_eq!(restored.finished_at_ms, None);
        assert_eq!(restored.expected_sha256, None);
        assert!(restored.torrent_file_indices.is_empty());
    }

    #[test]
    fn normalizes_expected_sha256_when_creating_task() {
        let mut request = DownloadRequest::new("https://example.com/file.bin", "/tmp");
        request.expected_sha256 = Some(
            " sha256:671E23B189BB7A2041EFF1B29F077B4E59460D30DB56248FDCCCAFA012BABFC8 ".to_string(),
        );

        let task = DownloadTask::from_request(request);

        assert_eq!(
            task.expected_sha256.as_deref(),
            Some("671e23b189bb7a2041eff1b29f077b4e59460d30db56248fdcccafa012babfc8")
        );
        assert_eq!(
            task.request().expected_sha256.as_deref(),
            Some("671e23b189bb7a2041eff1b29f077b4e59460d30db56248fdcccafa012babfc8")
        );
    }

    #[test]
    fn validates_sha256_text_before_queueing_tasks() {
        assert_eq!(
            validate_sha256_text(
                " sha256:671E23B189BB7A2041EFF1B29F077B4E59460D30DB56248FDCCCAFA012BABFC8 "
            )
            .unwrap(),
            "671e23b189bb7a2041eff1b29f077b4e59460d30db56248fdcccafa012babfc8"
        );
        assert!(validate_sha256_text("not-a-sha256").is_err());
    }

    #[test]
    fn normalizes_torrent_file_indices_when_creating_task() {
        let mut request = DownloadRequest::new("/tmp/multi.torrent", "/tmp");
        request.torrent_file_indices = vec![3, 1, 3, 0];

        let task = DownloadTask::from_request(request);

        assert_eq!(task.torrent_file_indices, vec![0, 1, 3]);
        assert_eq!(task.request().torrent_file_indices, vec![0, 1, 3]);
    }

    #[test]
    fn sanitizes_requested_file_name_when_creating_task() {
        let mut request = DownloadRequest::new("https://example.com/file.bin", "/tmp");
        request.file_name = Some("../bad:name?.zip".to_string());

        let task = DownloadTask::from_request(request);

        assert_eq!(task.file_name.as_deref(), Some("_bad_name_.zip"));
    }

    #[test]
    fn sanitizes_legacy_task_file_name_when_building_request() {
        let mut task = DownloadTask::from_request(DownloadRequest::new(
            "https://example.com/file.bin",
            "/tmp",
        ));
        task.file_name = Some("../legacy:name.bin".to_string());

        assert_eq!(
            task.request().file_name.as_deref(),
            Some("_legacy_name.bin")
        );
    }

    #[test]
    fn unsafe_file_names_fall_back_to_single_file_name() {
        assert_eq!(
            sanitize_download_file_name("..", "download.bin"),
            "download.bin"
        );
        assert_eq!(
            sanitize_download_file_name(" . ", "download.bin"),
            "download.bin"
        );
        assert_eq!(
            sanitize_download_file_name("folder\\name?.bin", "download.bin"),
            "folder_name_.bin"
        );
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
    fn redacts_credentials_from_magnet_tracker_urls_in_text() {
        let text = "failed magnet:?xt=urn:btih:abc&tr=https%3A%2F%2Fuser%3Ap%2540ss%40tracker.example.com%2Fannounce.";

        let redacted = redact_url_credentials_in_text(text);

        assert_eq!(
            redacted,
            "failed magnet:?xt=urn%3Abtih%3Aabc&tr=https%3A%2F%2F***%3A***%40tracker.example.com%2Fannounce."
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

    #[test]
    fn requeue_and_rerun_clear_interruption_error() {
        let mut task = DownloadTask::from_request(DownloadRequest::new(
            "https://example.com/file.bin",
            "/tmp",
        ));

        task.set_state(DownloadState::Running);
        task.pause_after_interruption();
        assert!(
            task.error
                .as_deref()
                .unwrap_or_default()
                .contains("任务中断")
        );

        // 作者: long
        // 中断提示只属于暂停态；重新排队或再次下载后不能继续污染任务卡片和 CLI JSON。
        task.set_state(DownloadState::Queued);
        assert_eq!(task.error, None);
        task.error = Some("old interruption".to_string());
        task.set_state(DownloadState::Running);
        assert_eq!(task.error, None);
        task.error = Some("old interruption".to_string());
        task.set_state(DownloadState::Finished);
        assert_eq!(task.error, None);
    }
}
