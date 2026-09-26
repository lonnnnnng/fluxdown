//! FluxDown FFI：把 Rust 下载核心暴露给移动端（Flutter `dart:ffi`）使用。
//!
//! 约定：
//! - 所有导出函数接收/返回 UTF-8 JSON 字符串（`char*`），调用方通过
//!   `fluxdown_string_free` 释放返回值，输入字符串由调用方持有并释放。
//! - 每个返回值都是统一信封：`{"ok":true,"data":...}` 或 `{"ok":false,"error":"..."}`，
//!   解析失败/panic 都收敛为 ok=false，保证跨语言边界不抛异常。
//! - 异步能力通过常驻 tokio 多线程运行时驱动，FFI 调用本身保持同步签名。

use std::{
    collections::{HashMap, HashSet},
    ffi::{CStr, CString},
    os::raw::{c_char, c_int},
    sync::{
        Arc, Mutex as StdMutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
    time::{SystemTime, UNIX_EPOCH},
};

use fluxdown_core::{
    DEFAULT_DOWNLOAD_THREAD_COUNT, DEFAULT_QUEUE_CONCURRENCY, DEFAULT_RETRY_ATTEMPTS,
    DownloadOptions, DownloadRequest, DownloadState, QueueRunner, QueueRunnerOptions, TaskStore,
    TorrentFileMetadata, default_store_path, detect_protocol, runtime_support_status,
};
use serde_json::json;
use tokio::{runtime::Runtime, sync::Mutex};

static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static QUEUE_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
static ASYNC_RUNS: OnceLock<StdMutex<HashMap<String, Arc<StdMutex<AsyncRunState>>>>> =
    OnceLock::new();
static ACTIVE_QUEUED_STORES: OnceLock<StdMutex<HashSet<String>>> = OnceLock::new();
static NEXT_ASYNC_RUN_ID: AtomicU64 = AtomicU64::new(1);

enum AsyncRunState {
    Running,
    Finished(serde_json::Value),
    Failed(String),
}

fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("fluxdown ffi tokio runtime")
    })
}

fn queue_lock() -> &'static Mutex<()> {
    QUEUE_LOCK.get_or_init(|| Mutex::new(()))
}

fn async_runs() -> &'static StdMutex<HashMap<String, Arc<StdMutex<AsyncRunState>>>> {
    ASYNC_RUNS.get_or_init(|| StdMutex::new(HashMap::new()))
}

fn active_queued_stores() -> &'static StdMutex<HashSet<String>> {
    ACTIVE_QUEUED_STORES.get_or_init(|| StdMutex::new(HashSet::new()))
}

fn next_async_run_id() -> String {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or_default();
    let sequence = NEXT_ASYNC_RUN_ID.fetch_add(1, Ordering::Relaxed);
    format!("run-{millis}-{sequence}")
}

fn cstr_to_string(pointer: *const c_char) -> String {
    if pointer.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(pointer) }
        .to_string_lossy()
        .into_owned()
}

fn string_to_cstr(value: String) -> *mut c_char {
    // 作者: long
    // CString 不能包含内部 NUL；JSON 序列化不会产生 NUL，这里兜底替换避免 UB。
    let sanitized = value.replace('\0', " ");
    match CString::new(sanitized) {
        Ok(value) => value.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

fn envelope<T: serde::Serialize>(result: Result<T, String>) -> String {
    match result {
        Ok(data) => json!({ "ok": true, "data": data }).to_string(),
        Err(error) => json!({ "ok": false, "error": error }).to_string(),
    }
}

/// 释放 FFI 返回的字符串。传入非本模块分配的指针是未定义行为。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdown_string_free(pointer: *mut c_char) {
    if pointer.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(pointer));
    }
}

/// 协议识别：`{"ok":true,"data":{"protocol":"https","support":{...}}}`。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdown_detect(source: *const c_char) -> *mut c_char {
    let source = cstr_to_string(source);
    let protocol = detect_protocol(&source);
    let output = runtime().block_on(async {
        let support = runtime_support_status(protocol).await;
        json!({ "protocol": protocol.as_str(), "support": support })
    });
    string_to_cstr(envelope::<serde_json::Value>(Ok(output)))
}

