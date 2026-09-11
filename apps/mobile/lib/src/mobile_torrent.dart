import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:path/path.dart' as p;

import 'download_task.dart';
import 'transfer_metrics.dart';

class TorrentDownloadCancelled implements Exception {
  const TorrentDownloadCancelled();
}

class TorrentMetadataSelectionCancelled implements Exception {
  const TorrentMetadataSelectionCancelled();
}

class TorrentMetadata {
  const TorrentMetadata({required this.name, required this.files});

  final String name;
  final List<TorrentFileEntry> files;

  int get totalBytes => files.fold<int>(0, (total, file) => total + file.size);

  bool get hasMultipleFiles => files.length > 1;
}

class TorrentFileSelection {
  const TorrentFileSelection({required this.selectedIndexes});

  final List<int> selectedIndexes;
}

typedef TorrentMetadataSelector =
    Future<TorrentFileSelection?> Function(
      DownloadTask task,
      TorrentMetadata metadata,
    );

class _PausedTorrentHandle {
  const _PausedTorrentHandle({required this.engine, required this.torrentId});

  final LibtorrentFlutter engine;
  final int torrentId;
}

class MobileTorrentRunner {
  MobileTorrentRunner({
    http.Client? client,
    Duration stallTimeout = const Duration(minutes: 10),
    Duration peerHintDelay = const Duration(seconds: 10),
  }) : _client = client ?? http.Client(),
       _stallTimeout = stallTimeout,
       _peerHintDelay = peerHintDelay;

  final http.Client _client;
  final Duration _stallTimeout;
  final Duration _peerHintDelay;
  final Map<String, _PausedTorrentHandle> _pausedHandles = {};
  final Set<String> _discardRequested = {};

  void discard(String taskId) {
    _discardRequested.add(taskId);
    final paused = _pausedHandles.remove(taskId);
    if (paused == null) return;
    try {
      paused.engine.removeTorrent(paused.torrentId, deleteFiles: false);
    } catch (_) {
      // 作者: long
      // handle 已被原生 session 移除时，丢弃动作无需再向上抛错。
    }
    _discardRequested.remove(taskId);
  }

