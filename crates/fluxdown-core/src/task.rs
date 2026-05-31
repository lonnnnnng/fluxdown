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
    pub error: Option<String>,
    pub created_at_ms: u128,
    pub updated_at_ms: u128,
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
            error: None,
            created_at_ms: millis,
            updated_at_ms: millis,
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
        self.state = state;
        self.updated_at_ms = now_ms();
    }

    pub fn set_progress(&mut self, downloaded_bytes: u64, total_bytes: Option<u64>) {
        self.downloaded_bytes = downloaded_bytes;
        self.total_bytes = total_bytes;
        self.updated_at_ms = now_ms();
    }

    pub fn fail(&mut self, error: impl Into<String>) {
        self.state = DownloadState::Failed;
        self.error = Some(error.into());
        self.updated_at_ms = now_ms();
    }
}

fn now_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or_default()
}
