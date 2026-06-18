use anyhow::{Result, bail};
use clap::{Parser, Subcommand};
use fluxdown_core::{
    DownloadEngine, DownloadOptions, DownloadRequest, DownloadState, QueueRunner,
    QueueRunnerOptions, TaskStore, default_store_path, detect_protocol, doctor_report,
    runtime_support_status,
};
use std::path::PathBuf;
use std::time::Duration;

const MIN_CONCURRENCY: usize = 1;
const MAX_CONCURRENCY: usize = 30;
const DEFAULT_CONCURRENCY: usize = 1;
const MAX_RETRY_ATTEMPTS: usize = 10;
const STALE_RUNNING_TASK_TIMEOUT: Duration = Duration::from_secs(5 * 60);

#[derive(Debug, Parser)]
#[command(name = "fluxdown")]
#[command(about = "Cross-platform downloader CLI")]
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
    Download {
        source: String,
        #[arg(short, long, default_value = ".")]
        output: PathBuf,
        #[arg(short = 'n', long)]
        name: Option<String>,
        #[arg(long, default_value_t = 1)]
        threads: usize,
        #[arg(long = "speed-limit-mbps")]
        speed_limit_mbps: Option<f64>,
        #[arg(long)]
        restart: bool,
    },
    Add {
        source: String,
        #[arg(short, long, default_value = ".")]
        output: PathBuf,
        #[arg(short = 'n', long)]
        name: Option<String>,
    },
    List,
    Start {
        id: String,
        #[arg(long, default_value_t = 0)]
        retry_attempts: usize,
        #[arg(long)]
        restart: bool,
        #[arg(long, default_value_t = 1)]
        threads: usize,
        #[arg(long = "speed-limit-mbps")]
        speed_limit_mbps: Option<f64>,
    },
    Run {
        #[arg(short, long, default_value_t = DEFAULT_CONCURRENCY)]
        concurrency: usize,
        #[arg(long, default_value_t = 0)]
        retry_attempts: usize,
        #[arg(long)]
        restart: bool,
        #[arg(long, default_value_t = 1)]
        threads: usize,
        #[arg(long = "speed-limit-mbps")]
        speed_limit_mbps: Option<f64>,
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

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let store = TaskStore::new(cli.store.clone().unwrap_or_else(default_store_path));

    match cli.command {
        Command::Detect { source } => {
            println!("{:?}", detect_protocol(&source));
        }
        Command::Support { source } => {
            let status = runtime_support_status(detect_protocol(&source)).await;
            println!("{}", serde_json::to_string_pretty(&status)?);
        }
        Command::Doctor => {
            println!("{}", serde_json::to_string_pretty(&doctor_report().await)?);
        }
        Command::Download {
            source,
            output,
            name,
            threads,
            speed_limit_mbps,
            restart,
        } => {
            let mut request = DownloadRequest::new(source, output);
            request.file_name = name;
            let summary = DownloadEngine::new()
                .download_with_options(
                    request,
                    download_options(threads, speed_limit_mbps).with_restart_existing(restart),
                )
                .await?;
            println!("{}", serde_json::to_string_pretty(&summary)?);
        }
        Command::Add {
            source,
            output,
            name,
        } => {
            let mut request = DownloadRequest::new(source, output);
            request.file_name = name;
            let task = store.enqueue(request).await?;
            println!("{}", serde_json::to_string_pretty(&task)?);
        }
        Command::List => {
            store
                .recover_stale_running(STALE_RUNNING_TASK_TIMEOUT)
                .await?;
            println!("{}", serde_json::to_string_pretty(&store.list().await?)?);
        }
        Command::Start {
            id,
            retry_attempts,
            restart,
            threads,
            speed_limit_mbps,
        } => {
            let report = QueueRunner::new(store)
                .run_task_with_options(
                    &id,
                    runner_options(retry_attempts, threads, speed_limit_mbps, restart),
                )
                .await?;
            println!("{}", serde_json::to_string_pretty(&report)?);
        }
        Command::Run {
            concurrency,
            retry_attempts,
            restart,
            threads,
            speed_limit_mbps,
        } => {
            let report = QueueRunner::new(store)
                .run_queued_with_options(
                    clamp_concurrency(concurrency),
                    runner_options(retry_attempts, threads, speed_limit_mbps, restart),
                )
                .await?;
            println!("{}", serde_json::to_string_pretty(&report)?);
        }
        Command::Pause { id } => {
            let task = pause_task(&store, &id).await?;
            println!("{}", serde_json::to_string_pretty(&task)?);
        }
        Command::Resume { id } => {
            let task = resume_task(&store, &id).await?;
            println!("{}", serde_json::to_string_pretty(&task)?);
        }
        Command::Remove { id } => {
            let task = store.remove(&id).await?;
            println!("{}", serde_json::to_string_pretty(&task)?);
        }
    }

    Ok(())
}

fn runner_options(
    retry_attempts: usize,
    threads: usize,
    speed_limit_mbps: Option<f64>,
    restart_existing: bool,
) -> QueueRunnerOptions {
    QueueRunnerOptions {
        // 作者: long
        // CLI 和桌面设置共用同一条业务边界：失败重试最多 10 次，避免终端误传大数导致任务长时间循环。
        retry_attempts: clamp_retry_attempts(retry_attempts),
        download: download_options(threads, speed_limit_mbps),
        restart_existing,
    }
}

fn download_options(threads: usize, speed_limit_mbps: Option<f64>) -> DownloadOptions {
    DownloadOptions::new(threads, speed_limit_mbps_to_bps(speed_limit_mbps))
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
    let task = store.get(id).await?;
    // 作者: long
    // 暂停只作用于未结束任务，避免命令行误操作把已完成或失败任务改成可继续状态。
    match task.state {
        DownloadState::Queued | DownloadState::Running => {
            Ok(store.set_state(id, DownloadState::Paused).await?)
        }
        DownloadState::Paused => Ok(task),
        DownloadState::Finished | DownloadState::Failed => {
            bail!("only queued or running tasks can be paused")
        }
    }
}

async fn resume_task(store: &TaskStore, id: &str) -> Result<fluxdown_core::DownloadTask> {
    let task = store.get(id).await?;
    // 作者: long
    // 恢复只把暂停任务放回队列；已结束任务需要显式 start/restart，避免隐藏的重复下载。
    match task.state {
        DownloadState::Paused => Ok(store.set_state(id, DownloadState::Queued).await?),
        DownloadState::Queued => Ok(task),
        DownloadState::Running => bail!("running tasks do not need resume"),
        DownloadState::Finished | DownloadState::Failed => {
            bail!("finished or failed tasks cannot be resumed; start them again explicitly")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cli_queue_limits_match_product_settings() {
        let options = runner_options(99, 99, Some(-1.0), false);

        assert_eq!(DEFAULT_CONCURRENCY, 1);
        assert_eq!(clamp_concurrency(0), 1);
        assert_eq!(clamp_concurrency(31), 30);
        assert_eq!(options.retry_attempts, 10);
        assert_eq!(options.download.thread_count, 32);
        assert_eq!(options.download.speed_limit_bps, None);
    }
}
