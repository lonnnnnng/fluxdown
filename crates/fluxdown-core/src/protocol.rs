use serde::{Deserialize, Serialize};
use std::path::Path;
use tokio::process::Command;
use url::Url;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Protocol {
    Http,
    Https,
    Webdav,
    Webdavs,
    Ftp,
    Ftps,
    Torrent,
    Magnet,
    Ed2k,
    M3u8,
    Sftp,
    Smb,
    Ipfs,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Backend {
    BuiltIn,
    SystemHandoff,
    Aria2,
    Amule,
    SmbClient,
    Ipfs,
    Planned,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct SupportStatus {
    pub protocol: Protocol,
    pub backend: Backend,
    pub executable: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BackendAvailability {
    pub backend: Backend,
    pub command: Option<String>,
    pub available: bool,
    pub note: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RuntimeSupportStatus {
    pub protocol: Protocol,
    pub backend: Backend,
    pub configured: bool,
    pub executable: bool,
    pub missing_command: Option<String>,
    pub note: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DoctorReport {
    pub backends: Vec<BackendAvailability>,
    pub protocols: Vec<RuntimeSupportStatus>,
}

pub fn support_status(protocol: Protocol) -> SupportStatus {
    let backend = match protocol {
        Protocol::Http
        | Protocol::Https
        | Protocol::Webdav
        | Protocol::Webdavs
        | Protocol::Ftp
        | Protocol::Ftps
        | Protocol::Torrent
        | Protocol::Magnet
        | Protocol::M3u8
        | Protocol::Sftp
        | Protocol::Smb
        | Protocol::Ipfs => Backend::BuiltIn,
        Protocol::Ed2k => Backend::SystemHandoff,
        Protocol::Unknown => Backend::Planned,
    };

    SupportStatus {
        protocol,
        backend,
        executable: backend != Backend::Planned,
    }
}

pub async fn runtime_support_status(protocol: Protocol) -> RuntimeSupportStatus {
    if protocol == Protocol::Ed2k {
        let amule = backend_availability(Backend::Amule).await;
        if amule.available {
            return RuntimeSupportStatus {
                protocol,
                backend: Backend::Amule,
                configured: true,
                executable: true,
                missing_command: None,
                note: amule.note,
            };
        }

        let handoff = backend_availability(Backend::SystemHandoff).await;
        return RuntimeSupportStatus {
            protocol,
            backend: Backend::SystemHandoff,
            configured: true,
            executable: true,
            missing_command: None,
            note: format!("{}; {}", amule.note, handoff.note),
        };
    }

    let status = support_status(protocol);
    let availability = backend_availability(status.backend).await;
    let missing_command = if status.executable && !availability.available {
        availability.command.clone()
    } else {
        None
    };

    RuntimeSupportStatus {
        protocol,
        backend: status.backend,
        configured: status.executable,
        executable: status.executable && availability.available,
        missing_command,
        note: availability.note,
    }
}

pub async fn doctor_report() -> DoctorReport {
    let backends = [
        Backend::BuiltIn,
        Backend::Amule,
        Backend::SystemHandoff,
        Backend::Planned,
    ];
    let protocols = [
        Protocol::Http,
        Protocol::Https,
        Protocol::Webdav,
        Protocol::Webdavs,
        Protocol::Ftp,
        Protocol::Ftps,
        Protocol::Torrent,
        Protocol::Magnet,
        Protocol::Ed2k,
        Protocol::M3u8,
        Protocol::Sftp,
        Protocol::Smb,
        Protocol::Ipfs,
    ];

    DoctorReport {
        backends: futures_util::future::join_all(backends.into_iter().map(backend_availability))
            .await,
        protocols: futures_util::future::join_all(
            protocols.into_iter().map(runtime_support_status),
        )
        .await,
    }
}

pub async fn backend_availability(backend: Backend) -> BackendAvailability {
    match backend {
        Backend::BuiltIn => BackendAvailability {
            backend,
            command: None,
            available: true,
            note: "compiled into FluxDown core".to_string(),
        },
        Backend::SystemHandoff => BackendAvailability {
            backend,
            command: None,
            available: true,
            note: "delegates matching links to the operating system URL handler".to_string(),
        },
        Backend::Aria2 => {
            command_availability(backend, "aria2c", "optional external aria2 backend").await
        }
        Backend::Amule => command_availability(backend, "ed2k", "optional ed2k CLI handoff").await,
        Backend::SmbClient => {
            command_availability(backend, "smbclient", "optional external SMB fallback").await
        }
        Backend::Ipfs => {
            command_availability(backend, "ipfs", "optional external IPFS backend").await
        }
        Backend::Planned => BackendAvailability {
            backend,
            command: None,
            available: false,
            note: "no executable backend is configured for this protocol yet".to_string(),
        },
    }
}

async fn command_availability(backend: Backend, command: &str, note: &str) -> BackendAvailability {
    let available = Command::new(command)
        .arg("--version")
        .output()
        .await
        .is_ok_and(|output| output.status.success());

    BackendAvailability {
        backend,
        command: Some(command.to_string()),
        available,
        note: if available {
            note.to_string()
        } else {
            format!("{note}; `{command}` was not found in PATH")
        },
    }
}

pub fn detect_protocol(input: &str) -> Protocol {
    let trimmed = input.trim();
    let lowered = trimmed.to_ascii_lowercase();

    if lowered.starts_with("magnet:?") {
        return Protocol::Magnet;
    }

    if lowered.starts_with("ed2k://") {
        return Protocol::Ed2k;
    }

    if has_path_extension(trimmed, "torrent") {
        return Protocol::Torrent;
    }

    if has_path_extension(trimmed, "m3u8") {
        return Protocol::M3u8;
    }

    match Url::parse(trimmed).map(|url| url.scheme().to_ascii_lowercase()) {
        Ok(scheme) => match scheme.as_str() {
            "http" => Protocol::Http,
            "https" => Protocol::Https,
            "webdav" => Protocol::Webdav,
            "webdavs" => Protocol::Webdavs,
            "ftp" => Protocol::Ftp,
            "ftps" => Protocol::Ftps,
            "sftp" => Protocol::Sftp,
            "smb" => Protocol::Smb,
            "ipfs" => Protocol::Ipfs,
            _ => Protocol::Unknown,
        },
        Err(_) => Protocol::Unknown,
    }
}

fn has_path_extension(input: &str, extension: &str) -> bool {
    let lowered = input.to_ascii_lowercase();
    if lowered.ends_with(&format!(".{extension}")) {
        return true;
    }

    if let Ok(url) = Url::parse(input) {
        return Path::new(url.path())
            .extension()
            .is_some_and(|ext| ext.eq_ignore_ascii_case(extension));
    }

    Path::new(input)
        .extension()
        .is_some_and(|ext| ext.eq_ignore_ascii_case(extension))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_mainstream_protocols() {
        let cases = [
            ("http://example.com/a.bin", Protocol::Http),
            ("https://example.com/video.m3u8", Protocol::M3u8),
            (
                "webdav://cloud.example.com/remote.php/dav/files/a.zip",
                Protocol::Webdav,
            ),
            (
                "webdavs://cloud.example.com/remote.php/dav/files/a.zip",
                Protocol::Webdavs,
            ),
            ("ftp://example.com/file.iso", Protocol::Ftp),
            ("ftps://example.com/file.iso", Protocol::Ftps),
            ("sftp://example.com/file.iso", Protocol::Sftp),
            ("smb://nas/share/file.iso", Protocol::Smb),
            ("ipfs://bafybeigdyrzt", Protocol::Ipfs),
            ("magnet:?xt=urn:btih:abc", Protocol::Magnet),
            ("ed2k://|file|x|1|hash|/", Protocol::Ed2k),
            ("/tmp/linux.torrent", Protocol::Torrent),
            (
                "https://example.com/file.torrent?token=abc",
                Protocol::Torrent,
            ),
            ("https://example.com/video.m3u8?token=abc", Protocol::M3u8),
        ];

        for (input, expected) in cases {
            assert_eq!(detect_protocol(input), expected, "{input}");
        }
    }

    #[test]
    fn reports_backend_capability() {
        assert_eq!(support_status(Protocol::Https).backend, Backend::BuiltIn);
        assert_eq!(support_status(Protocol::Webdav).backend, Backend::BuiltIn);
        assert_eq!(support_status(Protocol::Webdavs).backend, Backend::BuiltIn);
        assert_eq!(support_status(Protocol::M3u8).backend, Backend::BuiltIn);
        assert_eq!(support_status(Protocol::Ftp).backend, Backend::BuiltIn);
        assert_eq!(support_status(Protocol::Ftps).backend, Backend::BuiltIn);
        assert_eq!(support_status(Protocol::Torrent).backend, Backend::BuiltIn);
        assert_eq!(support_status(Protocol::Magnet).backend, Backend::BuiltIn);
        assert_eq!(support_status(Protocol::Ipfs).backend, Backend::BuiltIn);
        assert_eq!(support_status(Protocol::Sftp).backend, Backend::BuiltIn);
        assert_eq!(
            support_status(Protocol::Ed2k).backend,
            Backend::SystemHandoff
        );
        assert_eq!(support_status(Protocol::Smb).backend, Backend::BuiltIn);
    }
}