/// 协议运行时支持状态。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdown_support(source: *const c_char) -> *mut c_char {
    let source = cstr_to_string(source);
    let output = runtime().block_on(async {
        serde_json::to_value(runtime_support_status(detect_protocol(&source)).await)
            .unwrap_or(serde_json::Value::Null)
    });
    string_to_cstr(envelope::<serde_json::Value>(Ok(output)))
}

/// 队列列表：`data` 为统一任务 schema 数组（与桌面端 serde JSON 对齐）。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdown_queue_list(store_path: *const c_char) -> *mut c_char {
    let store_path = cstr_to_string(store_path);
    let output = runtime().block_on(async {
        let _guard = queue_lock().lock().await;
        let store = open_store(&store_path);
        store
            .recover_stale_running(std::time::Duration::from_secs(5 * 60))
            .await
            .map_err(|error| error.to_string())?;
        let tasks = store.list().await.map_err(|error| error.to_string())?;
        serde_json::to_value(tasks).map_err(|error| error.to_string())
    });
    string_to_cstr(envelope::<serde_json::Value>(output))
}

/// 入队任务：`request_json` 为统一任务请求对象
/// `{"source":..,"outputDir":..,"fileName":..,"expectedSha256":..,"torrentFileIndices":[..],"torrentName":..,"torrentFiles":[..],"speedLimitMbps":..,"hlsVariantIndex":..,"hlsKeepTransportStream":..}`。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdown_queue_add(
    store_path: *const c_char,
    request_json: *const c_char,
) -> *mut c_char {
    let store_path = cstr_to_string(store_path);
    let request_json = cstr_to_string(request_json);
    let output = runtime().block_on(async {
        let _guard = queue_lock().lock().await;
        let payload: serde_json::Value = serde_json::from_str(&request_json)
            .map_err(|error| format!("请求 JSON 无法解析: {error}"))?;
        let source = payload
            .get("source")
            .and_then(|value| value.as_str())
            .ok_or_else(|| "缺少 source 字段".to_string())?
            .to_string();
        let output_dir = payload
            .get("outputDir")
            .and_then(|value| value.as_str())
            .map(std::path::PathBuf::from)
            .unwrap_or_else(default_store_path_dir);
        let mut request = DownloadRequest::new(source, output_dir);
        if let Some(name) = payload.get("fileName").and_then(|value| value.as_str()) {
            request.file_name = Some(name.to_string());
        }
        if let Some(sha) = payload
            .get("expectedSha256")
            .and_then(|value| value.as_str())
        {
            request.expected_sha256 = fluxdown_core::validate_sha256_text(sha)
                .map_err(|error| format!("SHA-256 无效: {error}"))
                .map(Some)?;
        }
        if let Some(indices) = payload
            .get("torrentFileIndices")
            .and_then(|value| value.as_array())
        {
            request.torrent_file_indices = indices
                .iter()
                .filter_map(|value| value.as_u64().map(|value| value as usize))
                .collect();
        }
        if let Some(name) = payload.get("torrentName").and_then(|value| value.as_str()) {
            request.torrent_name = Some(name.to_string());
        }
        if let Some(files) = payload
            .get("torrentFiles")
            .and_then(|value| value.as_array())
        {
            // 作者: long
            // 移动端和桌面端通过 FFI 传递同一份文件树；字段同时兼容 camelCase 与 snake_case，
            // 这样升级后的调用方可以读取旧版本生成的队列而无需转换文件。
            request.torrent_files = files
                .iter()
                .filter_map(|value| {
                    let object = value.as_object()?;
                    let index = object.get("index").and_then(|value| value.as_u64())? as usize;
                    let path = object
                        .get("path")
                        .and_then(|value| value.as_str())?
                        .to_string();
                    let name = object
                        .get("name")
                        .and_then(|value| value.as_str())?
                        .to_string();
                    let size = object.get("size").and_then(|value| value.as_u64())?;
                    let is_streamable = object
                        .get("isStreamable")
                        .or_else(|| object.get("is_streamable"))
                        .and_then(|value| value.as_bool())
                        .unwrap_or(false);
                    Some(TorrentFileMetadata {
                        index,
                        path,
                        name,
                        size,
                        is_streamable,
                    })
                })
                .collect();
        }
        if let Some(limit) = payload
            .get("speedLimitMbps")
            .and_then(|value| value.as_f64())
        {
            request.speed_limit_mbps = Some(limit);
        }
        // 作者: long
        // HLS 的清晰度和输出格式必须随任务保存，移动端或其他 FFI 调用方重启后才能复用同一选择。
        if let Some(index) = payload
            .get("hlsVariantIndex")
            .and_then(|value| value.as_u64())
        {
            request.hls_variant_index = Some(index as usize);
        }
        if let Some(keep_ts) = payload
            .get("hlsKeepTransportStream")
            .and_then(|value| value.as_bool())
        {
            request.hls_keep_transport_stream = Some(keep_ts);
        }
        let task = open_store(&store_path)
            .enqueue(request)
            .await
            .map_err(|error| error.to_string())?;
        serde_json::to_value(task).map_err(|error| error.to_string())
    });
    string_to_cstr(envelope::<serde_json::Value>(output))
}

