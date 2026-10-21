//! Android JNI 壳：Kotlin 只负责界面和生命周期，下载队列仍由 Rust core 执行。
//!
//! 作者: long
//! 这里不复制 `fluxdown-ffi` 的任务模型，而是把现有 ABI 1 的 JSON 信封直接转成
//! Kotlin `String`。这样 Kotlin 重写期间仍与 Flutter、桌面和 CLI 共用同一份队列 schema。

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use jni::JNIEnv;
use jni::objects::{JClass, JString};
use jni::sys::jstring;

extern crate fluxdown_ffi;

type FfiStringFn = extern "C" fn(*const c_char) -> *mut c_char;
type FfiTwoStringFn = extern "C" fn(*const c_char, *const c_char) -> *mut c_char;

fn input_string(env: &mut JNIEnv<'_>, value: JString<'_>) -> Result<String, String> {
    env.get_string(&value)
        .map(|value| value.to_string_lossy().into_owned())
        .map_err(|error| format!("读取 Kotlin 字符串失败: {error}"))
}

fn output_string(env: &mut JNIEnv<'_>, value: String) -> jstring {
    match env.new_string(value) {
        Ok(value) => value.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

fn call_one(function: FfiStringFn, value: &str) -> String {
    let input = CString::new(value).unwrap_or_default();
    // 作者: long
    // Rust FFI 返回的指针只能由原 FFI 模块释放；转换为 Kotlin 字符串前立即释放，
    // 避免 Android 长时间运行时累积 native heap 泄漏。
    let pointer = function(input.as_ptr());
    take_ffi_string(pointer)
}

fn call_two(function: FfiTwoStringFn, first: &str, second: &str) -> String {
    let first = CString::new(first).unwrap_or_default();
    let second = CString::new(second).unwrap_or_default();
    let pointer = function(first.as_ptr(), second.as_ptr());
    take_ffi_string(pointer)
}

fn take_ffi_string(pointer: *mut c_char) -> String {
    if pointer.is_null() {
        return r#"{"ok":false,"error":"Rust FFI 返回空指针"}"#.to_string();
    }
    let value = unsafe { CStr::from_ptr(pointer) }
        .to_string_lossy()
        .into_owned();
    // 作者: long
    // `fluxdown_string_free` 与返回指针属于同一 Rust 动态库，不能使用 libc::free。
    fluxdown_ffi::fluxdown_string_free(pointer);
    value
}

fn with_one_string<F>(env: &mut JNIEnv<'_>, value: JString<'_>, f: F) -> jstring
where
    F: FnOnce(&str) -> String,
{
    match input_string(env, value) {
        Ok(value) => output_string(env, f(&value)),
        Err(error) => output_string(env, format!(r#"{{"ok":false,"error":{error:?}}}"#)),
    }
}

fn with_two_strings<F>(
    env: &mut JNIEnv<'_>,
    first: JString<'_>,
    second: JString<'_>,
    f: F,
) -> jstring
where
    F: FnOnce(&str, &str) -> String,
{
    let first = match input_string(env, first) {
        Ok(value) => value,
        Err(error) => return output_string(env, format!(r#"{{"ok":false,"error":{error:?}}}"#)),
    };
    let second = match input_string(env, second) {
        Ok(value) => value,
        Err(error) => return output_string(env, format!(r#"{{"ok":false,"error":{error:?}}}"#)),
    };
    output_string(env, f(&first, &second))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_fluxdown_android_core_RustCoreBridge_versionNative(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
) -> jstring {
    output_string(&mut env, take_ffi_string(fluxdown_ffi::fluxdown_version()))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_fluxdown_android_core_RustCoreBridge_abiNative(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
) -> jstring {
    output_string(&mut env, fluxdown_ffi::fluxdown_ffi_abi().to_string())
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_fluxdown_android_core_RustCoreBridge_detectNative(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    source: JString<'_>,
) -> jstring {
    with_one_string(&mut env, source, |source| {
        call_one(fluxdown_ffi::fluxdown_detect, source)
    })
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_fluxdown_android_core_RustCoreBridge_hlsVariantsNative(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    source: JString<'_>,
) -> jstring {
    with_one_string(&mut env, source, |source| {
        call_one(fluxdown_ffi::fluxdown_hls_variants, source)
    })
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_fluxdown_android_core_RustCoreBridge_torrentDetailsAsyncNative(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    source: JString<'_>,
    task_id: JString<'_>,
) -> jstring {
    with_two_strings(&mut env, source, task_id, |source, task_id| {
        call_two(
            fluxdown_ffi::fluxdown_torrent_details_async,
            source,
            task_id,
        )
    })
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_fluxdown_android_core_RustCoreBridge_queueListNative(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    store_path: JString<'_>,
) -> jstring {
    with_one_string(&mut env, store_path, |path| {
        call_one(fluxdown_ffi::fluxdown_queue_list, path)
    })
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_fluxdown_android_core_RustCoreBridge_queueRecoverInterruptedNative(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    store_path: JString<'_>,
) -> jstring {
    with_one_string(&mut env, store_path, |path| {
        call_one(fluxdown_ffi::fluxdown_queue_recover_interrupted, path)
    })
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_fluxdown_android_core_RustCoreBridge_queueAddNative(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    store_path: JString<'_>,
    request_json: JString<'_>,
) -> jstring {
    with_two_strings(&mut env, store_path, request_json, |path, request| {
        call_two(fluxdown_ffi::fluxdown_queue_add, path, request)
    })
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_fluxdown_android_core_RustCoreBridge_queueRunQueuedNative(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    store_path: JString<'_>,
    options_json: JString<'_>,
) -> jstring {
    with_two_strings(&mut env, store_path, options_json, |path, options| {
        call_two(fluxdown_ffi::fluxdown_queue_run_queued_async, path, options)
    })
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_fluxdown_android_core_RustCoreBridge_queueRunStatusNative(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    run_id: JString<'_>,
) -> jstring {
    with_one_string(&mut env, run_id, |id| {
        call_one(fluxdown_ffi::fluxdown_queue_run_status, id)
    })
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_fluxdown_android_core_RustCoreBridge_queueRunForgetNative(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    run_id: JString<'_>,
) -> jstring {
    with_one_string(&mut env, run_id, |id| {
        call_one(fluxdown_ffi::fluxdown_queue_run_forget, id)
    })
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_fluxdown_android_core_RustCoreBridge_queuePauseNative(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    store_path: JString<'_>,
    task_id: JString<'_>,
) -> jstring {
    with_two_strings(&mut env, store_path, task_id, |path, id| {
        call_two(fluxdown_ffi::fluxdown_queue_pause, path, id)
    })
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_fluxdown_android_core_RustCoreBridge_queueResumeNative(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    store_path: JString<'_>,
    task_id: JString<'_>,
) -> jstring {
    with_two_strings(&mut env, store_path, task_id, |path, id| {
        call_two(fluxdown_ffi::fluxdown_queue_resume, path, id)
    })
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_fluxdown_android_core_RustCoreBridge_queueResetNative(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    store_path: JString<'_>,
    task_id: JString<'_>,
) -> jstring {
    with_two_strings(&mut env, store_path, task_id, |path, id| {
        call_two(fluxdown_ffi::fluxdown_queue_reset, path, id)
    })
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_fluxdown_android_core_RustCoreBridge_queueMarkHandedOffNative(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    store_path: JString<'_>,
    task_id: JString<'_>,
) -> jstring {
    with_two_strings(&mut env, store_path, task_id, |path, id| {
        call_two(fluxdown_ffi::fluxdown_queue_mark_handed_off, path, id)
    })
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_fluxdown_android_core_RustCoreBridge_queueRemoveNative(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    store_path: JString<'_>,
    task_id: JString<'_>,
) -> jstring {
    with_two_strings(&mut env, store_path, task_id, |path, id| {
        call_two(fluxdown_ffi::fluxdown_queue_remove, path, id)
    })
}

// 作者: long
// Android 上没有 stderr 可看，librqbit/tokio 的 tracing 与 Rust panic 只能写进 logcat。
// 否则 P2P 这类"任务卡在 0 B/s"的静默失败在真机上完全无法定位。
#[cfg(target_os = "android")]
mod logcat {
    use std::io::{self, Write};

    use std::os::raw::{c_char, c_int};

    const TAG: &std::ffi::CStr = c"fluxdown-rust";
    pub const INFO: c_int = 4;
    pub const DEBUG: c_int = 3;
    pub const ERROR: c_int = 6;

    unsafe extern "C" {
        fn __android_log_write(prio: c_int, tag: *const c_char, text: *const c_char) -> c_int;
    }

    pub fn log(level: c_int, message: &str) {
        for line in message.lines() {
            let Ok(line) = std::ffi::CString::new(line) else {
                continue;
            };
            unsafe {
                __android_log_write(level, TAG.as_ptr(), line.as_ptr());
            }
        }
    }

    pub struct Writer;

    impl Write for Writer {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            log(DEBUG, &String::from_utf8_lossy(buf));
            Ok(buf.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_fluxdown_android_core_RustCoreBridge_initLoggingNative(
    _env: JNIEnv<'_>,
    _class: JClass<'_>,
    verbose: jni::sys::jboolean,
) {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        std::panic::set_hook(Box::new(|info| {
            logcat::log(logcat::ERROR, &format!("rust panic: {info}"));
        }));
        // 作者: long
        // 调试包放开 DEBUG（DHT/Tracker/peer 全量日志），正式包只留 WARN，
        // 避免 logcat 被 librqbit 的每帧日志刷屏。
        let level = if verbose != 0 {
            tracing_subscriber::filter::LevelFilter::DEBUG
        } else {
            tracing_subscriber::filter::LevelFilter::WARN
        };
        let _ = tracing_subscriber::fmt()
            .with_max_level(level)
            .with_ansi(false)
            .with_target(true)
            .with_writer(|| logcat::Writer)
            .try_init();
    });
}
