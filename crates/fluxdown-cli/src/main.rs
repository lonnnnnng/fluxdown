use anyhow::{Result, bail};
use clap::{Parser, Subcommand};
use fluxdown_core::{
    DEFAULT_DOWNLOAD_THREAD_COUNT, DEFAULT_QUEUE_CONCURRENCY, DEFAULT_RETRY_ATTEMPTS,
    DownloadEngine, DownloadOptions, DownloadRequest, DownloadState, QueueRunner,
    QueueRunnerOptions, SftpJumpOptions, TaskStore, default_store_path, delete_credential,
    detect_protocol, doctor_report, redact_url_credentials_in_text, runtime_support_status,
    set_credential, validate_credential_ref, validate_sha256_text,
};
use std::time::Duration;
use std::{
    io::{self, Read},
    path::PathBuf,
};
use url::Url;

const MIN_CONCURRENCY: usize = 1;
const MAX_CONCURRENCY: usize = 30;
const MAX_RETRY_ATTEMPTS: usize = 10;
const STALE_RUNNING_TASK_TIMEOUT: Duration = Duration::from_secs(5 * 60);

#[derive(Debug, Parser)]
#[command(name = "fluxdown")]
#[command(about = "Cross-platform downloader CLI")]
#[command(version)]
struct Cli {
    #[arg(long, global = true)]
    store: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    Detect {
        source: String,
    },
    Support {
        source: String,
    },
    Doctor,
    Credential {
        #[command(subcommand)]
        command: CredentialCommand,
    },
    Download {
        source: String,
        #[arg(short, long, default_value = ".")]
        output: PathBuf,
        #[arg(short = 'n', long)]
        name: Option<String>,
        #[arg(long, default_value_t = DEFAULT_DOWNLOAD_THREAD_COUNT)]
        threads: usize,
        #[arg(
            long = "speed-limit-mbps",
            help = "per-task limit in MiB/s; blank means unlimited"
        )]
        speed_limit_mbps: Option<f64>,
        #[arg(long = "sha256")]
        expected_sha256: Option<String>,
        #[arg(long = "torrent-file-index")]
        torrent_file_indices: Vec<usize>,
        #[arg(long = "hls-variant-index", help = "HLS master playlist variant index")]
        hls_variant_index: Option<usize>,
        #[arg(
            long = "hls-keep-ts",
            help = "Keep HLS transport stream output instead of remuxing to MP4"
        )]
        hls_keep_ts: bool,
        #[arg(
            long = "sftp-known-hosts",
            help = "OpenSSH known_hosts file used to verify SFTP server identity"
        )]
        sftp_known_hosts: Option<PathBuf>,
        #[arg(
            long = "sftp-jump",
            help = "runtime SFTP jump URL, for example sftp://user@bastion:22"
        )]
        sftp_jump: Option<String>,
        #[arg(
            long = "sftp-jump-known-hosts",
            help = "OpenSSH known_hosts file used to verify the SFTP jump host"
        )]
        sftp_jump_known_hosts: Option<PathBuf>,
        #[arg(
            long = "credential-ref",
            help = "system credential reference created by `credential set`"
        )]
        credential_ref: Option<String>,
        #[arg(long)]
        restart: bool,
    },
    Add {
        source: String,
        #[arg(short, long, default_value = ".")]
        output: PathBuf,
        #[arg(short = 'n', long)]
        name: Option<String>,
        #[arg(long = "sha256")]
        expected_sha256: Option<String>,
        #[arg(long = "torrent-file-index")]
        torrent_file_indices: Vec<usize>,
        #[arg(long = "hls-variant-index", help = "HLS master playlist variant index")]
        hls_variant_index: Option<usize>,
        #[arg(
            long = "hls-keep-ts",
            help = "Keep HLS transport stream output instead of remuxing to MP4"
        )]
        hls_keep_ts: bool,
        #[arg(
            long = "credential-ref",
            help = "system credential reference created by `credential set`"
        )]
        credential_ref: Option<String>,
    },
    List,
    Start {
        id: String,
        #[arg(long, default_value_t = DEFAULT_RETRY_ATTEMPTS)]
        retry_attempts: usize,
        #[arg(long)]
        restart: bool,
        #[arg(long, default_value_t = DEFAULT_DOWNLOAD_THREAD_COUNT)]
        threads: usize,
        #[arg(
            long = "speed-limit-mbps",
            help = "global limit in MiB/s; blank means unlimited"
        )]
        speed_limit_mbps: Option<f64>,
        #[arg(long = "hls-variant-index", help = "HLS master playlist variant index")]
        hls_variant_index: Option<usize>,
        #[arg(
            long = "hls-keep-ts",
            help = "Keep HLS transport stream output instead of remuxing to MP4"
        )]
        hls_keep_ts: bool,
        #[arg(
            long = "sftp-known-hosts",
            help = "OpenSSH known_hosts file used to verify SFTP server identity"
        )]
        sftp_known_hosts: Option<PathBuf>,
        #[arg(
            long = "sftp-jump",
            help = "runtime SFTP jump URL, for example sftp://user@bastion:22"
        )]
        sftp_jump: Option<String>,
        #[arg(
            long = "sftp-jump-known-hosts",
            help = "OpenSSH known_hosts file used to verify the SFTP jump host"
        )]
        sftp_jump_known_hosts: Option<PathBuf>,
    },
    Run {
        #[arg(short, long, default_value_t = DEFAULT_QUEUE_CONCURRENCY)]
        concurrency: usize,
        #[arg(long, default_value_t = DEFAULT_RETRY_ATTEMPTS)]
        retry_attempts: usize,
        #[arg(long)]
        restart: bool,
        #[arg(long, default_value_t = DEFAULT_DOWNLOAD_THREAD_COUNT)]
        threads: usize,
        #[arg(
            long = "speed-limit-mbps",
            help = "global limit in MiB/s; blank means unlimited"
        )]
        speed_limit_mbps: Option<f64>,
        #[arg(long = "hls-variant-index", help = "HLS master playlist variant index")]
        hls_variant_index: Option<usize>,
        #[arg(
            long = "hls-keep-ts",
            help = "Keep HLS transport stream output instead of remuxing to MP4"
        )]
        hls_keep_ts: bool,
        #[arg(
            long = "sftp-known-hosts",
            help = "OpenSSH known_hosts file used to verify SFTP server identity"
        )]
        sftp_known_hosts: Option<PathBuf>,
        #[arg(
            long = "sftp-jump",
            help = "runtime SFTP jump URL, for example sftp://user@bastion:22"
        )]
        sftp_jump: Option<String>,
        #[arg(
            long = "sftp-jump-known-hosts",
            help = "OpenSSH known_hosts file used to verify the SFTP jump host"
        )]
        sftp_jump_known_hosts: Option<PathBuf>,
    },
    Pause {
        id: String,
    },
    Resume {
        id: String,
    },
    Remove {
        id: String,
    },
}

