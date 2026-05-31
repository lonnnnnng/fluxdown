use anyhow::Result;
use clap::{Parser, Subcommand};
use fluxdown_core::{
    DownloadEngine, DownloadRequest, DownloadState, QueueRunner, TaskStore, default_store_path,
    detect_protocol, doctor_report, runtime_support_status,
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
    },
    Run {
        #[arg(short, long, default_value_t = 2)]
        concurrency: usize,
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
        } => {
            let mut request = DownloadRequest::new(source, output);
            request.file_name = name;
            let summary = DownloadEngine::new().download(request).await?;
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
        Command::Start { id } => {
            let report = QueueRunner::new(store).run_task(&id).await?;
            println!("{}", serde_json::to_string_pretty(&report)?);
        }
        Command::Run { concurrency } => {
            let report = QueueRunner::new(store).run_queued(concurrency).await?;
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
