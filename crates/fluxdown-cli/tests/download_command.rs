use serde_json::Value;
use std::io::{ErrorKind, Read, Write};
use std::net::TcpListener;
use std::process::{Child, Command, Output, Stdio};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use std::thread;
use std::time::{Duration, Instant};

fn wait_for_cli_output(mut child: Child, timeout: Duration) -> Output {
    let deadline = Instant::now() + timeout;
    loop {
        if child.try_wait().unwrap().is_some() {
            return child.wait_with_output().unwrap();
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let output = child.wait_with_output().unwrap();
            panic!(
                "CLI process timed out; stdout: {}; stderr: {}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }
        thread::sleep(Duration::from_millis(50));
    }
}

fn list_task(store_path: &std::path::Path, task_id: &str) -> Value {
    let output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args(["--store", store_path.to_str().unwrap(), "list"])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let tasks: Value = serde_json::from_slice(&output.stdout).unwrap();
    tasks
        .as_array()
        .unwrap()
        .iter()
        .find(|task| task["id"] == task_id)
        .cloned()
        .unwrap_or_else(|| panic!("task {task_id} not found in list output"))
}

fn list_tasks(store_path: &std::path::Path) -> Value {
    let output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args(["--store", store_path.to_str().unwrap(), "list"])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap()
}

fn wait_for_running_progress(store_path: &std::path::Path, task_id: &str) -> Value {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let task = list_task(store_path, task_id);
        if task["state"] == "running" && task["downloaded_bytes"].as_u64().unwrap_or(0) > 0 {
            return task;
        }
        if Instant::now() >= deadline {
            panic!("timed out waiting for task {task_id} running progress; last task: {task}");
        }
        thread::sleep(Duration::from_millis(50));
    }
}

fn requested_range(request: &str) -> Option<(usize, usize)> {
    let range = request.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        if name.eq_ignore_ascii_case("range") {
            Some(value.trim())
        } else {
            None
        }
    })?;
    let value = range.strip_prefix("bytes=")?;
    let (start, end) = value.split_once('-')?;
    Some((start.parse().ok()?, end.parse().ok()?))
}