#[derive(Debug, Subcommand)]
enum CredentialCommand {
    /// 将用户名和 stdin 中的密码保存到系统凭据库。
    Set {
        reference: String,
        #[arg(long)]
        username: String,
    },
    /// 删除系统凭据库中的引用。
    Delete { reference: String },
}

#[tokio::main]
async fn main() {
    if let Err(error) = run_cli().await {
        eprintln!(
            "Error: {}",
            redact_url_credentials_in_text(&format!("{error:#}"))
        );
        std::process::exit(1);
    }
}

async fn run_cli() -> Result<()> {
    let cli = Cli::parse();
    let store = TaskStore::new(cli.store.clone().unwrap_or_else(default_store_path));

    match cli.command {
        Command::Detect { source } => {
            println!("{}", detect_protocol(&source).as_str());
        }
        Command::Support { source } => {
            let status = runtime_support_status(detect_protocol(&source)).await;
            println!("{}", serde_json::to_string_pretty(&status)?);
        }
        Command::Doctor => {
            println!("{}", serde_json::to_string_pretty(&doctor_report().await)?);
        }
        Command::Credential { command } => match command {
            CredentialCommand::Set {
                reference,
                username,
            } => {
                let mut password = String::new();
                io::stdin().read_to_string(&mut password)?;
                let password = password.trim_end_matches(['\r', '\n']);
                let reference = validate_credential_ref(&reference).map_err(anyhow::Error::msg)?;
                set_credential(&reference, &username, password)
                    .map_err(|error| anyhow::anyhow!(error.to_string()))?;
                println!(
                    "{}",
                    serde_json::json!({"reference": reference, "stored": true})
                );
            }
            CredentialCommand::Delete { reference } => {
                let reference = validate_credential_ref(&reference).map_err(anyhow::Error::msg)?;
                delete_credential(&reference)
                    .map_err(|error| anyhow::anyhow!(error.to_string()))?;
                println!(
                    "{}",
                    serde_json::json!({"reference": reference, "deleted": true})
                );
            }
        },
        Command::Download {
            source,
            output,
            name,
            threads,
            speed_limit_mbps,
            expected_sha256,
            torrent_file_indices,
            hls_variant_index,
            hls_keep_ts,
            sftp_known_hosts,
            sftp_jump: sftp_jump_url,
            sftp_jump_known_hosts,
            credential_ref,
            restart,
        } => {
            let sftp_jump = parse_sftp_jump(sftp_jump_url, sftp_jump_known_hosts)?;
            let mut request = DownloadRequest::new(source, output);
            request.file_name = name;
            request.credential_ref = credential_ref;
            request.expected_sha256 = validated_expected_sha256(expected_sha256)?;
            request.torrent_file_indices = torrent_file_indices;
            request.hls_variant_index = hls_variant_index;
            request.hls_keep_transport_stream = Some(hls_keep_ts);
            let summary = DownloadEngine::new()
                .download_with_options(
                    request,
                    download_options(
                        threads,
                        speed_limit_mbps,
                        hls_variant_index,
                        hls_keep_ts,
                        sftp_known_hosts,
                        sftp_jump,
                    )
                    .with_restart_existing(restart),
                )
                .await
                .map_err(|error| anyhow::anyhow!(error.user_message()))?;
            println!("{}", serde_json::to_string_pretty(&summary)?);
        }
        Command::Add {
            source,
            output,
            name,
            expected_sha256,
            torrent_file_indices,
            hls_variant_index,
            hls_keep_ts,
            credential_ref,
        } => {
            let mut request = DownloadRequest::new(source, output);
            request.file_name = name;
            request.credential_ref = credential_ref;
            request.expected_sha256 = validated_expected_sha256(expected_sha256)?;
            request.torrent_file_indices = torrent_file_indices;
            request.hls_variant_index = hls_variant_index;
            request.hls_keep_transport_stream = Some(hls_keep_ts);
            let task = store.enqueue(request).await?;
            println!(
                "{}",
                serde_json::to_string_pretty(&task.redacted_for_display())?
            );
        }
        Command::List => {
            store
                .recover_stale_running(STALE_RUNNING_TASK_TIMEOUT)
                .await?;
            let tasks = store
                .list()
                .await?
                .into_iter()
                .map(|task| task.redacted_for_display())
                .collect::<Vec<_>>();
            println!("{}", serde_json::to_string_pretty(&tasks)?);
        }
        Command::Start {
            id,
            retry_attempts,
            restart,
            threads,
            speed_limit_mbps,
            hls_variant_index,
            hls_keep_ts,
            sftp_known_hosts,
            sftp_jump: sftp_jump_url,
            sftp_jump_known_hosts,
        } => {
            let sftp_jump = parse_sftp_jump(sftp_jump_url, sftp_jump_known_hosts)?;
            let report = QueueRunner::new(store)
                .run_task_with_options(
                    &id,
                    runner_options(
                        retry_attempts,
                        threads,
                        speed_limit_mbps,
                        restart,
                        hls_variant_index,
                        hls_keep_ts,
                        sftp_known_hosts,
                        sftp_jump,
                    ),
                )
                .await?;
            println!(
                "{}",
                serde_json::to_string_pretty(&report.redacted_for_display())?
            );
        }
        Command::Run {
            concurrency,
            retry_attempts,
            restart,
            threads,
            speed_limit_mbps,
            hls_variant_index,
            hls_keep_ts,
            sftp_known_hosts,
            sftp_jump: sftp_jump_url,
            sftp_jump_known_hosts,
        } => {
            let sftp_jump = parse_sftp_jump(sftp_jump_url, sftp_jump_known_hosts)?;
            let report = QueueRunner::new(store)
                .run_queued_with_options(
                    clamp_concurrency(concurrency),
                    runner_options(
                        retry_attempts,
                        threads,
                        speed_limit_mbps,
                        restart,
                        hls_variant_index,
                        hls_keep_ts,
                        sftp_known_hosts,
                        sftp_jump,
                    ),
                )
                .await?;
            println!(
                "{}",
                serde_json::to_string_pretty(&report.redacted_for_display())?
            );
        }
        Command::Pause { id } => {
            let task = pause_task(&store, &id).await?;
            println!(
                "{}",
                serde_json::to_string_pretty(&task.redacted_for_display())?
            );
        }
        Command::Resume { id } => {
            let task = resume_task(&store, &id).await?;
            println!(
                "{}",
                serde_json::to_string_pretty(&task.redacted_for_display())?
            );
        }
        Command::Remove { id } => {
            let task = remove_task(&store, &id).await?;
            println!(
                "{}",
                serde_json::to_string_pretty(&task.redacted_for_display())?
            );
        }
    }

    Ok(())
}