  Future<DownloadTask> download(
    DownloadTask task, {
    int speedLimitKbps = 0,
    required FutureOr<void> Function(DownloadTask task) onProgress,
    required bool Function() isCancelled,
    TorrentMetadataSelector? onMetadata,
  }) async {
    final outputDir = Directory(task.outputFolder);
    await outputDir.create(recursive: true);

    await LibtorrentFlutter.init(
      defaultSavePath: outputDir.path,
      pollInterval: const Duration(milliseconds: 500),
    );
    final engine = LibtorrentFlutter.instance;
    // 作者: long
    // libtorrent 的下载上限作用于当前 session，0 明确恢复为不限速，避免沿用上一批任务的旧配置。
    engine.setDownloadLimit(speedLimitKbps <= 0 ? 0 : speedLimitKbps * 1024);
    _discardRequested.remove(task.id);
    final pausedHandle = _pausedHandles.remove(task.id);
    final reusedPausedHandle = pausedHandle != null;
    String? torrentSource;
    late final int torrentId;
    if (pausedHandle != null) {
      torrentId = pausedHandle.torrentId;
      // 作者: long
      // 暂停后的继续直接复用原生 handle，保留已经校验过的 piece 和连接状态，避免重新添加任务导致整文件重下。
      pausedHandle.engine.resumeTorrent(torrentId);
    } else {
      torrentSource = await _torrentSourcePath(task);
      try {
        torrentId = task.protocol == 'magnet'
            ? engine.addMagnet(
                await _magnetSourceWithTrackers(task.source),
                outputDir.path,
              )
            : engine.addTorrentFile(torrentSource, outputDir.path);
      } catch (_) {
        await _deleteTemporaryTorrentSource(task, torrentSource);
        rethrow;
      }
    }

    StreamSubscription<Map<int, TorrentInfo>>? subscription;
    Timer? cancelPoller;
    var preserveHandleOnCancel = false;
    try {
      var current = task.copyWith(
        state: DownloadState.running,
        downloadedBytes: reusedPausedHandle ? task.downloadedBytes : 0,
        totalBytes: task.selectedTorrentTotalBytes,
        clearTotalBytes: task.selectedTorrentTotalBytes == null,
        clearError: true,
      );
      await onProgress(current);
      final speedSampler = TransferSpeedSampler();

      final completion = Completer<DownloadTask>();
      var metadataHandled = false;
      Future<void>? metadataHandling;
      var lastProgressBytes = reusedPausedHandle ? task.downloadedBytes : 0;
      var lastProgressAt = DateTime.now();

      Future<void> applyMetadataBody(TorrentInfo info) async {
        final files = engine.getFiles(torrentId);
        if (files.isEmpty) {
          return;
        }

        final metadata = _metadataFromLibtorrent(info.name, files);
        var selectedIndexes = current.selectedTorrentFileIndexes;
        var pausedForSelection = false;
        if (selectedIndexes == null || selectedIndexes.isEmpty) {
          if (metadata.hasMultipleFiles && onMetadata != null) {
            engine.pauseTorrent(torrentId);
            pausedForSelection = true;
            final selection = await onMetadata(current, metadata);
            if (selection == null || selection.selectedIndexes.isEmpty) {
              try {
                engine.pauseTorrent(torrentId);
              } finally {
                completion.completeError(
                  const TorrentMetadataSelectionCancelled(),
                );
              }
              return;
            }
            selectedIndexes = selection.selectedIndexes;
          } else {
            selectedIndexes = metadata.files.map((file) => file.index).toList();
          }
        }

        final validSelectedIndexes = _validSelectedIndexes(
          metadata.files,
          selectedIndexes,
        );
        final selectedFiles = _selectedFiles(
          metadata.files,
          validSelectedIndexes,
        );
        if (selectedFiles.isEmpty) {
          throw StateError('No torrent files selected.');
        }

        engine.setFilePriorities(
          torrentId,
          metadata.files
              .map((file) => validSelectedIndexes.contains(file.index) ? 1 : 0)
              .toList(growable: false),
        );

        if (!reusedPausedHandle && task.downloadedBytes > 0) {
          // 作者: long
          // 暂停后重新创建 handle 时，已有文件可能只有部分 piece 已通过校验；强制重检让 libtorrent
          // 恢复这些 piece，而不是把预分配文件当成全新任务从 0 开始重下。
          engine.recheckTorrent(torrentId);
        }

        final selectedTotal = selectedFiles.fold<int>(
          0,
          (total, file) => total + file.size,
        );
        current = current.copyWith(
          fileName: torrentDisplayName(
            metadata,
            selectedIndexes: validSelectedIndexes,
          ),
          torrentName: metadata.name,
          torrentFiles: metadata.files,
          selectedTorrentFileIndexes: validSelectedIndexes,
          totalBytes: selectedTotal,
          clearError: true,
        );
        await onProgress(current);
        metadataHandled = true;
        lastProgressAt = DateTime.now();
        if (pausedForSelection && !completion.isCompleted) {
          engine.resumeTorrent(torrentId);
        }
      }

      Future<void> applyMetadata(TorrentInfo info) {
        if (metadataHandled || !info.hasMetadata) {
          return Future.value();
        }
        final pending = metadataHandling;
        if (pending != null) {
          return pending;
        }
        final future = applyMetadataBody(info);
        metadataHandling = future.whenComplete(() {
          metadataHandling = null;
        });
        return metadataHandling!;
      }

      Future<void> emit(TorrentInfo info) async {
        if (completion.isCompleted) {
          return;
        }

        if (isCancelled()) {
          try {
            engine.pauseTorrent(torrentId);
            preserveHandleOnCancel = true;
          } finally {
            completion.completeError(const TorrentDownloadCancelled());
          }
          return;
        }

        try {
          await applyMetadata(info);
        } catch (error, stackTrace) {
          if (!completion.isCompleted) {
            completion.completeError(error, stackTrace);
          }
          return;
        }
        if (completion.isCompleted) {
          return;
        }

        if (info.state == TorrentState.error) {
          completion.completeError(
            StateError(
              info.errorMsg.isEmpty
                  ? 'Torrent download failed.'
                  : info.errorMsg,
            ),
          );
          return;
        }

        final selectedTotal = current.selectedTorrentTotalBytes;
        final total =
            selectedTotal ?? (info.totalWanted > 0 ? info.totalWanted : null);
        // 作者: long
        // total_done 包含过滤文件边界上被一并写入的 piece，不能直接与用户所选文件大小比较；
        // progress 是 libtorrent 针对 wanted 数据的进度，用它折算任务已下载量可避免提前完成。
        final nativeReportedDone = total == null
            ? info.totalDone
            : (info.progress.clamp(0.0, 1.0) * total)
                  .round()
                  .clamp(0, total)
                  .toInt();
        final reportedDone =
            reusedPausedHandle && nativeReportedDone < task.downloadedBytes
            ? task.downloadedBytes
            : nativeReportedDone;
        if (reportedDone > lastProgressBytes) {
          lastProgressBytes = reportedDone;
          lastProgressAt = DateTime.now();
        }
        final preparing =
            info.state == TorrentState.downloadingMetadata ||
            info.state == TorrentState.checkingFiles ||
            info.state == TorrentState.checkingResume ||
            info.state == TorrentState.allocating;
        if (preparing) {
          // 作者: long
          // metadata 获取、断点校验和稀疏文件分配本身可能长时间没有下载字节，不计入网络停滞时间。
          lastProgressAt = DateTime.now();
        }
        final stalledFor = DateTime.now().difference(lastProgressAt);
        final waitingForPeer =
            metadataHandled &&
            info.state == TorrentState.downloading &&
            info.numPeers == 0 &&
            stalledFor >= _peerHintDelay;
        final sampledSpeed = speedSampler.sample(reportedDone);
        current = current.copyWith(
          downloadedBytes: reportedDone,
          totalBytes: total,
          clearTotalBytes: total == null,
          currentSpeedBytesPerSecond: info.downloadRate > 0
              ? info.downloadRate
              : sampledSpeed,
          error: waitingForPeer ? '暂无可用 Peer，正在等待 Tracker 或其他节点。' : null,
          clearError: !waitingForPeer,
        );
        await onProgress(current);

        // 作者: long
        // 某些 Android 原生存储场景会在文件尚未创建时先返回 finished/seeding；
        // 只有 native 完成状态与已下载字节都覆盖用户选择的内容，才能结束任务并写入“已完成”。
        final nativeDone = info.isFinished || info.state.isDone;
        final selectedTotalReached = total == null || info.totalDone >= total;
        final doneByNativeState = nativeDone && selectedTotalReached;
        final canEvaluateStall =
            metadataHandled &&
            info.state == TorrentState.downloading &&
            !doneByNativeState;
        if (canEvaluateStall && stalledFor >= _stallTimeout) {
          // 作者: long
          // 冷门资源的 Peer 发现可能需要数分钟，只在真正进入下载态后持续 10 分钟无进度才释放并发槽位并交给自动重试。
          completion.completeError(
            StateError(
              'Torrent made no download progress for ${stalledFor.inSeconds}s; '
              'peers=${info.numPeers}; check tracker and peers.',
            ),
          );
          return;
        }
        if (doneByNativeState && metadataHandled) {
          completion.complete(
            current.copyWith(
              state: DownloadState.finished,
              downloadedBytes: total ?? reportedDone,
              totalBytes: total,
              clearTotalBytes: total == null,
              clearError: true,
            ),
          );
        }
      }

      subscription = engine.torrentUpdates.listen(
        (snapshot) {
          final info = snapshot[torrentId];
          if (info == null) {
            return;
          }
          unawaited(emit(info));
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!completion.isCompleted) {
            completion.completeError(error, stackTrace);
          }
        },
      );

      if (reusedPausedHandle) {
        engine.resumeTorrent(torrentId);
      }
      final initial = engine.torrents[torrentId];
      if (initial != null) {
        await emit(initial);
      }

      cancelPoller = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!completion.isCompleted && isCancelled()) {
          try {
            engine.pauseTorrent(torrentId);
            preserveHandleOnCancel = true;
          } finally {
            completion.completeError(const TorrentDownloadCancelled());
          }
        }
      });

      return await completion.future;
    } finally {
      cancelPoller?.cancel();
      await subscription?.cancel();
      final discardRequested = _discardRequested.contains(task.id);
      final keepPausedHandle = preserveHandleOnCancel && !discardRequested;
      if (keepPausedHandle) {
        _pausedHandles[task.id] = _PausedTorrentHandle(
          engine: engine,
          torrentId: torrentId,
        );
      }
      if (!keepPausedHandle) {
        try {
          // 作者: long
          // 正常完成或失败后释放 handle；暂停则由取消分支先登记到 _pausedHandles，继续时复用同一实例。
          engine.removeTorrent(torrentId, deleteFiles: false);
        } catch (_) {
          // handle 可能已被原生引擎因致命错误移除，收尾失败不覆盖真实下载结果。
        }
      }
      if (torrentSource != null) {
        await _deleteTemporaryTorrentSource(task, torrentSource);
      }
      if (discardRequested) {
        _discardRequested.remove(task.id);
      }
    }
  }

  Future<void> _deleteTemporaryTorrentSource(
    DownloadTask task,
    String torrentSource,
  ) async {
    final uri = Uri.tryParse(task.source);
    if (task.protocol != 'torrent' ||
        uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return;
    }
    try {
      final directory = File(torrentSource).parent;
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {
      // 作者: long
      // .torrent 临时文件只用于向原生引擎传递 metadata，清理失败不应改写任务状态。
    }
  }

  Future<String> _torrentSourcePath(DownloadTask task) async {
    if (task.protocol != 'torrent') {
      return task.source;
    }

    final uri = Uri.tryParse(task.source);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return _downloadTorrentFile(uri, task.id);
    }
    if (uri != null && uri.scheme == 'file') {
      return uri.toFilePath();
    }
    return task.source;
  }

  Future<String> _downloadTorrentFile(Uri uri, String taskId) async {
    final response = await _client.get(uri);
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }

    final tempDir = await Directory.systemTemp.createTemp('fluxdown_torrent_');
    final fileName = p.basename(uri.path).trim().isEmpty
        ? '$taskId.torrent'
        : p.basename(uri.path);
    final file = File(p.join(tempDir.path, fileName));
    await file.writeAsBytes(response.bodyBytes);
    return file.path;
  }

  Future<String> _magnetSourceWithTrackers(String source) async {
    return _prepareMagnetSource(source);
  }
}

