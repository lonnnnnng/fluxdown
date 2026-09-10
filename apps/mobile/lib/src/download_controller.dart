import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:pointycastle/digests/sha256.dart';

import 'download_defaults.dart';
import 'download_failure.dart';
import 'download_task.dart';
import 'mobile_downloader.dart';
import 'mobile_torrent.dart';
import 'protocol.dart';
import 'task_store.dart';

class MobileQueueRunReport {
  const MobileQueueRunReport({
    required this.totalQueued,
    required this.started,
    required this.finished,
    required this.failed,
  });

  final int totalQueued;
  final int started;
  final int finished;
  final int failed;
}

class DownloadController {
  DownloadController({
    TaskStore? store,
    MobileDownloadRunner? runner,
    void Function()? onChanged,
  }) : _store = store ?? TaskStore(),
       _runner = runner ?? MobileDownloadRunner(),
       _onChanged = onChanged;

  final TaskStore _store;
  final MobileDownloadRunner _runner;
  final void Function()? _onChanged;
  final List<DownloadTask> _tasks = [];
  final Set<String> _activeTaskIds = {};
  final Map<String, _StartRequest> _pendingStarts = {};
  Future<void> _saveQueue = Future.value();
  Future<MobileQueueRunReport>? _queueRun;
  _QueueRunRequest? _pendingQueueRun;

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  bool get hasRunnableTasks => _tasks.any((task) => task.canRun);

  Future<void> load() async {
    _tasks
      ..clear()
      ..addAll(await _store.load());
    final interruptedAt = DateTime.now().toUtc();
    var recoveredInterruptedTask = false;
    for (var index = 0; index < _tasks.length; index += 1) {
      final task = _tasks[index];
      if (task.state != DownloadState.running) {
        continue;
      }
      // 作者: long
      // Controller 刚创建时没有存活的下载 Future，持久化 running 只能来自上次被系统终止的进程；立即恢复为暂停，保留断点并释放队列并发槽位。
      _tasks[index] = task.copyWith(
        state: DownloadState.paused,
        pausedAt: interruptedAt,
        clearFinishedAt: true,
        currentSpeedBytesPerSecond: 0,
        error: '任务因应用退出中断，已暂停，可继续下载。',
      );
      recoveredInterruptedTask = true;
    }
    _tasks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (recoveredInterruptedTask) {
      await _save();
    }
    _emit();
  }

  Future<DownloadTask> add({
    required String source,
    required String outputFolder,
    String? fileName,
    String? torrentName,
    List<TorrentFileEntry> torrentFiles = const [],
    List<int>? selectedTorrentFileIndexes,
    String? expectedSha256,
    int? hlsVariantIndex,
    bool hlsKeepTransportStream = false,
  }) async {
    final task = DownloadTask.create(
      source: source,
      outputFolder: outputFolder,
      fileName: fileName,
      torrentName: torrentName,
      torrentFiles: torrentFiles,
      selectedTorrentFileIndexes: selectedTorrentFileIndexes,
      expectedSha256: expectedSha256,
      hlsVariantIndex: hlsVariantIndex,
      hlsKeepTransportStream: hlsKeepTransportStream,
    );
    _tasks.insert(0, task);
    await _save();
    _emit();
    return task;
  }

  Future<void> remove(String id) async {
    _runner.cancel(id);
    _pendingStarts.remove(id);
    _tasks.removeWhere((task) => task.id == id);
    await _save();
    _emit();
  }

  Future<void> pause(String id) async {
    _runner.cancel(id);
    final now = DateTime.now().toUtc();
    _replace(
      id,
      (task) => task.copyWith(
        state: DownloadState.paused,
        pausedAt: now,
        currentSpeedBytesPerSecond: 0,
        clearError: true,
      ),
    );
    await _save();
    _emit();
  }

  Future<void> resetForRedownload(String id) async {
    _runner.cancel(id);
    _pendingStarts.remove(id);
    _replace(
      id,
      (task) => task.copyWith(
        state: DownloadState.queued,
        downloadedBytes: 0,
        clearTotalBytes: true,
        clearError: true,
        clearStartedAt: true,
        clearPausedAt: true,
        clearFinishedAt: true,
        currentSpeedBytesPerSecond: 0,
      ),
    );
    await _save();
    _emit();
  }

