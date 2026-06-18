use fluxdown_core::{DownloadRequest, DownloadState, TaskStore};
use serde_json::Value;
use std::io::{ErrorKind, Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
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

#[cfg(target_os = "macos")]
#[test]
fn queue_commands_use_macos_native_default_store_path() {
    let temp_dir = tempfile::tempdir().unwrap();
    let home_dir = temp_dir.path().join("home");
    let downloads_dir = temp_dir.path().join("downloads");
    let native_store = home_dir
        .join("Library")
        .join("Application Support")
        .join("FluxDown")
        .join("queue.json");
    let legacy_store = home_dir
        .join(".local")
        .join("share")
        .join("fluxdown")
        .join("queue.json");

    let add_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .env("HOME", &home_dir)
        .env_remove("XDG_DATA_HOME")
        .args([
            "add",
            "http://127.0.0.1:9/native-store.bin",
            "--output",
            downloads_dir.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(
        add_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&add_output.stderr)
    );

    // 作者: long
    // macOS CLI 默认队列应落在 Application Support，避免桌面端和命令行继续分裂到旧 Unix 路径。
    assert!(native_store.exists(), "missing {}", native_store.display());
    assert!(
        !legacy_store.exists(),
        "new CLI task should not create legacy store {}",
        legacy_store.display()
    );

    let list_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .env("HOME", &home_dir)
        .env_remove("XDG_DATA_HOME")
        .args(["list"])
        .output()
        .unwrap();
    assert!(
        list_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&list_output.stderr)
    );
    let listed: Value = serde_json::from_slice(&list_output.stdout).unwrap();
    assert_eq!(listed.as_array().unwrap().len(), 1);
    assert_eq!(listed[0]["state"], "queued");
    assert_eq!(listed[0]["source"], "http://127.0.0.1:9/native-store.bin");
}

#[cfg(target_os = "macos")]
#[test]
fn queue_commands_migrate_legacy_macos_store_on_next_write() {
    let temp_dir = tempfile::tempdir().unwrap();
    let home_dir = temp_dir.path().join("home");
    let downloads_dir = temp_dir.path().join("downloads");
    let native_store = home_dir
        .join("Library")
        .join("Application Support")
        .join("FluxDown")
        .join("queue.json");
    let legacy_store = home_dir
        .join(".local")
        .join("share")
        .join("fluxdown")
        .join("queue.json");

    let legacy_add = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "--store",
            legacy_store.to_str().unwrap(),
            "add",
            "http://127.0.0.1:9/legacy.bin",
            "--output",
            downloads_dir.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(
        legacy_add.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&legacy_add.stderr)
    );
    assert!(legacy_store.exists(), "missing {}", legacy_store.display());
    assert!(!native_store.exists());

    let legacy_list = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .env("HOME", &home_dir)
        .env_remove("XDG_DATA_HOME")
        .args(["list"])
        .output()
        .unwrap();
    assert!(
        legacy_list.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&legacy_list.stderr)
    );
    let legacy_tasks: Value = serde_json::from_slice(&legacy_list.stdout).unwrap();
    assert_eq!(legacy_tasks.as_array().unwrap().len(), 1);
    assert_eq!(legacy_tasks[0]["source"], "http://127.0.0.1:9/legacy.bin");

    let native_add = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .env("HOME", &home_dir)
        .env_remove("XDG_DATA_HOME")
        .args([
            "add",
            "http://127.0.0.1:9/native.bin",
            "--output",
            downloads_dir.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(
        native_add.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&native_add.stderr)
    );

    // 作者: long
    // 旧版 macOS 队列不能在升级后丢失；下一次默认写入必须把旧任务带到 Application Support 队列里。
    assert!(native_store.exists(), "missing {}", native_store.display());
    let migrated_list = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .env("HOME", &home_dir)
        .env_remove("XDG_DATA_HOME")
        .args(["list"])
        .output()
        .unwrap();
    assert!(
        migrated_list.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&migrated_list.stderr)
    );
    let migrated_tasks: Value = serde_json::from_slice(&migrated_list.stdout).unwrap();
    let sources = migrated_tasks
        .as_array()
        .unwrap()
        .iter()
        .map(|task| task["source"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(sources.len(), 2);
    assert!(sources.contains(&"http://127.0.0.1:9/legacy.bin"));
    assert!(sources.contains(&"http://127.0.0.1:9/native.bin"));
}

#[tokio::test]
async fn queue_resume_recovers_stale_running_task_before_transition() {
    let temp_dir = tempfile::tempdir().unwrap();
    let store_path = temp_dir.path().join("queue.json");
    let store = TaskStore::new(&store_path);
    let task = store
        .enqueue(DownloadRequest::new(
            "http://127.0.0.1:9/stale-resume.bin",
            temp_dir.path(),
        ))
        .await
        .unwrap();
    let mut running_task = task;
    running_task.set_state(DownloadState::Running);
    running_task.set_progress_with_speed(256, Some(1024), 128);
    running_task.updated_at_ms = 0;
    store.update(running_task.clone()).await.unwrap();

    let resume_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "--store",
            store_path.to_str().unwrap(),
            "resume",
            &running_task.id,
        ])
        .output()
        .unwrap();
    assert!(
        resume_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&resume_output.stderr)
    );
    let resumed: Value = serde_json::from_slice(&resume_output.stdout).unwrap();

    // 作者: long
    // 终端恢复命令要能直接处理上次异常退出留下的 running，避免用户必须先 list 一次才可继续。
    assert_eq!(resumed["state"], "queued");
    assert_eq!(resumed["downloaded_bytes"], 256);
    assert_eq!(resumed["error"], Value::Null);
    assert_eq!(list_task(&store_path, &running_task.id)["state"], "queued");
}