Future<TorrentMetadata?> inspectTorrentMetadataFromSource(
  String source, {
  http.Client? client,
  Duration magnetMetadataTimeout = const Duration(minutes: 3),
}) async {
  final normalized = source.trim();
  if (Uri.tryParse(normalized)?.scheme.toLowerCase() == 'magnet') {
    return _inspectMagnetMetadata(normalized, timeout: magnetMetadataTimeout);
  }
  final bytes = await _readTorrentBytesFromSource(source, client: client);
  if (bytes == null) {
    return null;
  }
  return parseTorrentMetadataBytes(bytes);
}

Future<TorrentMetadata?> _inspectMagnetMetadata(
  String source, {
  required Duration timeout,
}) async {
  if (source.isEmpty) return null;

  final tempDirectory = await Directory.systemTemp.createTemp(
    'fluxdown_magnet_metadata_',
  );
  StreamSubscription<Map<int, TorrentInfo>>? subscription;
  int? torrentId;
  try {
    await LibtorrentFlutter.init(
      defaultSavePath: tempDirectory.path,
      pollInterval: const Duration(milliseconds: 500),
    );
    final engine = LibtorrentFlutter.instance;
    torrentId = engine.addMagnet(
      await _prepareMagnetSource(source),
      tempDirectory.path,
      true,
    );
    final metadata = Completer<TorrentMetadata>();

    void inspectSnapshot(Map<int, TorrentInfo> snapshot) {
      if (metadata.isCompleted) return;
      final info = snapshot[torrentId];
      if (info == null || !info.hasMetadata) return;
      final files = engine.getFiles(torrentId!);
      if (files.isEmpty) return;
      metadata.complete(_metadataFromLibtorrent(info.name, files));
    }

    subscription = engine.torrentUpdates.listen(
      inspectSnapshot,
      onError: (Object error, StackTrace stackTrace) {
        if (!metadata.isCompleted) {
          metadata.completeError(error, stackTrace);
        }
      },
    );
    inspectSnapshot(engine.torrents);

    // 作者: long
    // Magnet 必须先通过 DHT/Tracker 取回 metadata 才能让用户选文件；预览使用临时目录且禁止后台下载，确认前不会创建任务或留下业务文件。
    return await metadata.future.timeout(timeout);
  } finally {
    await subscription?.cancel();
    if (torrentId != null && LibtorrentFlutter.isInitialized) {
      try {
        LibtorrentFlutter.instance.removeTorrent(torrentId, deleteFiles: true);
      } catch (_) {
        // 作者: long
        // metadata 获取的临时 torrent 可能已由底层移除，清理失败不应覆盖真实的解析结果。
      }
    }
    try {
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    } catch (_) {
      // 作者: long
      // 系统临时目录由操作系统兜底清理，不因收尾失败阻断用户创建任务。
    }
  }
}

