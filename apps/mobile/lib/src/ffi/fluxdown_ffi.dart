// Flutter 绑定：通过 dart:ffi 复用 FluxDown Rust 下载核心（crates/fluxdown-ffi）。
//
// 作者: long
// 原生库必须随 App 打包，协议识别才能复用 Rust；构建命令见 docs/build-release.md。
// 1. 构建对应 ABI 的原生库：
//    - Android: cargo-ndk 产物写入 android/app/src/main/jniLibs。
//    - iOS: Runner 构建阶段执行 scripts/build-ios-ffi.sh，按目标架构链接静态库。
// 2. 加载：Android 上 DynamicLibrary.open('libfluxdown_ffi.so')；iOS 上
//    DynamicLibrary.process()（静态链接）。[FluxDownCoreFfi.open] 已按平台处理。
// 3. 协议识别接入默认产品调用链；native 库可用时 HTTP/HTTPS/WebDAV(S)/HLS，以及已经完成
//    metadata 文件选择的 Torrent/Magnet 由 RustQueueBackend 优先执行。Torrent/Magnet 的
//    metadata 获取和二次确认仍由 Dart/libtorrent 负责，ed2k 仍走外部应用移交。queueRun 保留同步兼容入口。
//
// 协议与队列调用返回统一信封 {ok, data, error}；ABI/版本是独立标量。
// 任务 JSON 与桌面端 serde schema 对齐（见 docs/task-schema.md）。

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../download_task.dart';

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
    this.credentialRef,
    this.expectedSha256,
    this.support,
    this.torrentName,
    this.torrentFiles = const [],
    this.selectedTorrentFileIndexes,
    this.speedLimitMbps,
    this.hlsVariantIndex,
    this.hlsKeepTransportStream = false,
    this.totalBytes,
    this.downloadedBytes = 0,
    this.currentSpeedBytesPerSecond = 0,
    this.error,
    this.createdAt,
    this.updatedAt,
    this.startedAt,
    this.finishedAt,
    this.handoffBackend,
    this.handedOffAt,
  });

  factory FluxDownCoreTask.fromJson(Map<String, Object?> json) {
    return FluxDownCoreTask(
      id: json['id'] as String,
      source: json['source'] as String? ?? '',
      protocol: json['protocol'] as String? ?? 'unknown',
      state: json['state'] as String? ?? 'queued',
      fileName: json['file_name'] as String?,
      outputDir: json['output_dir'] as String?,
      credentialRef: json['credential_ref'] as String?,
      expectedSha256: json['expected_sha256'] as String?,
      support: (json['support'] as Map?)?.cast<String, Object?>(),
      torrentName: json['torrent_name'] as String?,
      torrentFiles:
          (json['torrent_files'] as List?)
              ?.whereType<Map>()
              .map(_torrentFileFromJson)
              .toList(growable: false) ??
          const [],
      selectedTorrentFileIndexes: (json['torrent_file_indices'] as List?)
          ?.map(_intFromJson)
          .whereType<int>()
          .toList(growable: false),
      speedLimitMbps: _doubleFromJson(json['speed_limit_mbps']),
      hlsVariantIndex: _intFromJson(json['hls_variant_index']),
      hlsKeepTransportStream:
          json['hls_keep_transport_stream'] as bool? ?? false,
      totalBytes: _intFromJson(json['total_bytes']),
      downloadedBytes: _intFromJson(json['downloaded_bytes']) ?? 0,
      currentSpeedBytesPerSecond:
          _intFromJson(json['current_speed_bytes_per_second']) ?? 0,
      error: json['error'] as String?,
      createdAt: _dateTimeFromMilliseconds(json['created_at_ms']),
      updatedAt: _dateTimeFromMilliseconds(json['updated_at_ms']),
      startedAt: _dateTimeFromMilliseconds(json['started_at_ms']),
      finishedAt: _dateTimeFromMilliseconds(json['finished_at_ms']),
      handoffBackend: json['handoff_backend'] as String?,
      handedOffAt: _dateTimeFromMilliseconds(json['handed_off_at_ms']),
    );
  }

  final String id;
  final String source;
  final String protocol;
  final String state;
  final String? fileName;
  final String? outputDir;
  final String? credentialRef;
  final String? expectedSha256;
  final Map<String, Object?>? support;
  final String? torrentName;
  final List<TorrentFileEntry> torrentFiles;
  final List<int>? selectedTorrentFileIndexes;
  final double? speedLimitMbps;
  final int? hlsVariantIndex;
  final bool hlsKeepTransportStream;
  final int? totalBytes;
  final int downloadedBytes;
  final int currentSpeedBytesPerSecond;
  final String? error;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final String? handoffBackend;
  final DateTime? handedOffAt;

  /// 将 native 队列中的孤儿任务恢复为 Flutter 任务；缺少关键路径时跳过，避免生成不可操作的假任务。
  DownloadTask? toDownloadTask() {
    final normalizedSource = source.trim();
    final normalizedOutput = outputDir?.trim();
    if (id.trim().isEmpty ||
        normalizedSource.isEmpty ||
        normalizedOutput == null ||
        normalizedOutput.isEmpty) {
      return null;
    }
    final created = createdAt ?? DateTime.now().toUtc();
    final updated = updatedAt ?? created;
    // 作者: long
    // native 队列可能来自比当前 App 更新的版本；未知状态不能伪装成 queued，
    // 否则启动迁移会把未来版本的任务重新排队并覆盖原始状态。显式跳过后由上层保留
    // native 文件，待升级到支持该状态的版本再恢复。
    final mappedState = switch (state) {
      'queued' => DownloadState.queued,
      'running' => DownloadState.running,
      'paused' => DownloadState.paused,
      'finished' => DownloadState.finished,
      'failed' => DownloadState.failed,
      'handed-off' => DownloadState.handedOff,
      _ => null,
    };
    if (mappedState == null) return null;
    final normalizedFileName = normalizeFileName(
      fileName?.trim().isNotEmpty == true
          ? fileName!.trim()
          : suggestedFileName(normalizedSource),
    );
    return DownloadTask(
      id: id,
      source: normalizedSource,
      outputFolder: normalizedOutput,
      fileName: normalizedFileName,
      protocol: protocol.trim().isEmpty ? 'unknown' : protocol,
      state: mappedState,
      createdAt: created,
      updatedAt: updated,
      downloadedBytes: downloadedBytes,
      totalBytes: totalBytes,
      error: error,
      startedAt: startedAt,
      pausedAt: mappedState == DownloadState.paused ? updated : null,
      finishedAt: finishedAt,
      handoffBackend: handoffBackend,
      handedOffAt: handedOffAt,
      currentSpeedBytesPerSecond: currentSpeedBytesPerSecond,
      torrentName: torrentName,
      torrentFiles: List.unmodifiable(torrentFiles),
      selectedTorrentFileIndexes: selectedTorrentFileIndexes == null
          ? null
          : List.unmodifiable(selectedTorrentFileIndexes!),
      expectedSha256: expectedSha256,
      credentialRef: credentialRef,
      speedLimitMbps: speedLimitMbps,
      hlsVariantIndex: hlsVariantIndex,
      hlsKeepTransportStream: hlsKeepTransportStream,
    );
  }
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