fn spawn_hls_http_server() -> (String, Vec<u8>, thread::JoinHandle<()>) {
    let first_segment = b"cli hls first segment".to_vec();
    let second_segment = b"cli hls second segment".to_vec();
    let expected = [first_segment.clone(), second_segment.clone()].concat();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        for _ in 0..3 {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buffer = [0; 1024];
            let read = stream.read(&mut buffer).unwrap();
            let request = String::from_utf8_lossy(&buffer[..read]);
            let path = request
                .lines()
                .next()
                .and_then(|line| line.split_whitespace().nth(1))
                .unwrap_or("/");
            let (status, content_type, body): (&str, &str, Vec<u8>) = match path {
                "/playlist.m3u8" => (
                    "200 OK",
                    "application/vnd.apple.mpegurl",
                    b"#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:1,\nseg-1.ts\n#EXTINF:1,\nseg-2.ts\n#EXT-X-ENDLIST\n"
                        .to_vec(),
                ),
                "/seg-1.ts" => ("200 OK", "video/mp2t", first_segment.clone()),
                "/seg-2.ts" => ("200 OK", "video/mp2t", second_segment.clone()),
                _ => ("404 Not Found", "text/plain", b"not found".to_vec()),
            };
            let response = format!(
                "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            stream.write_all(response.as_bytes()).unwrap();
            stream.write_all(&body).unwrap();
        }
    });
    (format!("http://{address}/playlist.m3u8"), expected, server)
}

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
fn download_command_uses_threads_for_http_ranges() {
    let payload = Arc::new(
        (0..(256 * 1024))
            .map(|index| (index % 251) as u8)
            .collect::<Vec<_>>(),
    );
    let range_hits = Arc::new(AtomicUsize::new(0));
    let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let address = listener.local_addr().unwrap();
    let server_payload = Arc::clone(&payload);
    let server_range_hits = Arc::clone(&range_hits);
    let server_done = Arc::clone(&done);
    let server = thread::spawn(move || {
        let mut handlers = Vec::new();
        while !server_done.load(Ordering::SeqCst) {
            let Ok((mut stream, _)) = listener.accept() else {
                thread::sleep(Duration::from_millis(10));
                continue;
            };
            let handler_payload = Arc::clone(&server_payload);
            let handler_range_hits = Arc::clone(&server_range_hits);
            // 作者: long
            // 多线程下载会同时打开多个 Range 连接，fixture 也要并发响应，才能稳定验证真实客户端行为。
            handlers.push(thread::spawn(move || {
                let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
                let mut buffer = [0; 2048];
                let read = match stream.read(&mut buffer) {
                    Ok(read) => read,
                    Err(error) if error.kind() == ErrorKind::WouldBlock => return,
                    Err(error) if error.kind() == ErrorKind::TimedOut => return,
                    Err(error) => panic!("test fixture failed to read request: {error}"),
                };
                let request = String::from_utf8_lossy(&buffer[..read]);
                let method = request
                    .lines()
                    .next()
                    .and_then(|line| line.split_whitespace().next())
                    .unwrap_or("GET");
                if method == "HEAD" {
                    let response = format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                        handler_payload.len()
                    );
                    let _ = stream.write_all(response.as_bytes());
                    return;
                }

                let (status, extra_header, body) =
                    if let Some((start, end)) = requested_range(&request) {
                        handler_range_hits.fetch_add(1, Ordering::SeqCst);
                        (
                            "206 Partial Content",
                            format!(
                                "Content-Range: bytes {start}-{end}/{}\r\nAccept-Ranges: bytes\r\n",
                                handler_payload.len()
                            ),
                            handler_payload[start..=end].to_vec(),
                        )
                    } else {
                        (
                            "200 OK",
                            "Accept-Ranges: bytes\r\n".to_string(),
                            handler_payload.to_vec(),
                        )
                    };
                let response = format!(
                    "HTTP/1.1 {status}\r\nContent-Length: {}\r\n{extra_header}Connection: close\r\n\r\n",
                    body.len()
                );
                let _ = stream.write_all(response.as_bytes());
                let _ = stream.write_all(&body);
            }));
        }
        for handler in handlers {
            handler.join().unwrap();
        }
    });

    let temp_dir = tempfile::tempdir().unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "download",
            &format!("http://{address}/payload.bin"),
            "--output",
            temp_dir.path().to_str().unwrap(),
            "--name",
            "payload.bin",
            "--threads",
            "4",
        ])
        .output()
        .unwrap();

    done.store(true, Ordering::SeqCst);
    server.join().unwrap();
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        std::fs::read(temp_dir.path().join("payload.bin")).unwrap(),
        payload.as_slice()
    );

    let summary: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(summary["bytes_written"], payload.len() as u64);
    assert!(
        range_hits.load(Ordering::SeqCst) >= 2,
        "CLI --threads should trigger HTTP Range requests"
    );
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
fn download_command_fetches_hls_playlist() {
    let (source, expected_payload, server) = spawn_hls_http_server();
    let temp_dir = tempfile::tempdir().unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "download",
            &source,
            "--output",
            temp_dir.path().to_str().unwrap(),
            "--name",
            "cli-hls.m3u8",
        ])
        .output()
        .unwrap();

    server.join().unwrap();
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    // 作者: long
    // CLI 的 HLS 下载必须返回一个可被脚本读取的最终产物；测试片段不是合法媒体流，因此稳定验证 fallback 的 TS 文件。
    assert_eq!(
        std::fs::read(temp_dir.path().join("cli-hls.ts")).unwrap(),
        expected_payload
    );

    let summary: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(summary["protocol"], "m3u8");
    assert_eq!(summary["backend"], "built-in");
    assert_eq!(summary["bytes_written"], expected_payload.len() as u64);
    assert_eq!(summary["total_bytes"], expected_payload.len() as u64);
    assert_eq!(summary["segments_written"], 2);
    assert_eq!(summary["display_name"], "cli-hls.ts");
    assert_eq!(
        summary["output_path"].as_str().unwrap(),
        temp_dir.path().join("cli-hls.ts").to_string_lossy()
    );
}