/// 启动指定任务并等待结束（供移动端“点击任务开始/继续”使用）。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdown_queue_run(
    store_path: *const c_char,
    task_id: *const c_char,
) -> *mut c_char {
    let store_path = cstr_to_string(store_path);
    let task_id = cstr_to_string(task_id);
    let output = runtime().block_on(async {
        let _guard = queue_lock().lock().await;
        let store = open_store(&store_path);
        let report = QueueRunner::new(store)
            .run_task_with_options(&task_id, QueueRunnerOptions::default())
            .await
            .map_err(|error| error.to_string())?;
        serde_json::to_value(report).map_err(|error| error.to_string())
    });
    string_to_cstr(envelope::<serde_json::Value>(output))
}

/// 启动非阻塞任务，返回 `{"runId":"..."}`；下载状态继续通过 queue_list 读取真实任务进度。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdown_queue_run_async(
    store_path: *const c_char,
    task_id: *const c_char,
) -> *mut c_char {
    let store_path = cstr_to_string(store_path);
    let task_id = cstr_to_string(task_id);
    let run_id = next_async_run_id();
    let state = Arc::new(StdMutex::new(AsyncRunState::Running));
    {
        let mut runs = async_runs().lock().expect("async run registry poisoned");
        runs.insert(run_id.clone(), Arc::clone(&state));
    }

    runtime().spawn(async move {
        // 作者: long
        // 异步任务不持有 FFI 全局锁，否则 pause/resume 无法在下载期间写入任务状态；TaskStore 自身的进程锁负责并发落盘。
        let result = {
            let store = open_store(&store_path);
            QueueRunner::new(store)
                .run_task_with_options(&task_id, QueueRunnerOptions::default())
                .await
                .map_err(|error| error.to_string())
                .and_then(|report| serde_json::to_value(report).map_err(|error| error.to_string()))
        };
        let mut current = state.lock().expect("async run state poisoned");
        *current = match result {
            Ok(report) => AsyncRunState::Finished(report),
            Err(error) => AsyncRunState::Failed(error),
        };
    });

    string_to_cstr(envelope::<serde_json::Value>(Ok(
        json!({ "runId": run_id }),
    )))
}

