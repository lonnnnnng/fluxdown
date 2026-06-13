import 'dart:async';

import 'download_task.dart';
import 'mobile_downloader.dart';
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
  Future<void> _saveQueue = Future.value();
  Future<MobileQueueRunReport>? _queueRun;
  _QueueRunRequest? _pendingQueueRun;

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  bool get hasRunnableTasks => _tasks.any((task) => task.canRun);

  Future<void> load() async {
    _tasks
      ..clear()
      ..addAll(await _store.load());
    _tasks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _emit();
  }

  Future<DownloadTask> add({
    required String source,
    required String outputFolder,
    String? fileName,
  }) async {
    final task = DownloadTask.create(
      source: source,
      outputFolder: outputFolder,
      fileName: fileName,
    );
    _tasks.insert(0, task);
    await _save();
    _emit();
    return task;
  }

  Future<void> remove(String id) async {
    _runner.cancel(id);
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
      ),
    );
    await _save();
    _emit();
  }

  Future<void> resetForRedownload(String id) async {
    _runner.cancel(id);
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
    int maxRetries = 0,
    int speedLimitKbps = 0,
    int threadCount = 8,
  }) async {
    if (_activeTaskIds.contains(id)) {
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
      );
    } finally {
      _activeTaskIds.remove(id);
    }
  }

  Future<void> _startActiveTask(
    String id, {
    required int maxRetries,
    required int speedLimitKbps,
    required int threadCount,
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
          onProgress: (progress) async {
            _replace(progress.id, (_) => progress);
            await _save();
            _emit();
          },
        );
        _replace(
          id,
          (_) => finished.copyWith(
            finishedAt: DateTime.now().toUtc(),
            clearPausedAt: true,
            currentSpeedBytesPerSecond: 0,
          ),
        );
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
        if (attempt + 1 < totalAttempts) {
          _replace(
            id,
            (_) => latest.copyWith(
              state: DownloadState.running,
              error: error.toString(),
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
            error: error.toString(),
            finishedAt: DateTime.now().toUtc(),
            clearPausedAt: true,
            currentSpeedBytesPerSecond: 0,
          ),
        );
      }
    }

    await _save();
    _emit();
  }

  Future<MobileQueueRunReport> runQueued({
    int concurrency = 1,
    int maxRetries = 0,
    int speedLimitKbps = 0,
    int threadCount = 8,
  }) {
    final request = _QueueRunRequest(
      concurrency: concurrency,
      maxRetries: maxRetries,
      speedLimitKbps: speedLimitKbps,
      threadCount: threadCount,
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
  });

  final int concurrency;
  final int maxRetries;
  final int speedLimitKbps;
  final int threadCount;
}
