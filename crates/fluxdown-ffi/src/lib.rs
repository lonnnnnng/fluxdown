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
    DownloadRequest, QueueRunner, QueueRunnerOptions, TaskStore, TorrentFileMetadata,
    default_store_path, detect_protocol, runtime_support_status,
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        ffi::{CStr, CString},
        fs,
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
