// Flutter 绑定：通过 dart:ffi 复用 FluxDown Rust 下载核心（crates/fluxdown-ffi）。
//
// 作者: long
// 原生库必须随 App 打包，协议识别才能复用 Rust；构建命令见 docs/build-release.md。
// 1. 构建对应 ABI 的原生库：
//    - Android: cargo-ndk 产物写入 android/app/src/main/jniLibs。
//    - iOS: Runner 构建阶段执行 scripts/build-ios-ffi.sh，按目标架构链接静态库。
// 2. 加载：Android 上 DynamicLibrary.open('libfluxdown_ffi.so')；iOS 上
//    DynamicLibrary.process()（静态链接）。[FluxDownCoreFfi.open] 已按平台处理。
// 3. 当前仅协议识别接入产品调用链；队列绑定用于独立验证，移动下载仍由 Dart/原生适配器执行。
//    queueRun 会阻塞调用线程，后续接入下载控制器时需要隔离执行和独立的取消/进度接口。
//
// 协议与队列调用返回统一信封 {ok, data, error}；ABI/版本是独立标量。
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

typedef _TwoStringsNative =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _TwoStringsDart = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);

typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class FluxDownCoreFfi {
  FluxDownCoreFfi._(DynamicLibrary library) : _lib = library {
    _abi = _lib.lookupFunction<_AbiNative, _AbiDart>('fluxdown_ffi_abi');
    if (_abi() != 1) {
      throw const FluxDownCoreException('FFI ABI 版本不兼容');
    }
    _version = _lib.lookupFunction<_VersionNative, _VersionDart>(
      'fluxdown_version',
    );
    _detect = _lib.lookupFunction<_StringInNative, _StringInDart>(
      'fluxdown_detect',
    );
    _support = _lib.lookupFunction<_StringInNative, _StringInDart>(
      'fluxdown_support',
    );
    _queueList = _lib.lookupFunction<_StringInNative, _StringInDart>(
      'fluxdown_queue_list',
    );
    _queueAdd = _lib.lookupFunction<_TwoStringsNative, _TwoStringsDart>(
      'fluxdown_queue_add',
    );
    _queueRun = _lib.lookupFunction<_TwoStringsNative, _TwoStringsDart>(
      'fluxdown_queue_run',
    );
    _free = _lib.lookupFunction<_FreeNative, _FreeDart>('fluxdown_string_free');
  }

  /// 按平台打开核心动态库；Windows 调试用，移动端见文件头注释。
  factory FluxDownCoreFfi.open({String? libraryPath}) {
    if (libraryPath != null) {
      return FluxDownCoreFfi._(DynamicLibrary.open(libraryPath));
    }
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
      _unwrapMap(_call(_detect, source));

  Map<String, Object?> support(String source) =>
      _unwrapMap(_call(_support, source));

  List<FluxDownCoreTask> queueList(String storePath) {
    final data = _unwrap(_call(_queueList, storePath));
    if (data is! List || data.any((item) => item is! Map)) {
      throw const FluxDownCoreException('FFI 返回的队列不是任务列表');
    }
    return data
        .whereType<Map>()
        .map(
          (item) => FluxDownCoreTask.fromJson(Map<String, Object?>.from(item)),
        )
        .toList(growable: false);
  }

  FluxDownCoreTask queueAdd(String storePath, Map<String, Object?> request) {
    final data = _unwrapMap(
      _callTwo(_queueAdd, storePath, jsonEncode(request)),
    );
    return FluxDownCoreTask.fromJson(data);
  }

  Map<String, Object?> queueRun(String storePath, String taskId) =>
      _unwrapMap(_callTwo(_queueRun, storePath, taskId));

  /// 解包信封：成功返回 data 载荷（可能是任意 JSON 值），失败抛异常。
  // 作者: long
  // C ABI 返回 UTF-8 JSON 文本，必须先解码再解包；直接按 Map 判断会让每次调用都失败。
  Object? _unwrap(String raw) => FluxDownCoreEnvelope.parse(raw).unwrap();

  /// 解包信封并要求 data 是 JSON 对象。
  Map<String, Object?> _unwrapMap(String envelope) {
    final data = _unwrap(envelope);
    if (data is Map) {
      return Map<String, Object?>.from(data);
    }
    throw const FluxDownCoreException('FFI 返回的 data 不是对象');
  }

  String _toDart(Pointer<Utf8> pointer) {
    if (pointer == nullptr) {
      throw const FluxDownCoreException('FFI 未返回结果');
    }
    try {
      return pointer.toDartString();
    } finally {
      _free(pointer);
    }
  }

  // 作者: long
  // 输入由 Dart 分配、输出由 Rust 分配，必须各自释放，避免协议识别与队列轮询持续泄漏。
  String _call(_StringInDart call, String value) =>
      using((arena) => _toDart(call(value.toNativeUtf8(allocator: arena))));

  String _callTwo(_TwoStringsDart call, String first, String second) => using(
    (arena) => _toDart(
      call(
        first.toNativeUtf8(allocator: arena),
        second.toNativeUtf8(allocator: arena),
      ),
    ),
  );
}
