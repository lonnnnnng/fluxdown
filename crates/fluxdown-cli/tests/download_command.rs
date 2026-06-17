use serde_json::Value;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::process::Command;
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use std::thread;

#[test]
fn detect_and_support_commands_cover_webdav() {
    let detect_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "detect",
            "webdavs://cloud.example.com/remote.php/dav/files/archive.zip",
        ])
        .output()
        .unwrap();
    assert!(
        detect_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&detect_output.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&detect_output.stdout).trim(),
        "Webdavs"
    );

    let support_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "support",
            "webdav://cloud.example.com/remote.php/dav/files/archive.zip",
        ])
        .output()
        .unwrap();
    assert!(
        support_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&support_output.stderr)
    );
    let support: Value = serde_json::from_slice(&support_output.stdout).unwrap();
    assert_eq!(support["protocol"], "webdav");
    assert_eq!(support["backend"], "built-in");
    assert_eq!(support["executable"], true);
}

#[test]
fn download_command_fetches_http_file() {
    let payload = b"fluxdown-cli-direct-download";
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut buffer = [0; 1024];
        let _ = stream.read(&mut buffer).unwrap();
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            payload.len()
        );
        stream.write_all(response.as_bytes()).unwrap();
        stream.write_all(payload).unwrap();
    });

    let temp_dir = tempfile::tempdir().unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "download",
            &format!("http://{address}/file.bin"),
            "--output",
            temp_dir.path().to_str().unwrap(),
            "--name",
            "payload.bin",
        ])
        .output()
        .unwrap();

    server.join().unwrap();
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        std::fs::read(temp_dir.path().join("payload.bin")).unwrap(),
        payload
    );

    let summary: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(summary["protocol"], "http");
    assert_eq!(summary["backend"], "built-in");
    assert_eq!(summary["bytes_written"], payload.len() as u64);
    assert_eq!(
        summary["output_path"].as_str().unwrap(),
        temp_dir.path().join("payload.bin").to_string_lossy()
    );
}

#[test]
fn queue_commands_add_list_and_run_http_task() {
    let payload = b"fluxdown-cli-queued-download";
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut buffer = [0; 1024];
        let _ = stream.read(&mut buffer).unwrap();
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            payload.len()
        );
        stream.write_all(response.as_bytes()).unwrap();
        stream.write_all(payload).unwrap();
    });

    let temp_dir = tempfile::tempdir().unwrap();
    let store_path = temp_dir.path().join("queue.json");
    let downloads_dir = temp_dir.path().join("downloads");
    let source = format!("http://{address}/queued.bin");

    let add_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "--store",
            store_path.to_str().unwrap(),
            "add",
            &source,
            "--output",
            downloads_dir.to_str().unwrap(),
            "--name",
            "queued.bin",
        ])
        .output()
        .unwrap();
    assert!(
        add_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&add_output.stderr)
    );
    let added: Value = serde_json::from_slice(&add_output.stdout).unwrap();
    let task_id = added["id"].as_str().unwrap().to_string();
    assert_eq!(added["state"], "queued");
    assert_eq!(added["source"], source);

    let list_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args(["--store", store_path.to_str().unwrap(), "list"])
        .output()
        .unwrap();
    assert!(
        list_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&list_output.stderr)
    );
    let listed: Value = serde_json::from_slice(&list_output.stdout).unwrap();
    assert_eq!(listed.as_array().unwrap().len(), 1);
    assert_eq!(listed[0]["id"], task_id);
    assert_eq!(listed[0]["state"], "queued");

    let run_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "--store",
            store_path.to_str().unwrap(),
            "run",
            "--concurrency",
            "1",
        ])
        .output()
        .unwrap();

    server.join().unwrap();
    assert!(
        run_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&run_output.stderr)
    );
    assert_eq!(
        std::fs::read(downloads_dir.join("queued.bin")).unwrap(),
        payload
    );
    let report: Value = serde_json::from_slice(&run_output.stdout).unwrap();
    assert_eq!(report["total_queued"], 1);
    assert_eq!(report["started"], 1);
    assert_eq!(report["finished"], 1);
    assert_eq!(report["failed"], 0);
    assert_eq!(report["tasks"][0]["id"], task_id);
    assert_eq!(report["tasks"][0]["state"], "finished");
    assert_eq!(report["tasks"][0]["downloaded_bytes"], payload.len() as u64);

    let final_list_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args(["--store", store_path.to_str().unwrap(), "list"])
        .output()
        .unwrap();
    assert!(
        final_list_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&final_list_output.stderr)
    );
    let final_list: Value = serde_json::from_slice(&final_list_output.stdout).unwrap();
    assert_eq!(final_list[0]["id"], task_id);
    assert_eq!(final_list[0]["state"], "finished");
}