#[tokio::test]
async fn queue_pause_recovers_stale_running_task_before_transition() {
    let temp_dir = tempfile::tempdir().unwrap();
    let store_path = temp_dir.path().join("queue.json");
    let store = TaskStore::new(&store_path);
    let task = store
        .enqueue(DownloadRequest::new(
            "http://127.0.0.1:9/stale-pause.bin",
            temp_dir.path(),
        ))
        .await
        .unwrap();
    let mut running_task = task;
    running_task.set_state(DownloadState::Running);
    running_task.set_progress_with_speed(384, Some(1024), 192);
    running_task.updated_at_ms = 0;
    store.update(running_task.clone()).await.unwrap();

    let pause_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "--store",
            store_path.to_str().unwrap(),
            "pause",
            &running_task.id,
        ])
        .output()
        .unwrap();
    assert!(
        pause_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&pause_output.stderr)
    );
    let paused: Value = serde_json::from_slice(&pause_output.stdout).unwrap();

    // 作者: long
    // 暂停命令也要能接管异常退出留下的 running，让用户看到真实可恢复的暂停态和中断原因。
    assert_eq!(paused["state"], "paused");
    assert_eq!(paused["downloaded_bytes"], 384);
    assert_eq!(paused["error"], "任务中断，已暂停，可继续下载");
    assert_eq!(list_task(&store_path, &running_task.id)["state"], "paused");
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

fn read_http_request(stream: &mut TcpStream) -> std::io::Result<String> {
    let mut buffer = Vec::with_capacity(2048);
    let mut chunk = [0; 512];
    loop {
        let read = stream.read(&mut chunk)?;
        if read == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..read]);
        if buffer.windows(4).any(|window| window == b"\r\n\r\n") {
            break;
        }
    }
    Ok(String::from_utf8_lossy(&buffer).into_owned())
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

