//! FluxDown FFI：把 Rust 下载核心暴露给移动端（Flutter `dart:ffi`）使用。
//!
//! 约定：
//! - 所有导出函数接收/返回 UTF-8 JSON 字符串（`char*`），调用方通过
//!   `fluxdown_string_free` 释放返回值，输入字符串由调用方持有并释放。
//! - 每个返回值都是统一信封：`{"ok":true,"data":...}` 或 `{"ok":false,"error":"..."}`，
//!   解析失败/panic 都收敛为 ok=false，保证跨语言边界不抛异常。
//! - 异步能力通过常驻 tokio 多线程运行时驱动，FFI 调用本身保持同步签名。

use std::{
    ffi::{CStr, CString},
    os::raw::{c_char, c_int},
    sync::OnceLock,
};

use fluxdown_core::{
    DownloadRequest, QueueRunner, QueueRunnerOptions, TaskStore, default_store_path,
    detect_protocol, runtime_support_status,
};
use serde_json::json;
use tokio::{runtime::Runtime, sync::Mutex};

static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static QUEUE_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

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
/// `{"source":..,"outputDir":..,"fileName":..,"expectedSha256":..,"torrentFileIndices":[..],"speedLimitMbps":..}`。
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
        if let Some(sha) = payload.get("expectedSha256").and_then(|value| value.as_str()) {
            request.expected_sha256 = fluxdown_core::validate_sha256_text(sha)
                .map_err(|error| format!("SHA-256 无效: {error}"))
                .map(Some)?;
        }
        if let Some(indices) = payload.get("torrentFileIndices").and_then(|value| value.as_array())
        {
            request.torrent_file_indices = indices
                .iter()
                .filter_map(|value| value.as_u64().map(|value| value as usize))
                .collect();
        }
        if let Some(limit) = payload.get("speedLimitMbps").and_then(|value| value.as_f64()) {
            request.speed_limit_mbps = Some(limit);
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

fn open_store(store_path: &str) -> TaskStore {
    let trimmed = store_path.trim();
    if trimmed.is_empty() {
        TaskStore::new(default_store_path())
    } else {
        TaskStore::new(std::path::PathBuf::from(trimmed))
    }
}

fn default_store_path_dir() -> std::path::PathBuf {
    default_store_path()
        .parent()
        .map(std::path::Path::to_path_buf)
        .unwrap_or_else(default_store_path)
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