  Future<void> start(
    String id, {
    int maxRetries = defaultRetryAttempts,
    int speedLimitKbps = 0,
    int threadCount = defaultDownloadThreadCount,
    TorrentMetadataSelector? onTorrentMetadata,
  }) async {
    if (_activeTaskIds.contains(id)) {
      final task = _maybeTaskById(id);
      if (task != null && task.canRun) {
        _pendingStarts[id] = _StartRequest(
          maxRetries: maxRetries,
          speedLimitKbps: speedLimitKbps,
          threadCount: threadCount,
          onTorrentMetadata: onTorrentMetadata,
        );
      }
      return;
    }
    final task = _maybeTaskById(id);
    if (task == null || !task.canRun) {
      return;
    }
    _activeTaskIds.add(id);
    try {
      await _startActiveTask(
        id,
        maxRetries: maxRetries,
        speedLimitKbps: speedLimitKbps,
        threadCount: threadCount,
        onTorrentMetadata: onTorrentMetadata,
      );
    } finally {
      _activeTaskIds.remove(id);
      final pending = _pendingStarts.remove(id);
      final latest = _maybeTaskById(id);
      if (pending != null && latest != null && latest.canRun) {
        // 作者: long
        // 用户暂停后马上点继续时，上一轮下载 Future 可能还没释放 active 标记；这里在旧任务真正收尾后补启动，避免“点了继续但没反应”。
        unawaited(
          start(
            id,
            maxRetries: pending.maxRetries,
            speedLimitKbps: pending.speedLimitKbps,
            threadCount: pending.threadCount,
            onTorrentMetadata: pending.onTorrentMetadata,
          ),
        );
      }
    }
  }

  Future<void> _startActiveTask(
    String id, {
    required int maxRetries,
    required int speedLimitKbps,
    required int threadCount,
    TorrentMetadataSelector? onTorrentMetadata,
  }) async {
    final task = _taskById(id);
    final support = supportStatus(task.protocol);
    if (!support.executable || !task.isBuiltInMobile) {
      _replace(
        id,
        (current) =>
            current.copyWith(state: DownloadState.failed, error: support.note),
      );
      await _save();
      _emit();
      return;
    }

    final totalAttempts = maxRetries.clamp(0, 10).toInt() + 1;
    final effectiveThreadCount = threadCount.clamp(1, 32).toInt();
    for (var attempt = 0; attempt < totalAttempts; attempt += 1) {
      if (_maybeTaskById(id) == null) {
        return;
      }

      final now = DateTime.now().toUtc();
      _replace(
        id,
        (current) => current.copyWith(
          state: DownloadState.running,
          clearError: true,
          startedAt: _startedAtForRun(current, now),
          clearPausedAt: true,
          clearFinishedAt: true,
          currentSpeedBytesPerSecond: 0,
        ),
      );
      await _save();
      _emit();

      try {
        final finished = await _runner.download(
          _taskById(id),
          speedLimitKbps: speedLimitKbps,
          threadCount: effectiveThreadCount,
          onTorrentMetadata: onTorrentMetadata,
          onProgress: (progress) async {
            _replace(progress.id, (current) {
              // 作者: long
              // 暂停已先写入队列，旧下载 Future 可能仍送达最后一次进度；保留用户的暂停状态，避免它被迟到回调改回 downloading。
              return current.state == DownloadState.paused ? current : progress;
            });
            await _save();
            _emit();
          },
        );
        final latestAfterDownload = _maybeTaskById(id);
        if (latestAfterDownload == null ||
            latestAfterDownload.state == DownloadState.paused) {
          // 作者: long
          // 某些协议在取消信号与最终落盘同时发生时仍可能返回完成；用户已经选择暂停时不允许旧 Future 覆盖该状态。
          return;
        }
        var completed = finished.copyWith(
          finishedAt: finished.state == DownloadState.finished
              ? DateTime.now().toUtc()
              : null,
          clearFinishedAt: finished.state != DownloadState.finished,
          clearPausedAt: true,
          currentSpeedBytesPerSecond: 0,
        );
        // 作者: long
        // SHA-256 校验与桌面端语义一致：下载成功后核对产物哈希，不匹配按失败处理；
        // torrent 任务是目录/多文件产物，哈希校验不适用，直接跳过。
        // 未配置 SHA-256 的任务必须走同步路径完成状态落库，不引入额外 await，
        // 否则会改变既有“完成即可见”的时序约定。
        final needsSha256Verification =
            completed.state == DownloadState.finished &&
            normalizeSha256Text(completed.expectedSha256) != null;
        if (needsSha256Verification) {
          final mismatch = await _verifyExpectedSha256(completed);
          if (mismatch != null) {
            completed = completed.copyWith(
              state: DownloadState.failed,
              error: mismatch,
              finishedAt: DateTime.now().toUtc(),
            );
          }
        }
        _replace(id, (_) => completed);
        await _save();
        _emit();
        return;
      } on DownloadCancelled {
        final latest = _maybeTaskById(id);
        if (latest == null) {
          return;
        }
        _replace(
          id,
          (_) => latest.copyWith(
            state: DownloadState.paused,
            pausedAt: DateTime.now().toUtc(),
            currentSpeedBytesPerSecond: 0,
            clearError: true,
          ),
        );
        await _save();
        _emit();
        return;
      } on Object catch (error) {
        final latest = _maybeTaskById(id);
        if (latest == null) {
          return;
        }
        if (latest.state == DownloadState.paused) {
          return;
        }
        final failure = describeDownloadFailure(
          error,
          source: latest.source,
          protocol: latest.protocol,
        );
        if (failure.retryable && attempt + 1 < totalAttempts) {
          _replace(
            id,
            (_) => latest.copyWith(
              state: DownloadState.running,
              error: '${failure.message} 正在自动重试。',
              clearPausedAt: true,
              clearFinishedAt: true,
              currentSpeedBytesPerSecond: 0,
            ),
          );
          await _save();
          _emit();
          continue;
        }
        _replace(
          id,
          (_) => latest.copyWith(
            state: DownloadState.failed,
            error: failure.message,
            finishedAt: DateTime.now().toUtc(),
            clearPausedAt: true,
            currentSpeedBytesPerSecond: 0,
          ),
        );
        break;
      }
    }

    await _save();
    _emit();
  }