fn spawn_checked_http_server(
    payload: &'static [u8],
    expected_path: &'static str,
) -> (String, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut buffer = [0; 1024];
        let read = stream.read(&mut buffer).unwrap();
        let request = String::from_utf8_lossy(&buffer[..read]);
        assert!(request.starts_with(&format!("GET {expected_path} ")));
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            payload.len()
        );
        stream.write_all(response.as_bytes()).unwrap();
        stream.write_all(payload).unwrap();
    });
    (address.to_string(), server)
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
        "webdavs"
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
fn detect_command_outputs_stable_protocol_names() {
    let cases = [
        ("http://example.com/a.bin", "http"),
        ("https://example.com/a.bin", "https"),
        (
            "webdav://cloud.example.com/remote.php/dav/files/a.zip",
            "webdav",
        ),
        (
            "webdavs://cloud.example.com/remote.php/dav/files/a.zip",
            "webdavs",
        ),
        ("ftp://example.com/file.iso", "ftp"),
        ("ftps://example.com/file.iso", "ftps"),
        ("sftp://example.com/file.iso", "sftp"),
        ("smb://nas/share/file.iso", "smb"),
        ("ipfs://bafybeigdyrzt/readme.txt", "ipfs"),
        ("magnet:?xt=urn:btih:abc", "magnet"),
        ("ed2k://|file|x|1|hash|/", "ed2k"),
        ("https://example.com/file.torrent?token=abc", "torrent"),
        ("https://example.com/video.m3u8?token=abc", "m3u8"),
        ("/tmp/local.TORRENT", "torrent"),
        ("not-a-download-source", "unknown"),
    ];

    for (source, expected) in cases {
        let output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
            .args(["detect", source])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "source: {source}; stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(
            String::from_utf8_lossy(&output.stdout).trim(),
            expected,
            "{source}"
        );
    }
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
            // 作者: long
            // listener 为了轮询退出使用非阻塞模式；已接受连接要切回阻塞写入，避免 Range body 偶发只写入一部分。
            stream
                .set_nonblocking(false)
                .expect("accepted range fixture stream should use blocking writes");
            let handler_payload = Arc::clone(&server_payload);
            let handler_range_hits = Arc::clone(&server_range_hits);
            // 作者: long
            // 多线程下载会同时打开多个 Range 连接，fixture 也要并发响应，才能稳定验证真实客户端行为。
            handlers.push(thread::spawn(move || {
                let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
                let request = match read_http_request(&mut stream) {
                    Ok(request) if request.is_empty() => return,
                    Ok(request) => request,
                    Err(error) if error.kind() == ErrorKind::WouldBlock => return,
                    Err(error) if error.kind() == ErrorKind::TimedOut => return,
                    Err(error) => panic!("test fixture failed to read request: {error}"),
                };
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
                    let _ = stream.flush();
                    let _ = stream.shutdown(Shutdown::Write);
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
                let _ = stream.flush();
                let _ = stream.shutdown(Shutdown::Write);
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
    let expected_sha256 = "671e23b189bb7a2041eff1b29f077b4e59460d30db56248fdcccafa012babfc8";
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
            "--sha256",
            expected_sha256,
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
    assert_eq!(summary["sha256"], expected_sha256);
    assert_eq!(
        summary["output_path"].as_str().unwrap(),
        temp_dir.path().join("payload.bin").to_string_lossy()
    );
}

#[test]
fn download_command_fails_when_sha256_mismatches() {
    let payload = b"fluxdown-cli-direct-download";
    let wrong_sha256 = "8810ad581e59f2bc3928b261707a71308f7e139eb04820366dc4d5c18d980225";
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
            "--sha256",
            wrong_sha256,
        ])
        .output()
        .unwrap();

    server.join().unwrap();
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("SHA-256 mismatch"), "{stderr}");
    assert!(stderr.contains(wrong_sha256), "{stderr}");
}

#[test]
fn download_command_rejects_invalid_sha256_before_restart_cleanup() {
    let temp_dir = tempfile::tempdir().unwrap();
    let output_path = temp_dir.path().join("payload.bin");
    std::fs::write(&output_path, b"keep-existing-output").unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "download",
            "http://127.0.0.1:9/payload.bin",
            "--output",
            temp_dir.path().to_str().unwrap(),
            "--name",
            "payload.bin",
            "--sha256",
            "not-a-sha256",
            "--restart",
        ])
        .output()
        .unwrap();

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("invalid SHA-256 checksum"), "{stderr}");
    assert_eq!(
        std::fs::read(&output_path).unwrap(),
        b"keep-existing-output"
    );
}