#[test]
fn queue_commands_add_and_run_hls_task() {
    let (source, expected_payload, server) = spawn_hls_http_server();
    let temp_dir = tempfile::tempdir().unwrap();
    let store_path = temp_dir.path().join("queue.json");
    let downloads_dir = temp_dir.path().join("downloads");

    let add_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "--store",
            store_path.to_str().unwrap(),
            "add",
            &source,
            "--output",
            downloads_dir.to_str().unwrap(),
            "--name",
            "queue-hls.m3u8",
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
    assert_eq!(added["protocol"], "m3u8");
    assert_eq!(added["state"], "queued");

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
        std::fs::read(downloads_dir.join("queue-hls.ts")).unwrap(),
        expected_payload
    );

    let report: Value = serde_json::from_slice(&run_output.stdout).unwrap();
    assert_eq!(report["total_queued"], 1);
    assert_eq!(report["finished"], 1);
    assert_eq!(report["failed"], 0);
    assert_eq!(report["tasks"][0]["id"], task_id);
    assert_eq!(report["tasks"][0]["state"], "finished");
    assert_eq!(report["tasks"][0]["file_name"], "queue-hls.ts");
    assert_eq!(
        report["tasks"][0]["downloaded_bytes"],
        expected_payload.len() as u64
    );

    let final_list = list_tasks(&store_path);
    // 作者: long
    // 队列页展示依赖持久化任务里的最终文件名，HLS 从 .m3u8 变成真实产物后必须同步写回。
    assert_eq!(final_list[0]["file_name"], "queue-hls.ts");
    assert_eq!(final_list[0]["state"], "finished");
}

#[test]
fn download_command_restart_replaces_existing_http_file() {
    let payload = b"fluxdown-cli-direct-restarted-download";
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
    std::fs::write(temp_dir.path().join("payload.bin"), b"stale complete file").unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "download",
            &format!("http://{address}/payload.bin"),
            "--output",
            temp_dir.path().to_str().unwrap(),
            "--name",
            "payload.bin",
            "--restart",
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
    assert_eq!(summary["bytes_written"], payload.len() as u64);
    assert_eq!(summary["resumed_from"], 0);
}

#[test]
fn download_command_treats_416_as_already_complete() {
    let payload = b"fluxdown-cli-already-complete";
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut buffer = [0; 2048];
        let read = stream.read(&mut buffer).unwrap();
        let request = String::from_utf8_lossy(&buffer[..read]);
        assert!(request.to_ascii_lowercase().contains("range:"));
        let response = format!(
            "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            payload.len()
        );
        stream.write_all(response.as_bytes()).unwrap();
    });

    let temp_dir = tempfile::tempdir().unwrap();
    std::fs::write(temp_dir.path().join("payload.bin"), payload).unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "download",
            &format!("http://{address}/payload.bin"),
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
    assert_eq!(summary["bytes_written"], payload.len() as u64);
    assert_eq!(summary["resumed_from"], payload.len() as u64);
    assert_eq!(summary["total_bytes"], payload.len() as u64);
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

    let pause_queued_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args(["--store", store_path.to_str().unwrap(), "pause", &task_id])
        .output()
        .unwrap();
    assert!(
        pause_queued_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&pause_queued_output.stderr)
    );
    let paused: Value = serde_json::from_slice(&pause_queued_output.stdout).unwrap();
    assert_eq!(paused["state"], "paused");

    let resume_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args(["--store", store_path.to_str().unwrap(), "resume", &task_id])
        .output()
        .unwrap();
    assert!(
        resume_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&resume_output.stderr)
    );
    let resumed: Value = serde_json::from_slice(&resume_output.stdout).unwrap();
    assert_eq!(resumed["state"], "queued");

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

    let pause_finished_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args(["--store", store_path.to_str().unwrap(), "pause", &task_id])
        .output()
        .unwrap();
    assert!(!pause_finished_output.status.success());

    let resume_finished_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args(["--store", store_path.to_str().unwrap(), "resume", &task_id])
        .output()
        .unwrap();
    assert!(!resume_finished_output.status.success());

    let after_invalid_transition_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args(["--store", store_path.to_str().unwrap(), "list"])
        .output()
        .unwrap();
    assert!(
        after_invalid_transition_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&after_invalid_transition_output.stderr)
    );
    let after_invalid_transition: Value =
        serde_json::from_slice(&after_invalid_transition_output.stdout).unwrap();
    assert_eq!(after_invalid_transition[0]["state"], "finished");
}

