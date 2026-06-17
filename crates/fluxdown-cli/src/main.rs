use anyhow::Result;
use clap::{Parser, Subcommand};
use fluxdown_core::{
    DownloadEngine, DownloadOptions, DownloadRequest, DownloadState, QueueRunner,
    QueueRunnerOptions, TaskStore, default_store_path, detect_protocol, doctor_report,
    runtime_support_status,
};
use std::path::PathBuf;

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
        #[arg(short, long, default_value_t = 2)]
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
        } => {
            let mut request = DownloadRequest::new(source, output);
            request.file_name = name;
            let summary = DownloadEngine::new()
                .download_with_options(request, download_options(threads, speed_limit_mbps))
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
                    concurrency,
                    runner_options(retry_attempts, threads, speed_limit_mbps, restart),
                )
                .await?;
            println!("{}", serde_json::to_string_pretty(&report)?);
        }
        Command::Pause { id } => {
            let task = store.set_state(&id, DownloadState::Paused).await?;
            println!("{}", serde_json::to_string_pretty(&task)?);
        }
        Command::Resume { id } => {
            let task = store.set_state(&id, DownloadState::Queued).await?;
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
        retry_attempts,
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