/// 按移动端设置异步运行队列。`options_json` 支持 concurrency/threadCount/retryAttempts，
/// 以及 speedLimitKbps（KiB/s 字节限速，0/缺省表示不限速）。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdown_queue_run_queued_async(
    store_path: *const c_char,
    options_json: *const c_char,
) -> *mut c_char {
    let store_path = cstr_to_string(store_path);
    let options_json = cstr_to_string(options_json);
    let (concurrency, options) = match queue_options_from_json(&options_json) {
        Ok(options) => options,
        Err(error) => return string_to_cstr(envelope::<serde_json::Value>(Err(error))),
    };
    {
        let mut active = active_queued_stores()
            .lock()
            .expect("active queue registry poisoned");
        if !active.insert(store_path.clone()) {
            return string_to_cstr(envelope::<serde_json::Value>(Err(
                "该队列已有异步运行任务".to_string()
            )));
        }
    }
    let run_id = next_async_run_id();
    let state = Arc::new(StdMutex::new(AsyncRunState::Running));
    {
        let mut runs = async_runs().lock().expect("async run registry poisoned");
        runs.insert(run_id.clone(), Arc::clone(&state));
    }

    runtime().spawn(async move {
        // 作者: long
        // 队列运行使用核心的并发调度器，设置参数只在任务启动时读取一次，避免运行中途改变槽位造成状态漂移。
        let result = QueueRunner::new(open_store(&store_path))
            .run_queued_with_options(concurrency, options)
            .await
            .map_err(|error| error.to_string())
            .and_then(|report| serde_json::to_value(report).map_err(|error| error.to_string()));
        let mut current = state.lock().expect("async run state poisoned");
        *current = match result {
            Ok(report) => AsyncRunState::Finished(report),
            Err(error) => AsyncRunState::Failed(error),
        };
        active_queued_stores()
            .lock()
            .expect("active queue registry poisoned")
            .remove(&store_path);
    });

    string_to_cstr(envelope::<serde_json::Value>(Ok(
        json!({ "runId": run_id }),
    )))
}

/// 查询非阻塞任务：running / finished / failed。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdown_queue_run_status(run_id: *const c_char) -> *mut c_char {
    let run_id = cstr_to_string(run_id);
    let output = async_runs()
        .lock()
        .expect("async run registry poisoned")
        .get(&run_id)
        .cloned()
        .ok_or_else(|| format!("异步运行不存在: {run_id}"))
        .map(|state| {
            let state = state.lock().expect("async run state poisoned");
            match &*state {
                AsyncRunState::Running => json!({ "runId": run_id, "state": "running" }),
                AsyncRunState::Finished(report) => {
                    json!({ "runId": run_id, "state": "finished", "report": report })
                }
                AsyncRunState::Failed(error) => {
                    json!({ "runId": run_id, "state": "failed", "error": error })
                }
            }
        });
    string_to_cstr(envelope(output))
}

/// 删除已完成或失败的异步运行句柄，避免长时间运行的 App 累积状态。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdown_queue_run_forget(run_id: *const c_char) -> *mut c_char {
    let run_id = cstr_to_string(run_id);
    let mut runs = async_runs().lock().expect("async run registry poisoned");
    let Some(state) = runs.get(&run_id).cloned() else {
        return string_to_cstr(envelope::<serde_json::Value>(Err(format!(
            "异步运行不存在: {run_id}"
        ))));
    };
    if matches!(
        &*state.lock().expect("async run state poisoned"),
        AsyncRunState::Running
    ) {
        return string_to_cstr(envelope::<serde_json::Value>(Err(
            "异步运行仍在执行，不能回收句柄".to_string(),
        )));
    }
    runs.remove(&run_id);
    string_to_cstr(envelope::<serde_json::Value>(Ok(
        json!({ "runId": run_id }),
    )))
}

/// 通过任务状态触发正在执行的 Rust 下载取消；运行器会在下一次轮询时停止并保留断点。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdown_queue_pause(
    store_path: *const c_char,
    task_id: *const c_char,
) -> *mut c_char {
    let store_path = cstr_to_string(store_path);
    let task_id = cstr_to_string(task_id);
    let output = runtime().block_on(async {
        let task = open_store(&store_path)
            .set_state(&task_id, DownloadState::Paused)
            .await
            .map_err(|error| error.to_string())?;
        serde_json::to_value(task).map_err(|error| error.to_string())
    });
    string_to_cstr(envelope::<serde_json::Value>(output))
}