Future<String> _prepareMagnetSource(String source) async {
  await TrackerManager.fetchBestTrackers();
  var magnet = source;
  for (final tracker in _fallbackMagnetTrackers) {
    final encoded = Uri.encodeComponent(tracker);
    if (magnet.contains('tr=$encoded') || magnet.contains('tr=$tracker')) {
      continue;
    }
    magnet = '$magnet&tr=$encoded';
  }
  return magnet;
}

TorrentMetadata parseTorrentMetadataBytes(List<int> bytes) {
  final parser = _BencodeParser(Uint8List.fromList(bytes));
  final root = parser.parse();
  if (root is! Map<String, Object?>) {
    throw const FormatException('Torrent root must be a dictionary.');
  }
  final info = root['info'];
  if (info is! Map<String, Object?>) {
    throw const FormatException('Torrent info dictionary is missing.');
  }

  final name =
      _bencodedString(info['name.utf-8']) ??
      _bencodedString(info['name']) ??
      'torrent-download';
  final files = <TorrentFileEntry>[];
  final rawFiles = info['files'];
  if (rawFiles is List<Object?>) {
    for (final rawFile in rawFiles) {
      if (rawFile is! Map<String, Object?>) {
        continue;
      }
      final pathParts =
          _bencodedStringList(rawFile['path.utf-8']) ??
          _bencodedStringList(rawFile['path']) ??
          const <String>[];
      final path = pathParts.where((part) => part.trim().isNotEmpty).join('/');
      final length = _bencodedInt(rawFile['length']) ?? 0;
      if (path.trim().isEmpty || length < 0) {
        continue;
      }
      files.add(
        TorrentFileEntry(
          index: files.length,
          path: path,
          name: p.basename(path),
          size: length,
          isStreamable: _isStreamable(path),
        ),
      );
    }
  } else {
    final length = _bencodedInt(info['length']) ?? 0;
    files.add(
      TorrentFileEntry(
        index: 0,
        path: name,
        name: p.basename(name),
        size: length,
        isStreamable: _isStreamable(name),
      ),
    );
  }

  if (files.isEmpty) {
    throw const FormatException('Torrent does not contain downloadable files.');
  }
  return TorrentMetadata(name: name, files: List.unmodifiable(files));
}

