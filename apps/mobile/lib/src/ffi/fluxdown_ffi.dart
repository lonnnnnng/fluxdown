// Flutter 绑定：通过 dart:ffi 复用 FluxDown Rust 下载核心（crates/fluxdown-ffi）。
//
// 集成步骤（首次接入时执行一次）：
// 1. 用 cargo-ndk / cargo build 产出对应 ABI 的共享库并打包进 App：
//    - Android: cargo ndk -t arm64-v8a -t armeabi-v7a -o android/app/src/main/jniLibs build --release -p fluxdown-ffi
//    - iOS: cargo build --release -p fluxdown-ffi --target aarch64-apple-ios，
//      生成 libfluxdown_ffi.a 后在 Xcode 里链入 Runner target。
// 2. 加载：Android 上 DynamicLibrary.open('libfluxdown_ffi.so')；iOS 上
//    DynamicLibrary.process()（静态链接）。[FluxDownCoreFfi.open] 已按平台处理。
// 3. 在下载控制器里用 [FluxDownCoreFfi] 复用 Rust core 的协议识别与队列能力，
//    移动端自实现协议栈可以逐步收敛为降级路径。
//
// 所有调用返回统一信封 {ok, data, error}；[FluxDownCoreEnvelope] 已封装解包。
// 任务 JSON 与桌面端 serde schema 对齐（见 docs/task-schema.md）。

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// FFI 原始信封。
class FluxDownCoreEnvelope {
  const FluxDownCoreEnvelope({required this.ok, this.data, this.error});

  factory FluxDownCoreEnvelope.parse(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('FFI 返回的信封不是对象');
    }
    return FluxDownCoreEnvelope(
      ok: decoded['ok'] == true,
      data: decoded['data'],
      error: decoded['error'] as String?,
    );
  }

  final bool ok;
  final Object? data;
  final String? error;

  Object? unwrap() {
    if (!ok) {
      throw FluxDownCoreException(error ?? 'FFI 调用失败');
    }
    return data;
  }
}

class FluxDownCoreException implements Exception {
  const FluxDownCoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 覆盖桌面端 DownloadTask 的关键字段（统一任务 schema 的移动端投影）。
class FluxDownCoreTask {
  const FluxDownCoreTask({
    required this.id,
    required this.source,
    required this.protocol,
    required this.state,
    this.fileName,
    this.outputDir,
    this.expectedSha256,
    this.totalBytes,
    this.downloadedBytes = 0,
  });

  factory FluxDownCoreTask.fromJson(Map<String, Object?> json) {
    return FluxDownCoreTask(
      id: json['id'] as String,
      source: json['source'] as String? ?? '',
      protocol: json['protocol'] as String? ?? 'unknown',
      state: json['state'] as String? ?? 'queued',
      fileName: json['file_name'] as String?,
      outputDir: json['output_dir'] as String?,
      expectedSha256: json['expected_sha256'] as String?,
      totalBytes: json['total_bytes'] as int?,
      downloadedBytes: json['downloaded_bytes'] as int? ?? 0,
    );
  }

  final String id;
  final String source;
  final String protocol;
  final String state;
  final String? fileName;
  final String? outputDir;
  final String? expectedSha256;
  final int? totalBytes;
  final int downloadedBytes;
}

typedef _AbiNative = Int32 Function();
typedef _AbiDart = int Function();

typedef _VersionNative = Pointer<Utf8> Function();
typedef _VersionDart = Pointer<Utf8> Function();

typedef _StringInNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _StringInDart = Pointer<Utf8> Function(Pointer<Utf8>);

typedef _TwoStringsNative = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _TwoStringsDart = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);

typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class FluxDownCoreFfi {
  FluxDownCoreFfi._(DynamicLibrary library) : _lib = library {
    _abi = _lib.lookupFunction<_AbiNative, _AbiDart>('fluxdown_ffi_abi');
    _version = _lib.lookupFunction<_VersionNative, _VersionDart>('fluxdown_version');
    _detect = _lib.lookupFunction<_StringInNative, _StringInDart>('fluxdown_detect');
    _support = _lib.lookupFunction<_StringInNative, _StringInDart>('fluxdown_support');
    _queueList =
        _lib.lookupFunction<_StringInNative, _StringInDart>('fluxdown_queue_list');
    _queueAdd =
        _lib.lookupFunction<_TwoStringsNative, _TwoStringsDart>('fluxdown_queue_add');
    _queueRun =
        _lib.lookupFunction<_TwoStringsNative, _TwoStringsDart>('fluxdown_queue_run');
    _free = _lib.lookupFunction<_FreeNative, _FreeDart>('fluxdown_string_free');
  }

  /// 按平台打开核心动态库；Windows 调试用，移动端见文件头注释。
  factory FluxDownCoreFfi.open() {
    if (Platform.isWindows) {
      return FluxDownCoreFfi._(DynamicLibrary.open('fluxdown_ffi.dll'));
    }
    if (Platform.isIOS || Platform.isMacOS) {
      return FluxDownCoreFfi._(DynamicLibrary.process());
    }
    return FluxDownCoreFfi._(DynamicLibrary.open('libfluxdown_ffi.so'));
  }

  final DynamicLibrary _lib;
  late final _AbiDart _abi;
  late final _VersionDart _version;
  late final _StringInDart _detect;
  late final _StringInDart _support;
  late final _StringInDart _queueList;
  late final _TwoStringsDart _queueAdd;
  late final _TwoStringsDart _queueRun;
  late final _FreeDart _free;

  int abi() => _abi();

  String version() => _toDart(_version());

  Map<String, Object?> detect(String source) =>
      _unwrap(_toDart(_detect(_toNative(source))));

  Map<String, Object?> support(String source) =>
      _unwrap(_toDart(_support(_toNative(source))));

  List<FluxDownCoreTask> queueList(String storePath) {
    final data = _unwrap(_toDart(_queueList(_toNative(storePath))));
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((item) => FluxDownCoreTask.fromJson(Map<String, Object?>.from(item)))
        .toList(growable: false);
  }

  FluxDownCoreTask queueAdd(String storePath, Map<String, Object?> request) {
    final data = _unwrap(
      _toDart(_queueAdd(_toNative(storePath), _toNative(jsonEncode(request)))),
    );
    return FluxDownCoreTask.fromJson(Map<String, Object?>.from(data as Map));
  }

  Map<String, Object?> queueRun(String storePath, String taskId) =>
      _unwrap(_toDart(_queueRun(_toNative(storePath), _toNative(taskId))));

  Map<String, Object?> _unwrap(Object? envelope) {
    if (envelope is Map<String, Object?>) {
      if (envelope['ok'] != true) {
        throw FluxDownCoreException(envelope['error']?.toString() ?? 'FFI 调用失败');
      }
      return envelope;
    }
    throw const FluxDownCoreException('FFI 返回的信封无法解析');
  }

  String _toDart(Pointer<Utf8> pointer) {
    final result = pointer.toDartString();
    _free(pointer);
    return result;
  }

  Pointer<Utf8> _toNative(String value) => value.toNativeUtf8();
}