/// 将暂停任务重新置为 queued，供异步句柄或移动控制器继续执行。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdown_queue_resume(
    store_path: *const c_char,
    task_id: *const c_char,
) -> *mut c_char {
    let store_path = cstr_to_string(store_path);
    let task_id = cstr_to_string(task_id);
    let output = runtime().block_on(async {
        let task = open_store(&store_path)
            .set_state(&task_id, DownloadState::Queued)
            .await
            .map_err(|error| error.to_string())?;
        serde_json::to_value(task).map_err(|error| error.to_string())
    });
    string_to_cstr(envelope::<serde_json::Value>(output))
}

fn open_store(store_path: &str) -> TaskStore {
    let trimmed = store_path.trim();
    if trimmed.is_empty() {
        TaskStore::new(default_store_path())
    } else {
        TaskStore::new(std::path::PathBuf::from(trimmed))
    }
}

fn queue_options_from_json(raw: &str) -> Result<(usize, QueueRunnerOptions), String> {
    let payload = if raw.trim().is_empty() {
        serde_json::Value::Object(serde_json::Map::new())
    } else {
        serde_json::from_str(raw).map_err(|error| format!("队列设置 JSON 无法解析: {error}"))?
    };
    let object = payload
        .as_object()
        .ok_or_else(|| "队列设置必须是 JSON 对象".to_string())?;
    let concurrency = object
        .get("concurrency")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(DEFAULT_QUEUE_CONCURRENCY as u64)
        .clamp(1, 30) as usize;
    let thread_count = object
        .get("threadCount")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(DEFAULT_DOWNLOAD_THREAD_COUNT as u64)
        .clamp(1, 32) as usize;
    let retry_attempts = object
        .get("retryAttempts")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(DEFAULT_RETRY_ATTEMPTS as u64)
        .min(10) as usize;
    let speed_limit_bps = object
        .get("speedLimitKbps")
        .and_then(serde_json::Value::as_f64)
        .filter(|value| value.is_finite() && *value > 0.0)
        .map(|value| (value * 1024.0).round().max(1.0) as u64);
    Ok((
        concurrency,
        QueueRunnerOptions {
            retry_attempts,
            download: DownloadOptions::new(thread_count, speed_limit_bps),
            restart_existing: false,
        },
    ))
}