#[test]
fn queue_run_defaults_to_single_concurrent_task() {
    let payload = vec![b's'; 128 * 1024];
    let active = Arc::new(AtomicUsize::new(0));
    let max_active = Arc::new(AtomicUsize::new(0));
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server_active = Arc::clone(&active);
    let server_max_active = Arc::clone(&max_active);
    let server = thread::spawn(move || {
        for _ in 0..2 {
            let (mut stream, _) = listener.accept().unwrap();
            let active = Arc::clone(&server_active);
            let max_active = Arc::clone(&server_max_active);
            let payload = payload.clone();
            thread::spawn(move || {
                let current = active.fetch_add(1, Ordering::SeqCst) + 1;
                max_active.fetch_max(current, Ordering::SeqCst);
                let mut buffer = [0; 2048];
                let _ = stream.read(&mut buffer).unwrap();
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    payload.len()
                );
                stream.write_all(response.as_bytes()).unwrap();
                for (index, chunk) in payload.chunks(16 * 1024).enumerate() {
                    if index + 1 == payload.len().div_ceil(16 * 1024) {
                        active.fetch_sub(1, Ordering::SeqCst);
                    }
                    if stream.write_all(chunk).is_err() {
                        break;
                    }
                    let _ = stream.flush();
                    thread::sleep(Duration::from_millis(20));
                }
            });
        }
    });

    let temp_dir = tempfile::tempdir().unwrap();
    let store_path = temp_dir.path().join("queue.json");
    let downloads_dir = temp_dir.path().join("downloads");
    for index in 0..2 {
        let add_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
            .args([
                "--store",
                store_path.to_str().unwrap(),
                "add",
                &format!("http://{address}/default-{index}.bin"),
                "--output",
                downloads_dir.to_str().unwrap(),
                "--name",
                &format!("default-{index}.bin"),
            ])
            .output()
            .unwrap();
        assert!(
            add_output.status.success(),
            "stderr: {}",
            String::from_utf8_lossy(&add_output.stderr)
        );
    }

    let run_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args(["--store", store_path.to_str().unwrap(), "run"])
        .output()
        .unwrap();

    server.join().unwrap();
    assert!(
        run_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&run_output.stderr)
    );
    let report: Value = serde_json::from_slice(&run_output.stdout).unwrap();
    assert_eq!(report["total_queued"], 2);
    assert_eq!(report["started"], 2);
    assert_eq!(report["finished"], 2);
    assert_eq!(max_active.load(Ordering::SeqCst), 1);
}