fn runner_options(
    retry_attempts: usize,
    threads: usize,
    speed_limit_mbps: Option<f64>,
    restart_existing: bool,
    hls_variant_index: Option<usize>,
    hls_keep_ts: bool,
    sftp_known_hosts: Option<PathBuf>,
    sftp_jump: Option<SftpJumpOptions>,
) -> QueueRunnerOptions {
    QueueRunnerOptions {
        // 作者: long
        // CLI 和桌面设置共用同一条业务边界：失败重试最多 10 次，避免终端误传大数导致任务长时间循环。
        retry_attempts: clamp_retry_attempts(retry_attempts),
        download: download_options(
            threads,
            speed_limit_mbps,
            hls_variant_index,
            hls_keep_ts,
            sftp_known_hosts,
            sftp_jump,
        ),
        restart_existing,
    }
}

fn download_options(
    threads: usize,
    speed_limit_mbps: Option<f64>,
    hls_variant_index: Option<usize>,
    hls_keep_ts: bool,
    sftp_known_hosts: Option<PathBuf>,
    sftp_jump: Option<SftpJumpOptions>,
) -> DownloadOptions {
    DownloadOptions::new(threads, speed_limit_mbps_to_bps(speed_limit_mbps))
        .with_hls_options(hls_variant_index, hls_keep_ts)
        .with_sftp_known_hosts(sftp_known_hosts)
        .with_sftp_jump(sftp_jump)
}