#[test]
fn queue_run_retries_failed_http_task() {
    let payload = b"fluxdown-cli-retried-download";
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let attempts = Arc::new(AtomicUsize::new(0));
    let server_attempts = Arc::clone(&attempts);
    let server = thread::spawn(move || {
        for _ in 0..2 {
            let (mut stream, _) = listener.accept().unwrap();
            let attempt = server_attempts.fetch_add(1, Ordering::SeqCst) + 1;
            let mut buffer = [0; 1024];
            let _ = stream.read(&mut buffer).unwrap();
            if attempt == 1 {
                let response = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                stream.write_all(response.as_bytes()).unwrap();
            } else {
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    payload.len()
                );
                stream.write_all(response.as_bytes()).unwrap();
                stream.write_all(payload).unwrap();
            }
        }
    });

    let temp_dir = tempfile::tempdir().unwrap();
    let store_path = temp_dir.path().join("queue.json");
    let downloads_dir = temp_dir.path().join("downloads");
    let source = format!("http://{address}/retry.bin");

    let add_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "--store",
            store_path.to_str().unwrap(),
            "add",
            &source,
            "--output",
            downloads_dir.to_str().unwrap(),
            "--name",
            "retry.bin",
        ])
        .output()
        .unwrap();
    assert!(
        add_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&add_output.stderr)
    );

    let run_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "--store",
            store_path.to_str().unwrap(),
            "run",
            "--concurrency",
            "1",
            "--retry-attempts",
            "1",
        ])
        .output()
        .unwrap();

    server.join().unwrap();
    assert!(
        run_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&run_output.stderr)
    );
    assert_eq!(attempts.load(Ordering::SeqCst), 2);
    assert_eq!(
        std::fs::read(downloads_dir.join("retry.bin")).unwrap(),
        payload
    );
    let report: Value = serde_json::from_slice(&run_output.stdout).unwrap();
    assert_eq!(report["finished"], 1);
    assert_eq!(report["failed"], 0);
    assert_eq!(report["tasks"][0]["state"], "finished");
}

#[test]
fn queue_start_restart_replaces_existing_http_output() {
    let payload = b"fluxdown-cli-restarted-download";
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut buffer = [0; 2048];
        let read = stream.read(&mut buffer).unwrap();
        let request = String::from_utf8_lossy(&buffer[..read]);
        assert!(!request.to_ascii_lowercase().contains("range:"));
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            payload.len()
        );
        stream.write_all(response.as_bytes()).unwrap();
        stream.write_all(payload).unwrap();
    });

    let temp_dir = tempfile::tempdir().unwrap();
    let store_path = temp_dir.path().join("queue.json");
    let downloads_dir = temp_dir.path().join("downloads");
    std::fs::create_dir_all(&downloads_dir).unwrap();
    std::fs::write(downloads_dir.join("restart.bin"), b"stale complete file").unwrap();
    let source = format!("http://{address}/restart.bin");

    let add_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "--store",
            store_path.to_str().unwrap(),
            "add",
            &source,
            "--output",
            downloads_dir.to_str().unwrap(),
            "--name",
            "restart.bin",
        ])
        .output()
        .unwrap();
    assert!(
        add_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&add_output.stderr)
    );
    let added: Value = serde_json::from_slice(&add_output.stdout).unwrap();
    let task_id = added["id"].as_str().unwrap().to_string();

    let start_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "--store",
            store_path.to_str().unwrap(),
            "start",
            &task_id,
            "--restart",
        ])
        .output()
        .unwrap();

    server.join().unwrap();
    assert!(
        start_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&start_output.stderr)
    );
    assert_eq!(
        std::fs::read(downloads_dir.join("restart.bin")).unwrap(),
        payload
    );
    let report: Value = serde_json::from_slice(&start_output.stdout).unwrap();
    assert_eq!(report["task"]["state"], "finished");
    assert_eq!(report["task"]["downloaded_bytes"], payload.len() as u64);
}

#[test]
fn download_command_fetches_webdav_file_through_http_transport() {
    let payload = b"fluxdown-cli-webdav-download";
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut buffer = [0; 1024];
        let _ = stream.read(&mut buffer).unwrap();
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            payload.len()
        );
        stream.write_all(response.as_bytes()).unwrap();
        stream.write_all(payload).unwrap();
    });

    let temp_dir = tempfile::tempdir().unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "download",
            &format!("webdav://{address}/remote.php/dav/files/payload.bin"),
            "--output",
            temp_dir.path().to_str().unwrap(),
        ])
        .output()
        .unwrap();

    server.join().unwrap();
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        std::fs::read(temp_dir.path().join("payload.bin")).unwrap(),
        payload
    );

    let summary: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(summary["protocol"], "webdav");
    assert_eq!(summary["backend"], "built-in");
    assert_eq!(summary["bytes_written"], payload.len() as u64);
}