fn default_store_path_dir() -> std::path::PathBuf {
    default_store_path()
        .parent()
        .map(std::path::Path::to_path_buf)
        .unwrap_or_else(default_store_path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        ffi::{CStr, CString},
        fs, thread,
        time::{SystemTime, UNIX_EPOCH},
    };

    #[test]
    fn queue_add_maps_hls_options_from_camel_case_payload() {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before unix epoch")
            .as_nanos();
        let root = std::env::temp_dir().join(format!("fluxdown-ffi-hls-{suffix}"));
        fs::create_dir_all(&root).expect("create temporary queue directory");
        let store = CString::new(root.join("queue.json").to_string_lossy().as_bytes())
            .expect("queue path contains no NUL");
        let payload = CString::new(
            r#"{"source":"https://example.com/master.m3u8","outputDir":"/tmp/downloads","torrentName":"bundle","torrentFiles":[{"index":1,"path":"bundle/video.mp4","name":"video.mp4","size":42,"isStreamable":true}],"hlsVariantIndex":2,"hlsKeepTransportStream":true}"#,
        )
        .expect("payload contains no NUL");

        // 作者: long
        // 通过真实 C ABI 调用验证移动端字段命名能保存到 Rust 队列，防止跨语言边界静默丢配置。
        let pointer = fluxdown_queue_add(store.as_ptr(), payload.as_ptr());
        assert!(!pointer.is_null());
        let response = unsafe { CStr::from_ptr(pointer) }
            .to_str()
            .expect("FFI response is UTF-8");
        let value: serde_json::Value = serde_json::from_str(response).expect("valid response JSON");
        assert_eq!(value["ok"], true);
        assert_eq!(value["data"]["hls_variant_index"], 2);
        assert_eq!(value["data"]["hls_keep_transport_stream"], true);
        assert_eq!(value["data"]["torrent_name"], "bundle");
        assert_eq!(value["data"]["torrent_files"][0]["name"], "video.mp4");
        fluxdown_string_free(pointer);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn async_queue_run_exposes_terminal_status() {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before unix epoch")
            .as_nanos();
        let root = std::env::temp_dir().join(format!("fluxdown-ffi-async-{suffix}"));
        fs::create_dir_all(&root).expect("create temporary queue directory");
        let store = CString::new(root.join("queue.json").to_string_lossy().as_bytes())
            .expect("queue path contains no NUL");
        let task_id = CString::new("missing-task").expect("task id contains no NUL");

        // 作者: long
        // 以不存在任务验证异步句柄会从 running 收敛到 failed，避免只验证“能返回句柄”而漏掉后台错误。
        let start = fluxdown_queue_run_async(store.as_ptr(), task_id.as_ptr());
        let start_value = unsafe { CStr::from_ptr(start) }
            .to_str()
            .expect("async start response is UTF-8");
        let start_json: serde_json::Value =
            serde_json::from_str(start_value).expect("valid start JSON");
        let run_id = start_json["data"]["runId"]
            .as_str()
            .expect("run id is present")
            .to_string();
        fluxdown_string_free(start);

        let run_id_c = CString::new(run_id.clone()).expect("run id contains no NUL");
        for _ in 0..100 {
            let status = fluxdown_queue_run_status(run_id_c.as_ptr());
            let status_value = unsafe { CStr::from_ptr(status) }
                .to_str()
                .expect("async status response is UTF-8");
            let status_json: serde_json::Value =
                serde_json::from_str(status_value).expect("valid status JSON");
            fluxdown_string_free(status);
            if status_json["data"]["state"] == "failed" {
                assert!(
                    status_json["data"]["error"]
                        .as_str()
                        .unwrap_or_default()
                        .contains("missing-task")
                );
                let forgotten = fluxdown_queue_run_forget(run_id_c.as_ptr());
                fluxdown_string_free(forgotten);
                let _ = fs::remove_dir_all(root);
                return;
            }
            thread::sleep(std::time::Duration::from_millis(5));
        }

        let _ = fs::remove_dir_all(root);
        panic!("async queue run did not reach a terminal state");
    }

    #[test]
    fn queue_pause_and_resume_update_task_state() {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before unix epoch")
            .as_nanos();
        let root = std::env::temp_dir().join(format!("fluxdown-ffi-pause-{suffix}"));
        fs::create_dir_all(&root).expect("create temporary queue directory");
        let store = CString::new(root.join("queue.json").to_string_lossy().as_bytes())
            .expect("queue path contains no NUL");
        let payload = CString::new(format!(
            r#"{{"source":"https://example.com/file.bin","outputDir":"{}"}}"#,
            root.to_string_lossy()
        ))
        .expect("payload contains no NUL");
        let added = fluxdown_queue_add(store.as_ptr(), payload.as_ptr());
        let added_value = unsafe { CStr::from_ptr(added) }
            .to_str()
            .expect("add response is UTF-8");
        let added_json: serde_json::Value =
            serde_json::from_str(added_value).expect("valid add JSON");
        let task_id = CString::new(added_json["data"]["id"].as_str().expect("task id")).unwrap();
        fluxdown_string_free(added);

        let paused = fluxdown_queue_pause(store.as_ptr(), task_id.as_ptr());
        let paused_value = unsafe { CStr::from_ptr(paused) }
            .to_str()
            .expect("pause response is UTF-8");
        let paused_json: serde_json::Value =
            serde_json::from_str(paused_value).expect("valid pause JSON");
        assert_eq!(paused_json["data"]["state"], "paused");
        fluxdown_string_free(paused);

        let resumed = fluxdown_queue_resume(store.as_ptr(), task_id.as_ptr());
        let resumed_value = unsafe { CStr::from_ptr(resumed) }
            .to_str()
            .expect("resume response is UTF-8");
        let resumed_json: serde_json::Value =
            serde_json::from_str(resumed_value).expect("valid resume JSON");
        assert_eq!(resumed_json["data"]["state"], "queued");
        fluxdown_string_free(resumed);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn queue_options_parse_mobile_settings_with_bounds() {
        let (concurrency, options) = queue_options_from_json(
            r#"{"concurrency":99,"threadCount":0,"retryAttempts":99,"speedLimitKbps":2.5}"#,
        )
        .expect("valid options JSON");
        assert_eq!(concurrency, 30);
        assert_eq!(options.download.thread_count, 1);
        assert_eq!(options.retry_attempts, 10);
        assert_eq!(options.download.speed_limit_bps, Some(2560));
    }

    #[test]
    fn async_queue_run_queued_returns_empty_queue_report() {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before unix epoch")
            .as_nanos();
        let root = std::env::temp_dir().join(format!("fluxdown-ffi-queued-{suffix}"));
        fs::create_dir_all(&root).expect("create temporary queue directory");
        let store = CString::new(root.join("queue.json").to_string_lossy().as_bytes())
            .expect("queue path contains no NUL");
        let options = CString::new(
            r#"{"concurrency":2,"threadCount":4,"retryAttempts":1,"speedLimitKbps":0}"#,
        )
        .expect("options contain no NUL");
        let start = fluxdown_queue_run_queued_async(store.as_ptr(), options.as_ptr());
        let start_value = unsafe { CStr::from_ptr(start) }
            .to_str()
            .expect("async queue response is UTF-8");
        let start_json: serde_json::Value =
            serde_json::from_str(start_value).expect("valid queue JSON");
        let run_id = start_json["data"]["runId"]
            .as_str()
            .expect("run id is present")
            .to_string();
        fluxdown_string_free(start);

        let duplicate = fluxdown_queue_run_queued_async(store.as_ptr(), options.as_ptr());
        let duplicate_value = unsafe { CStr::from_ptr(duplicate) }
            .to_str()
            .expect("duplicate response is UTF-8");
        let duplicate_json: serde_json::Value =
            serde_json::from_str(duplicate_value).expect("valid duplicate JSON");
        assert_eq!(duplicate_json["ok"], false);
        fluxdown_string_free(duplicate);

        let run_id_c = CString::new(run_id).expect("run id contains no NUL");
        for _ in 0..100 {
            let status = fluxdown_queue_run_status(run_id_c.as_ptr());
            let status_value = unsafe { CStr::from_ptr(status) }
                .to_str()
                .expect("async status response is UTF-8");
            let status_json: serde_json::Value =
                serde_json::from_str(status_value).expect("valid status JSON");
            fluxdown_string_free(status);
            if status_json["data"]["state"] == "finished" {
                assert_eq!(status_json["data"]["report"]["total_queued"], 0);
                let forgotten = fluxdown_queue_run_forget(run_id_c.as_ptr());
                fluxdown_string_free(forgotten);
                let _ = fs::remove_dir_all(root);
                return;
            }
            thread::sleep(std::time::Duration::from_millis(5));
        }

        let _ = fs::remove_dir_all(root);
        panic!("async queued run did not reach a terminal state");
    }
}

/// FFI 层版本号，供绑定层做兼容性自检。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdown_version() -> *mut c_char {
    string_to_cstr(env!("CARGO_PKG_VERSION").to_string())
}

/// FFI 层 ABI 标记，移动端可先用它探测动态库可用性。
#[unsafe(no_mangle)]
pub extern "C" fn fluxdown_ffi_abi() -> c_int {
    1
}