fn parse_sftp_jump(
    value: Option<String>,
    known_hosts: Option<PathBuf>,
) -> Result<Option<SftpJumpOptions>> {
    if value.is_none() && known_hosts.is_some() {
        anyhow::bail!("--sftp-jump-known-hosts requires --sftp-jump")
    }
    value
        .map(|value| {
            let url = Url::parse(&value)
                .map_err(|error| anyhow::anyhow!("invalid --sftp-jump URL: {error}"))?;
            SftpJumpOptions::from_url(&url, known_hosts)
                .map_err(|error| anyhow::anyhow!(error.user_message()))
        })
        .transpose()
}

fn validated_expected_sha256(value: Option<String>) -> Result<Option<String>> {
    value
        .map(|value| validate_sha256_text(&value).map_err(anyhow::Error::msg))
        .transpose()
}

fn speed_limit_mbps_to_bps(speed_limit_mbps: Option<f64>) -> Option<u64> {
    speed_limit_mbps
        .filter(|value| value.is_finite() && *value > 0.0)
        .map(|value| (value * 1024.0 * 1024.0).round() as u64)
        .filter(|value| *value > 0)
}

fn clamp_concurrency(concurrency: usize) -> usize {
    // 作者: long
    // 队列并发和 GUI 设置保持一致，既允许终端脚本容错，也避免一次性启动过多任务压垮本机网络。
    concurrency.clamp(MIN_CONCURRENCY, MAX_CONCURRENCY)
}

fn clamp_retry_attempts(retry_attempts: usize) -> usize {
    retry_attempts.min(MAX_RETRY_ATTEMPTS)
}