#[test]
fn queue_run_can_remove_running_task_from_separate_cli_process() {
    let payload = vec![b'z'; 512 * 1024];
    let total_bytes = payload.len() as u64;
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut buffer = [0; 2048];
        let _ = stream.read(&mut buffer).unwrap();
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            payload.len()
        );
        if stream.write_all(response.as_bytes()).is_err() {
            return;
        }
        for chunk in payload.chunks(16 * 1024) {
            if stream.write_all(chunk).is_err() {
                break;
            }
        }
    });

    let temp_dir = tempfile::tempdir().unwrap();
    let store_path = temp_dir.path().join("queue.json");
    let downloads_dir = temp_dir.path().join("downloads");
    let source = format!("http://{address}/delete-running.bin");
    let add_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "--store",
            store_path.to_str().unwrap(),
            "add",
            &source,
            "--output",
            downloads_dir.to_str().unwrap(),
            "--name",
            "delete-running.bin",
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

    let run_child = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "--store",
            store_path.to_str().unwrap(),
            "run",
            "--concurrency",
            "1",
            "--speed-limit-mbps",
            "0.05",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();

    let running = wait_for_running_progress(&store_path, &task_id);
    assert!(running["downloaded_bytes"].as_u64().unwrap() < total_bytes);

    let remove_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args(["--store", store_path.to_str().unwrap(), "remove", &task_id])
        .output()
        .unwrap();
    assert!(
        remove_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&remove_output.stderr)
    );
    let removed: Value = serde_json::from_slice(&remove_output.stdout).unwrap();
    assert_eq!(removed["id"], task_id);
    assert_eq!(removed["state"], "running");

    let run_output = wait_for_cli_output(run_child, Duration::from_secs(5));
    server.join().unwrap();
    assert!(
        run_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&run_output.stderr)
    );
    let report: Value = serde_json::from_slice(&run_output.stdout).unwrap();
    assert_eq!(report["started"], 1);
    assert_eq!(report["finished"], 0);
    assert_eq!(report["failed"], 0);
    assert_eq!(report["tasks"][0]["id"], task_id);
    assert_eq!(report["tasks"][0]["state"], "paused");

    let final_tasks = list_tasks(&store_path);
    assert!(
        final_tasks.as_array().unwrap().is_empty(),
        "removed running task should not be restored to the queue: {final_tasks}"
    );
}