  Future<MobileQueueRunReport> runQueued({
    int concurrency = defaultQueueConcurrency,
    int maxRetries = defaultRetryAttempts,
    int speedLimitKbps = 0,
    int threadCount = defaultDownloadThreadCount,
    TorrentMetadataSelector? onTorrentMetadata,
  }) {
    final request = _QueueRunRequest(
      concurrency: concurrency,
      maxRetries: maxRetries,
      speedLimitKbps: speedLimitKbps,
      threadCount: threadCount,
      onTorrentMetadata: onTorrentMetadata,
    );
    final activeRun = _queueRun;
    if (activeRun != null) {
      _pendingQueueRun = request;
      return activeRun;
    }

    return _startQueueRun(request);
  }

  Future<MobileQueueRunReport> _startQueueRun(_QueueRunRequest request) {
    late final Future<MobileQueueRunReport> queueRun;
    queueRun =
        _runQueuedInternal(
          concurrency: request.concurrency,
          maxRetries: request.maxRetries,
          speedLimitKbps: request.speedLimitKbps,
          threadCount: request.threadCount,
          onTorrentMetadata: request.onTorrentMetadata,
        ).whenComplete(() {
          if (identical(_queueRun, queueRun)) {
            _queueRun = null;
          }
          final pending = _pendingQueueRun;
          if (pending != null) {
            _pendingQueueRun = null;
            if (_tasks.any((task) => task.state == DownloadState.queued)) {
              unawaited(_startQueueRun(pending));
            }
          }
        });
    _queueRun = queueRun;
    return queueRun;
  }