#[test]
fn download_command_sanitizes_requested_output_name() {
    let payload = b"fluxdown-cli-safe-name";
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
    let output_dir = temp_dir.path().join("downloads");
    let output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "download",
            &format!("http://{address}/file.bin"),
            "--output",
            output_dir.to_str().unwrap(),
            "--name",
            "../outside:name?.bin",
        ])
        .output()
        .unwrap();

    server.join().unwrap();
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let safe_path = output_dir.join("_outside_name_.bin");
    assert_eq!(std::fs::read(&safe_path).unwrap(), payload);
    assert!(!temp_dir.path().join("outside:name?.bin").exists());

    let summary: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(
        summary["output_path"].as_str().unwrap(),
        safe_path.to_string_lossy()
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
fn queue_start_runs_hls_task() {
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
            "start-hls.m3u8",
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

    let start_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args(["--store", store_path.to_str().unwrap(), "start", &task_id])
        .output()
        .unwrap();

    server.join().unwrap();
    assert!(
        start_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&start_output.stderr)
    );
    assert_eq!(
        std::fs::read(downloads_dir.join("start-hls.ts")).unwrap(),
        expected_payload
    );

    let report: Value = serde_json::from_slice(&start_output.stdout).unwrap();
    assert_eq!(report["task"]["id"], task_id);
    assert_eq!(report["task"]["state"], "finished");
    assert_eq!(report["task"]["file_name"], "start-hls.ts");
    assert_eq!(
        report["summary"]["segments_written"], 2,
        "CLI start should expose the HLS segment summary"
    );

    let final_list = list_tasks(&store_path);
    // 作者: long
    // CLI start 是单任务入口，HLS 完成后也要把 .m3u8 替换成最终产物名，保持脚本和队列页语义一致。
    assert_eq!(final_list[0]["file_name"], "start-hls.ts");
    assert_eq!(
        final_list[0]["downloaded_bytes"],
        expected_payload.len() as u64
    );
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
    let expected_sha256 = "dc5c62fa4e33d514df73305388ed24022ba3823d7529bc13a97a749bc9f505b3";
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
            "--sha256",
            expected_sha256,
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
    assert_eq!(added["expected_sha256"], expected_sha256);

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
    assert_eq!(listed[0]["expected_sha256"], expected_sha256);

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
    assert_eq!(report["tasks"][0]["expected_sha256"], expected_sha256);

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
    assert_eq!(final_list[0]["expected_sha256"], expected_sha256);

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
fn queue_add_persists_torrent_file_indices() {
    let temp_dir = tempfile::tempdir().unwrap();
    let store_path = temp_dir.path().join("queue.json");
    let downloads_dir = temp_dir.path().join("downloads");

    let add_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "--store",
            store_path.to_str().unwrap(),
            "add",
            "/tmp/multi-file.torrent",
            "--output",
            downloads_dir.to_str().unwrap(),
            "--name",
            "multi-file.torrent",
            "--torrent-file-index",
            "2",
            "--torrent-file-index",
            "0",
            "--torrent-file-index",
            "2",
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
    assert_eq!(added["protocol"], "torrent");
    assert_eq!(added["torrent_file_indices"], serde_json::json!([0, 2]));

    let listed = list_task(&store_path, &task_id);
    assert_eq!(listed["torrent_file_indices"], serde_json::json!([0, 2]));
}

#[test]
fn queue_add_rejects_invalid_sha256_without_writing_queue() {
    let temp_dir = tempfile::tempdir().unwrap();
    let store_path = temp_dir.path().join("queue.json");
    let downloads_dir = temp_dir.path().join("downloads");

    let add_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "--store",
            store_path.to_str().unwrap(),
            "add",
            "http://127.0.0.1:9/queued.bin",
            "--output",
            downloads_dir.to_str().unwrap(),
            "--name",
            "queued.bin",
            "--sha256",
            "not-a-sha256",
        ])
        .output()
        .unwrap();

    assert!(!add_output.status.success());
    let stderr = String::from_utf8_lossy(&add_output.stderr);
    assert!(stderr.contains("invalid SHA-256 checksum"), "{stderr}");
    assert!(
        !store_path.exists(),
        "invalid add must not create a queue file"
    );
}