String torrentDisplayName(
  TorrentMetadata metadata, {
  required List<int> selectedIndexes,
}) {
  final baseName = metadata.name.trim().isEmpty
      ? 'torrent-download'
      : metadata.name.trim();
  return normalizeFileName(baseName);
}

Future<List<int>?> _readTorrentBytesFromSource(
  String source, {
  http.Client? client,
}) async {
  final normalized = source.trim();
  if (normalized.isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(normalized);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    final ownedClient = client == null;
    final effectiveClient = client ?? http.Client();
    try {
      final response = await effectiveClient.get(uri);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      return response.bodyBytes;
    } finally {
      if (ownedClient) {
        effectiveClient.close();
      }
    }
  }

  final path = uri != null && uri.scheme == 'file'
      ? uri.toFilePath()
      : normalized;
  final file = File(path);
  if (!await file.exists()) {
    return null;
  }
  return file.readAsBytes();
}

TorrentMetadata _metadataFromLibtorrent(String name, List<FileInfo> files) {
  final entries = files
      .map(
        (file) => TorrentFileEntry(
          index: file.index,
          path: file.path.trim().isEmpty ? file.name : file.path,
          name: file.name.trim().isEmpty ? p.basename(file.path) : file.name,
          size: file.size,
          isStreamable: file.isStreamable,
        ),
      )
      .toList(growable: false);
  final metadataName = name.trim().isEmpty ? 'torrent-download' : name.trim();
  return TorrentMetadata(name: metadataName, files: List.unmodifiable(entries));
}

List<int> _validSelectedIndexes(
  List<TorrentFileEntry> files,
  List<int> selectedIndexes,
) {
  final known = files.map((file) => file.index).toSet();
  return selectedIndexes.where(known.contains).toSet().toList(growable: false)
    ..sort();
}

List<TorrentFileEntry> _selectedFiles(
  List<TorrentFileEntry> files,
  List<int> selectedIndexes,
) {
  final selected = selectedIndexes.toSet();
  return files
      .where((file) => selected.contains(file.index))
      .toList(growable: false);
}