  Future<MobileQueueRunReport> _runQueuedInternal({
    required int concurrency,
    required int maxRetries,
    required int speedLimitKbps,
    required int threadCount,
    TorrentMetadataSelector? onTorrentMetadata,
  }) async {
    final workerCount = concurrency.clamp(1, 30).toInt();
    final seen = <String>{};
    var started = 0;
    var finished = 0;
    var failed = 0;

    Future<void> worker() async {
      while (true) {
        final id = _nextQueuedTaskId();
        if (id == null) return;

        seen.add(id);
        started += 1;
        await start(
          id,
          maxRetries: maxRetries,
          speedLimitKbps: speedLimitKbps,
          threadCount: threadCount,
          onTorrentMetadata: onTorrentMetadata,
        );
        final after = _maybeTaskById(id);
        if (after?.state == DownloadState.finished) {
          finished += 1;
        } else if (after?.state == DownloadState.failed) {
          failed += 1;
        }
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
    return MobileQueueRunReport(
      totalQueued: seen.length,
      started: started,
      finished: finished,
      failed: failed,
    );
  }

  String? _nextQueuedTaskId() {
    DownloadTask? next;
    for (final task in _tasks) {
      if (task.state != DownloadState.queued ||
          _activeTaskIds.contains(task.id)) {
        continue;
      }
      if (next == null || task.createdAt.isBefore(next.createdAt)) {
        next = task;
      }
    }
    return next?.id;
  }

  /// 下载完成后的 SHA-256 校验。返回 null 表示通过（或无需校验），否则返回失败原因。
  Future<String?> _verifyExpectedSha256(DownloadTask task) async {
    final expected = normalizeSha256Text(task.expectedSha256);
    if (expected == null) return null;
    if (expected.length != 64 || !isValidSha256(expected)) {
      return 'SHA-256 校验失败：期望值必须是 64 位十六进制';
    }
    final taskFilePath = p.join(task.outputFolder, task.fileName);
    final file = File(taskFilePath);
    if (!await file.exists()) {
      return 'SHA-256 校验失败：找不到下载产物 $taskFilePath';
    }
    try {
      final digest = SHA256Digest();
      await for (final chunk in file.openRead()) {
        final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        digest.update(bytes, 0, bytes.length);
      }
      final out = Uint8List(digest.digestSize);
      digest.doFinal(out, 0);
      final actual = out
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      if (actual != expected) {
        return 'SHA-256 校验失败：期望 $expected，实际 $actual';
      }
      return null;
    } catch (error) {
      return 'SHA-256 校验失败：读取文件出错（$error）';
    }
  }

  DownloadTask _taskById(String id) {
    return _tasks.firstWhere((task) => task.id == id);
  }

  DownloadTask? _maybeTaskById(String id) {
    final index = _tasks.indexWhere((task) => task.id == id);
    if (index == -1) {
      return null;
    }
    return _tasks[index];
  }

  void _replace(String id, DownloadTask Function(DownloadTask task) update) {
    final index = _tasks.indexWhere((task) => task.id == id);
    if (index == -1) {
      return;
    }
    _tasks[index] = update(_tasks[index]);
  }

  Future<void> _save() {
    final snapshot = List<DownloadTask>.of(_tasks);
    _saveQueue = _saveQueue
        .catchError((_) {})
        .then((_) => _store.save(snapshot));
    return _saveQueue;
  }

  void _emit() {
    _onChanged?.call();
  }
}

DateTime _startedAtForRun(DownloadTask task, DateTime now) {
  final startedAt = task.startedAt;
  if (startedAt == null) {
    return now;
  }
  final pausedAt = task.pausedAt;
  if (task.state != DownloadState.paused || pausedAt == null) {
    return startedAt;
  }
  final pausedDuration = now.difference(pausedAt);
  if (pausedDuration.isNegative) {
    return startedAt;
  }
  return startedAt.add(pausedDuration);
}

class _QueueRunRequest {
  const _QueueRunRequest({
    required this.concurrency,
    required this.maxRetries,
    required this.speedLimitKbps,
    required this.threadCount,
    required this.onTorrentMetadata,
  });

  final int concurrency;
  final int maxRetries;
  final int speedLimitKbps;
  final int threadCount;
  final TorrentMetadataSelector? onTorrentMetadata;
}

class _StartRequest {
  const _StartRequest({
    required this.maxRetries,
    required this.speedLimitKbps,
    required this.threadCount,
    required this.onTorrentMetadata,
  });

  final int maxRetries;
  final int speedLimitKbps;
  final int threadCount;
  final TorrentMetadataSelector? onTorrentMetadata;
}