typedef _ThreeStringsNative =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _ThreeStringsDart =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

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
    _queueUpsert = _lib.lookupFunction<_TwoStringsNative, _TwoStringsDart>(
      'fluxdown_queue_upsert',
    );
    _queueRun = _lib.lookupFunction<_TwoStringsNative, _TwoStringsDart>(
      'fluxdown_queue_run',
    );
    _queueRunAsync = _lib.lookupFunction<_TwoStringsNative, _TwoStringsDart>(
      'fluxdown_queue_run_async',
    );
    _queueRunWithOptionsAsync = _lib
        .lookupFunction<_ThreeStringsNative, _ThreeStringsDart>(
          'fluxdown_queue_run_with_options_async',
        );
    _queueRunQueuedAsync = _lib
        .lookupFunction<_TwoStringsNative, _TwoStringsDart>(
          'fluxdown_queue_run_queued_async',
        );
    _queueRunStatus = _lib.lookupFunction<_StringInNative, _StringInDart>(
      'fluxdown_queue_run_status',
    );
    _queueRunForget = _lib.lookupFunction<_StringInNative, _StringInDart>(
      'fluxdown_queue_run_forget',
    );
    _queuePause = _lib.lookupFunction<_TwoStringsNative, _TwoStringsDart>(
      'fluxdown_queue_pause',
    );
    _queueResume = _lib.lookupFunction<_TwoStringsNative, _TwoStringsDart>(
      'fluxdown_queue_resume',
    );
    _queueRemove = _lib.lookupFunction<_TwoStringsNative, _TwoStringsDart>(
      'fluxdown_queue_remove',
    );
    _queueReset = _lib.lookupFunction<_TwoStringsNative, _TwoStringsDart>(
      'fluxdown_queue_reset',
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
  late final _TwoStringsDart _queueUpsert;
  late final _TwoStringsDart _queueRun;
  late final _TwoStringsDart _queueRunAsync;
  late final _ThreeStringsDart _queueRunWithOptionsAsync;
  late final _TwoStringsDart _queueRunQueuedAsync;
  late final _StringInDart _queueRunStatus;
  late final _StringInDart _queueRunForget;
  late final _TwoStringsDart _queuePause;
  late final _TwoStringsDart _queueResume;
  late final _TwoStringsDart _queueRemove;
  late final _TwoStringsDart _queueReset;
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

  FluxDownCoreTask queueUpsert(String storePath, Map<String, Object?> task) {
    final data = _unwrapMap(
      _callTwo(_queueUpsert, storePath, jsonEncode(task)),
    );
    return FluxDownCoreTask.fromJson(data);
  }

  Map<String, Object?> queueRun(String storePath, String taskId) =>
      _unwrapMap(_callTwo(_queueRun, storePath, taskId));

  Map<String, Object?> queueRunAsync(String storePath, String taskId) =>
      _unwrapMap(_callTwo(_queueRunAsync, storePath, taskId));

  Map<String, Object?> queueRunWithOptionsAsync(
    String storePath,
    String taskId,
    Map<String, Object?> options,
  ) => _unwrapMap(
    _callThree(
      _queueRunWithOptionsAsync,
      storePath,
      taskId,
      jsonEncode(options),
    ),
  );

  Map<String, Object?> queueRunQueuedAsync(
    String storePath,
    Map<String, Object?> options,
  ) => _unwrapMap(
    _callTwo(_queueRunQueuedAsync, storePath, jsonEncode(options)),
  );

  Map<String, Object?> queueRunStatus(String runId) =>
      _unwrapMap(_call(_queueRunStatus, runId));

  void queueRunForget(String runId) {
    _unwrap(_call(_queueRunForget, runId));
  }

  FluxDownCoreTask queuePause(String storePath, String taskId) =>
      FluxDownCoreTask.fromJson(
        _unwrapMap(_callTwo(_queuePause, storePath, taskId)),
      );

  FluxDownCoreTask queueResume(String storePath, String taskId) =>
      FluxDownCoreTask.fromJson(
        _unwrapMap(_callTwo(_queueResume, storePath, taskId)),
      );

  void queueRemove(String storePath, String taskId) {
    _unwrap(_callTwo(_queueRemove, storePath, taskId));
  }

  FluxDownCoreTask queueReset(String storePath, String taskId) =>
      FluxDownCoreTask.fromJson(
        _unwrapMap(_callTwo(_queueReset, storePath, taskId)),
      );

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

  String _callThree(
    _ThreeStringsDart call,
    String first,
    String second,
    String third,
  ) => using(
    (arena) => _toDart(
      call(
        first.toNativeUtf8(allocator: arena),
        second.toNativeUtf8(allocator: arena),
        third.toNativeUtf8(allocator: arena),
      ),
    ),
  );
}

DateTime? _dateTimeFromMilliseconds(Object? value) {
  if (value is num && value > 0) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
  }
  return null;
}

int? _intFromJson(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

double? _doubleFromJson(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}

TorrentFileEntry _torrentFileFromJson(Map raw) {
  final value = Map<String, Object?>.from(raw);
  return TorrentFileEntry(
    index: _intFromJson(value['index']) ?? 0,
    path: value['path'] as String? ?? '',
    name: value['name'] as String? ?? '',
    size: _intFromJson(value['size']) ?? 0,
    isStreamable:
        value['is_streamable'] as bool? ??
        value['isStreamable'] as bool? ??
        false,
  );
}