String? _bencodedString(Object? value) {
  if (value is Uint8List) {
    return utf8.decode(value, allowMalformed: true);
  }
  if (value is String) {
    return value;
  }
  return null;
}

List<String>? _bencodedStringList(Object? value) {
  if (value is! List<Object?>) {
    return null;
  }
  return value.map(_bencodedString).whereType<String>().toList(growable: false);
}

int? _bencodedInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

bool _isStreamable(String path) {
  final extension = p.extension(path).toLowerCase();
  return const {
    '.mp4',
    '.mkv',
    '.avi',
    '.mov',
    '.m4v',
    '.webm',
    '.ts',
    '.mp3',
    '.m4a',
    '.aac',
    '.flac',
  }.contains(extension);
}

class _BencodeParser {
  _BencodeParser(this.bytes);

  final Uint8List bytes;
  var offset = 0;

  Object? parse() {
    if (offset >= bytes.length) {
      throw const FormatException('Unexpected end of bencode data.');
    }
    final code = bytes[offset];
    if (code == 0x69) {
      return _parseInt();
    }
    if (code == 0x6c) {
      return _parseList();
    }
    if (code == 0x64) {
      return _parseDict();
    }
    if (code >= 0x30 && code <= 0x39) {
      return _parseBytes();
    }
    throw FormatException('Invalid bencode token at $offset.');
  }

  int _parseInt() {
    offset += 1;
    final start = offset;
    while (offset < bytes.length && bytes[offset] != 0x65) {
      offset += 1;
    }
    if (offset >= bytes.length) {
      throw const FormatException('Unterminated bencode integer.');
    }
    final value = utf8.decode(bytes.sublist(start, offset));
    offset += 1;
    return int.parse(value);
  }

  List<Object?> _parseList() {
    offset += 1;
    final list = <Object?>[];
    while (offset < bytes.length && bytes[offset] != 0x65) {
      list.add(parse());
    }
    if (offset >= bytes.length) {
      throw const FormatException('Unterminated bencode list.');
    }
    offset += 1;
    return list;
  }

  Map<String, Object?> _parseDict() {
    offset += 1;
    final map = <String, Object?>{};
    while (offset < bytes.length && bytes[offset] != 0x65) {
      final key = _parseBytes();
      map[utf8.decode(key, allowMalformed: true)] = parse();
    }
    if (offset >= bytes.length) {
      throw const FormatException('Unterminated bencode dictionary.');
    }
    offset += 1;
    return map;
  }

  Uint8List _parseBytes() {
    final start = offset;
    while (offset < bytes.length && bytes[offset] != 0x3a) {
      final code = bytes[offset];
      if (code < 0x30 || code > 0x39) {
        throw FormatException('Invalid bencode byte string at $offset.');
      }
      offset += 1;
    }
    if (offset >= bytes.length) {
      throw const FormatException('Unterminated bencode byte string length.');
    }
    final length = int.parse(utf8.decode(bytes.sublist(start, offset)));
    offset += 1;
    final end = offset + length;
    if (end > bytes.length) {
      throw const FormatException('Bencode byte string exceeds input length.');
    }
    final value = Uint8List.fromList(bytes.sublist(offset, end));
    offset = end;
    return value;
  }
}

const _fallbackMagnetTrackers = [
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://opentracker.i2p.rocks:6969/announce',
  'http://tracker.openbittorrent.com:80/announce',
  'udp://open.stealth.si:80/announce',
  'udp://tracker.openbittorrent.com:6969/announce',
  'udp://tracker.tiny-vps.com:6969/announce',
  'udp://epider.me:6969/announce',
  'udp://movies.zsw.ca:6969/announce',
  'udp://open.free-tracker.ga:6969/announce',
  'udp://p4p.arenabg.com:1337/announce',
  'udp://retracker01-msk-virt.corbina.net:80/announce',
  'udp://tracker.bittor.pw:1337/announce',
  'udp://tracker.dump.cl:6969/announce',
  'udp://tracker.moeking.me:6969/announce',
  'udp://tracker.theoks.net:6969/announce',
  'udp://tracker1.bt.moack.co.kr:80/announce',
  'udp://uploads.gamecoast.net:6969/announce',
  'udp://explodie.org:6969/announce',
  'udp://exodus.desync.com:6969/announce',
  'udp://tracker.torrent.eu.org:451/announce',
  'udp://open.demonii.com:1337/announce',
  'https://tracker.nanoha.org:443/announce',
];