#[test]
fn queue_run_can_pause_and_resume_running_task_from_separate_cli_process() {
    let payload = vec![b'x'; 512 * 1024];
    let total_bytes = payload.len() as u64;
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        for _ in 0..2 {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buffer = [0; 2048];
            let read = stream.read(&mut buffer).unwrap();
            let request = String::from_utf8_lossy(&buffer[..read]);
            let start = request
                .lines()
                .find_map(|line| {
                    let line = line.trim();
                    line.strip_prefix("Range: bytes=")
                        .or_else(|| line.strip_prefix("range: bytes="))
                })
                .and_then(|range| range.split('-').next())
                .and_then(|start| start.parse::<usize>().ok())
                .unwrap_or(0);
            let status = if start == 0 {
                "HTTP/1.1 200 OK".to_string()
            } else {
                format!(
                    "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {}-{}/{}",
                    start,
                    payload.len() - 1,
                    payload.len()
                )
            };
            let response = format!(
                "{status}\r\nAccept-Ranges: bytes\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                payload.len() - start
            );
            if stream.write_all(response.as_bytes()).is_err() {
                continue;
            }
            for chunk in payload[start..].chunks(16 * 1024) {
                if stream.write_all(chunk).is_err() {
                    break;
                }
            }
        }
    });

    let temp_dir = tempfile::tempdir().unwrap();
    let store_path = temp_dir.path().join("queue.json");
    let downloads_dir = temp_dir.path().join("downloads");
    let source = format!("http://{address}/slow.bin");
    let add_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "--store",
            store_path.to_str().unwrap(),
            "add",
            &source,
            "--output",
            downloads_dir.to_str().unwrap(),
            "--name",
            "slow.bin",
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

    let run_child = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "--store",
            store_path.to_str().unwrap(),
            "run",
            "--concurrency",
            "1",
            "--speed-limit-mbps",
            "0.05",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();

    let running = wait_for_running_progress(&store_path, &task_id);
    assert!(running["downloaded_bytes"].as_u64().unwrap() < total_bytes);

    let pause_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args(["--store", store_path.to_str().unwrap(), "pause", &task_id])
        .output()
        .unwrap();
    assert!(
        pause_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&pause_output.stderr)
    );
    let paused_by_command: Value = serde_json::from_slice(&pause_output.stdout).unwrap();
    assert_eq!(paused_by_command["state"], "paused");

    let run_output = wait_for_cli_output(run_child, Duration::from_secs(5));
    assert!(
        run_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&run_output.stderr)
    );
    let report: Value = serde_json::from_slice(&run_output.stdout).unwrap();
    assert_eq!(report["started"], 1);
    assert_eq!(report["finished"], 0);
    assert_eq!(report["failed"], 0);
    assert_eq!(report["tasks"][0]["state"], "paused");

    let final_task = list_task(&store_path, &task_id);
    assert_eq!(final_task["state"], "paused");
    let downloaded = final_task["downloaded_bytes"].as_u64().unwrap();
    assert!(downloaded > 0, "paused task should keep partial progress");
    assert!(
        downloaded < total_bytes,
        "paused task should not finish before pause"
    );
    let partial_size = std::fs::metadata(downloads_dir.join("slow.bin"))
        .unwrap()
        .len();
    assert_eq!(partial_size, downloaded);

    let resume_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args(["--store", store_path.to_str().unwrap(), "resume", &task_id])
        .output()
        .unwrap();
    assert!(
        resume_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&resume_output.stderr)
    );
    let resumed: Value = serde_json::from_slice(&resume_output.stdout).unwrap();
    assert_eq!(resumed["state"], "queued");

    let rerun_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
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
        rerun_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&rerun_output.stderr)
    );
    let rerun_report: Value = serde_json::from_slice(&rerun_output.stdout).unwrap();
    assert_eq!(rerun_report["started"], 1);
    assert_eq!(rerun_report["finished"], 1);
    assert_eq!(rerun_report["failed"], 0);
    assert_eq!(rerun_report["tasks"][0]["state"], "finished");

    let finished_task = list_task(&store_path, &task_id);
    assert_eq!(finished_task["state"], "finished");
    assert_eq!(finished_task["downloaded_bytes"], total_bytes);
    assert_eq!(
        std::fs::read(downloads_dir.join("slow.bin")).unwrap(),
        vec![b'x'; total_bytes as usize]
    );
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
fn queue_run_retries_once_by_default() {
    let payload = b"fluxdown-cli-default-retry";
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
    let source = format!("http://{address}/default-retry.bin");

    let add_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "--store",
            store_path.to_str().unwrap(),
            "add",
            &source,
            "--output",
            downloads_dir.to_str().unwrap(),
            "--name",
            "default-retry.bin",
        ])
        .output()
        .unwrap();
    assert!(
        add_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&add_output.stderr)
    );

    let run_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args(["--store", store_path.to_str().unwrap(), "run"])
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
        std::fs::read(downloads_dir.join("default-retry.bin")).unwrap(),
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

#[test]
fn download_command_fetches_ipfs_file_through_custom_gateway() {
    let cid = "bafkreidfdrlkeq4m4xnxuyx6iae76fdm4wgl5d4xzsb77ixhyqwumhz244";
    let payload = b"Hello IPFS";
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut buffer = [0; 1024];
        let read = stream.read(&mut buffer).unwrap();
        let request = String::from_utf8_lossy(&buffer[..read]);
        assert!(request.starts_with(&format!("GET /ipfs/{cid}/readme.txt ")));
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            payload.len()
        );
        stream.write_all(response.as_bytes()).unwrap();
        stream.write_all(payload).unwrap();
    });

    let temp_dir = tempfile::tempdir().unwrap();
    let gateway = format!("http%3A%2F%2F{address}");
    let output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "download",
            &format!("ipfs://{cid}/readme.txt?gateway={gateway}"),
            "--output",
            temp_dir.path().to_str().unwrap(),
            "--name",
            "ipfs-local.txt",
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
        std::fs::read(temp_dir.path().join("ipfs-local.txt")).unwrap(),
        payload
    );

    let summary: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(summary["protocol"], "ipfs");
    assert_eq!(summary["backend"], "built-in");
    assert_eq!(summary["bytes_written"], payload.len() as u64);
}