#[test]
fn queue_run_marks_task_failed_when_sha256_mismatches() {
    let payload = b"fluxdown-cli-queued-download";
    let wrong_sha256 = "8810ad581e59f2bc3928b261707a71308f7e139eb04820366dc4d5c18d980225";
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
            "--sha256",
            wrong_sha256,
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
            "0",
        ])
        .output()
        .unwrap();

    server.join().unwrap();
    assert!(
        run_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&run_output.stderr)
    );
    let report: Value = serde_json::from_slice(&run_output.stdout).unwrap();
    assert_eq!(report["finished"], 0);
    assert_eq!(report["failed"], 1);
    assert_eq!(report["tasks"][0]["state"], "failed");
    let error = report["tasks"][0]["error"].as_str().unwrap();
    assert!(error.contains("SHA-256 mismatch"), "{error}");
    assert!(error.contains(wrong_sha256), "{error}");
}

#[test]
fn queue_commands_redact_url_credentials_from_json_output() {
    let temp_dir = tempfile::tempdir().unwrap();
    let store_path = temp_dir.path().join("queue.json");
    let downloads_dir = temp_dir.path().join("downloads");
    let source = "ftp://user:p%40ss@example.com/private/file.bin";

    let add_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "--store",
            store_path.to_str().unwrap(),
            "add",
            source,
            "--output",
            downloads_dir.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(
        add_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&add_output.stderr)
    );
    let add_stdout = String::from_utf8_lossy(&add_output.stdout);
    let added: Value = serde_json::from_str(&add_stdout).unwrap();
    assert_eq!(
        added["source"],
        "ftp://***:***@example.com/private/file.bin"
    );
    assert!(!add_stdout.contains("user"));
    assert!(!add_stdout.contains("p%40ss"));

    let list_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args(["--store", store_path.to_str().unwrap(), "list"])
        .output()
        .unwrap();
    assert!(
        list_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&list_output.stderr)
    );
    let list_stdout = String::from_utf8_lossy(&list_output.stdout);
    let listed: Value = serde_json::from_str(&list_stdout).unwrap();
    assert_eq!(
        listed[0]["source"],
        "ftp://***:***@example.com/private/file.bin"
    );
    assert!(!list_stdout.contains("user"));
    assert!(!list_stdout.contains("p%40ss"));

    let raw_store = std::fs::read_to_string(&store_path).unwrap();
    assert!(raw_store.contains(source));
}