async fn pause_task(store: &TaskStore, id: &str) -> Result<fluxdown_core::DownloadTask> {
    // 作者: long
    // 进程崩溃后队列可能残留 running；暂停入口也要先恢复中断任务，避免返回一个没有中断原因的假运行状态。
    store
        .recover_stale_running(STALE_RUNNING_TASK_TIMEOUT)
        .await?;
    let task = store.get(id).await?;
    // 作者: long
    // 暂停只作用于未结束任务，避免命令行误操作把已完成或失败任务改成可继续状态。
    match task.state {
        DownloadState::Queued | DownloadState::Running => {
            Ok(store.set_state(id, DownloadState::Paused).await?)
        }
        DownloadState::Paused => Ok(task),
        DownloadState::Finished | DownloadState::HandedOff | DownloadState::Failed => {
            bail!("only queued or running tasks can be paused")
        }
    }
}

async fn resume_task(store: &TaskStore, id: &str) -> Result<fluxdown_core::DownloadTask> {
    // 作者: long
    // 用户重开终端后通常会直接 resume 上次任务；先回收陈旧 running，才能把异常中断任务恢复进队列。
    store
        .recover_stale_running(STALE_RUNNING_TASK_TIMEOUT)
        .await?;
    let task = store.get(id).await?;
    // 作者: long
    // 恢复只把暂停任务放回队列；已结束任务需要显式 start/restart，避免隐藏的重复下载。
    match task.state {
        DownloadState::Paused => Ok(store.set_state(id, DownloadState::Queued).await?),
        DownloadState::Queued => Ok(task),
        DownloadState::Running => bail!("running tasks do not need resume"),
        DownloadState::Finished | DownloadState::HandedOff | DownloadState::Failed => {
            bail!(
                "finished, handed-off or failed tasks cannot be resumed; start them again explicitly"
            )
        }
    }
}

async fn remove_task(store: &TaskStore, id: &str) -> Result<fluxdown_core::DownloadTask> {
    // 作者: long
    // 删除崩溃残留任务前先回收陈旧 running，命令返回值才能表达真实中断原因，现役下载不会被这个窗口误判。
    store
        .recover_stale_running(STALE_RUNNING_TASK_TIMEOUT)
        .await?;
    Ok(store.remove(id).await?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cli_queue_limits_match_product_settings() {
        let options = runner_options(99, 99, Some(-1.0), false, None, false, None, None);

        assert_eq!(DEFAULT_QUEUE_CONCURRENCY, 5);
        assert_eq!(DEFAULT_DOWNLOAD_THREAD_COUNT, 16);
        assert_eq!(DEFAULT_RETRY_ATTEMPTS, 3);
        assert_eq!(clamp_concurrency(0), 1);
        assert_eq!(clamp_concurrency(31), 30);
        assert_eq!(options.retry_attempts, 10);
        assert_eq!(options.download.thread_count, 32);
        assert_eq!(options.download.speed_limit_bps, None);
    }

    #[test]
    fn cli_default_download_options_use_sixteen_threads() {
        let options =
            download_options(DEFAULT_DOWNLOAD_THREAD_COUNT, None, None, false, None, None);

        assert_eq!(options.thread_count, 16);
        assert_eq!(options.speed_limit_bps, None);
    }

    #[test]
    fn cli_sftp_known_hosts_path_is_carried_into_download_options() {
        let path = PathBuf::from("/tmp/fluxdown/known_hosts");
        let options = download_options(
            DEFAULT_DOWNLOAD_THREAD_COUNT,
            None,
            None,
            false,
            Some(path.clone()),
            None,
        );

        assert_eq!(options.sftp_known_hosts, Some(path));
    }

    #[test]
    fn cli_sftp_jump_url_is_runtime_only_and_carries_known_hosts() {
        let path = PathBuf::from("/tmp/fluxdown/jump_known_hosts");
        let jump = parse_sftp_jump(
            Some("sftp://jump-user@example.test:2222/".to_string()),
            Some(path.clone()),
        )
        .unwrap()
        .unwrap();
        assert_eq!(jump.username, "jump-user");
        assert_eq!(jump.host, "example.test");
        assert_eq!(jump.port, 2222);
        assert_eq!(jump.known_hosts, Some(path));
        let options = download_options(
            DEFAULT_DOWNLOAD_THREAD_COUNT,
            None,
            None,
            false,
            None,
            Some(jump),
        );
        assert!(options.sftp_jump.is_some());
        let json = serde_json::to_string(&options).unwrap();
        assert!(!json.contains("jump-user"));
        assert!(!json.contains("example.test"));
    }
}