#[test]
fn queue_commands_redact_magnet_tracker_credentials_from_json_output() {
    let temp_dir = tempfile::tempdir().unwrap();
    let store_path = temp_dir.path().join("queue.json");
    let downloads_dir = temp_dir.path().join("downloads");
    let source =
        "magnet:?xt=urn:btih:abc&tr=https%3A%2F%2Fuser%3Ap%2540ss%40tracker.example.com%2Fannounce";

    let add_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "--store",
            store_path.to_str().unwrap(),
            "add",
            source,
            "--output",
            downloads_dir.to_str().unwrap(),
            "--name",
            "magnet-download",
        ])
        .output()
        .unwrap();
    assert!(
        add_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&add_output.stderr)
    );
    let add_stdout = String::from_utf8_lossy(&add_output.stdout);
    let added: Value = serde_json::from_str(&add_stdout).unwrap();
    assert!(added["source"].as_str().unwrap().contains("***"));
    assert!(!add_stdout.contains("user"));
    assert!(!add_stdout.contains("p%2540ss"));

    let list_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args(["--store", store_path.to_str().unwrap(), "list"])
        .output()
        .unwrap();
    assert!(
        list_output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&list_output.stderr)
    );
    let list_stdout = String::from_utf8_lossy(&list_output.stdout);
    let listed: Value = serde_json::from_str(&list_stdout).unwrap();
    assert!(listed[0]["source"].as_str().unwrap().contains("***"));
    assert!(!list_stdout.contains("user"));
    assert!(!list_stdout.contains("p%2540ss"));

    let raw_store = std::fs::read_to_string(&store_path).unwrap();
    assert!(raw_store.contains(source));
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
fn queue_commands_add_and_run_webdav_task() {
    let payload = b"fluxdown-cli-queued-webdav";
    let (address, server) =
        spawn_checked_http_server(payload, "/remote.php/dav/files/queue-webdav.bin");
    let temp_dir = tempfile::tempdir().unwrap();
    let store_path = temp_dir.path().join("queue.json");
    let downloads_dir = temp_dir.path().join("downloads");

    let add_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "--store",
            store_path.to_str().unwrap(),
            "add",
            &format!("webdav://{address}/remote.php/dav/files/queue-webdav.bin"),
            "--output",
            downloads_dir.to_str().unwrap(),
            "--name",
            "queue-webdav.txt",
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
    assert_eq!(added["protocol"], "webdav");

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
        std::fs::read(downloads_dir.join("queue-webdav.txt")).unwrap(),
        payload
    );

    let report: Value = serde_json::from_slice(&run_output.stdout).unwrap();
    assert_eq!(report["finished"], 1);
    assert_eq!(report["failed"], 0);
    assert_eq!(report["tasks"][0]["id"], task_id);
    assert_eq!(report["tasks"][0]["state"], "finished");
    assert_eq!(report["tasks"][0]["file_name"], "queue-webdav.txt");

    let final_list = list_tasks(&store_path);
    // 作者: long
    // WebDAV 在队列里走 HTTP 传输映射，完成后仍要像普通任务一样保留用户指定的保存文件名。
    assert_eq!(final_list[0]["file_name"], "queue-webdav.txt");
    assert_eq!(final_list[0]["downloaded_bytes"], payload.len() as u64);
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

#[test]
fn queue_commands_add_and_run_ipfs_task_through_custom_gateway() {
    let cid = "bafkreidfdrlkeq4m4xnxuyx6iae76fdm4wgl5d4xzsb77ixhyqwumhz244";
    let payload = b"Hello queued IPFS";
    let (address, server) = spawn_checked_http_server(
        payload,
        "/ipfs/bafkreidfdrlkeq4m4xnxuyx6iae76fdm4wgl5d4xzsb77ixhyqwumhz244/readme.txt",
    );
    let temp_dir = tempfile::tempdir().unwrap();
    let store_path = temp_dir.path().join("queue.json");
    let downloads_dir = temp_dir.path().join("downloads");
    let gateway = format!("http%3A%2F%2F{address}");

    let add_output = Command::new(env!("CARGO_BIN_EXE_fluxdown"))
        .args([
            "--store",
            store_path.to_str().unwrap(),
            "add",
            &format!("ipfs://{cid}/readme.txt?gateway={gateway}"),
            "--output",
            downloads_dir.to_str().unwrap(),
            "--name",
            "queue-ipfs.txt",
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
    assert_eq!(added["protocol"], "ipfs");

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
        std::fs::read(downloads_dir.join("queue-ipfs.txt")).unwrap(),
        payload
    );

    let report: Value = serde_json::from_slice(&run_output.stdout).unwrap();
    assert_eq!(report["finished"], 1);
    assert_eq!(report["failed"], 0);
    assert_eq!(report["tasks"][0]["id"], task_id);
    assert_eq!(report["tasks"][0]["state"], "finished");
    assert_eq!(report["tasks"][0]["file_name"], "queue-ipfs.txt");

    let final_list = list_tasks(&store_path);
    // 作者: long
    // IPFS 自定义 gateway 是离线可控验证入口，队列执行必须保留 gateway 映射后的真实下载结果。
    assert_eq!(final_list[0]["file_name"], "queue-ipfs.txt");
    assert_eq!(final_list[0]["downloaded_bytes"], payload.len() as u64);
}
