import 'dart:async';

import 'download_task.dart';
import 'ffi/fluxdown_ffi.dart';

/// Rust 队列异步运行的统一结果，保留核心报告或错误供控制器决定回退策略。
class RustQueueRunResult {
  const RustQueueRunResult({required this.state, this.report, this.error});

  final String state;
  final Map<String, Object?>? report;
  final String? error;

  bool get finished => state == 'finished';
  bool get failed => state == 'failed';
}

/// 移动端 Rust 队列的迁移适配层。
///
/// 该类使用独立的 Rust queue.json，不直接覆盖 Flutter camelCase 队列；
/// 这样 Rust 后端异常时仍可安全回退 Dart 控制器，等 schema 转换完成后再接入生产入口。
class RustQueueBackend {
  RustQueueBackend({required this.core, required this.storePath});

  final FluxDownCoreFfi core;
  final String storePath;

  FluxDownCoreTask enqueue(DownloadTask task) {
    return core.queueAdd(storePath, _requestFor(task));
  }

  void ensureTasks(Iterable<DownloadTask> tasks) {
    final existing = list().map((task) => task.id).toSet();
    for (final task in tasks) {
      if (!existing.contains(task.id)) {
        enqueue(task);
      }
    }
  }

  List<FluxDownCoreTask> list() => core.queueList(storePath);

  FluxDownCoreTask pause(String taskId) => core.queuePause(storePath, taskId);

  FluxDownCoreTask resume(String taskId) => core.queueResume(storePath, taskId);

  void remove(String taskId) => core.queueRemove(storePath, taskId);

  FluxDownCoreTask reset(String taskId) => core.queueReset(storePath, taskId);

  Future<RustQueueRunResult> runQueued({
    int concurrency = 5,
    int threadCount = 16,
    int retryAttempts = 3,
    int speedLimitKbps = 0,
    Duration pollInterval = const Duration(milliseconds: 200),
    FutureOr<void> Function(List<FluxDownCoreTask> tasks)? onProgress,
  }) async {
    final handle = core.queueRunQueuedAsync(storePath, {
      'concurrency': concurrency,
      'threadCount': threadCount,
      'retryAttempts': retryAttempts,
      'speedLimitKbps': speedLimitKbps,
    });
    final runId = handle['runId'];
    if (runId is! String || runId.isEmpty) {
      throw const FluxDownCoreException('Rust 队列未返回运行句柄');
    }

    return _pollRun(runId, pollInterval: pollInterval, onProgress: onProgress);
  }

  Future<RustQueueRunResult> runTask(
    String taskId, {
    int threadCount = 16,
    int retryAttempts = 3,
    int speedLimitKbps = 0,
    Duration pollInterval = const Duration(milliseconds: 200),
    FutureOr<void> Function(List<FluxDownCoreTask> tasks)? onProgress,
  }) async {
    final handle = core.queueRunWithOptionsAsync(storePath, taskId, {
      'threadCount': threadCount,
      'retryAttempts': retryAttempts,
      'speedLimitKbps': speedLimitKbps,
    });
    final runId = handle['runId'];
    if (runId is! String || runId.isEmpty) {
      throw const FluxDownCoreException('Rust 单任务未返回运行句柄');
    }
    return _pollRun(runId, pollInterval: pollInterval, onProgress: onProgress);
  }

  Future<RustQueueRunResult> _pollRun(
    String runId, {
    required Duration pollInterval,
    FutureOr<void> Function(List<FluxDownCoreTask> tasks)? onProgress,
  }) async {
    try {
      while (true) {
        final tasks = core.queueList(storePath);
        await onProgress?.call(tasks);
        final status = core.queueRunStatus(runId);
        final state = status['state'] as String? ?? 'failed';
        if (state == 'finished' || state == 'failed') {
          return RustQueueRunResult(
            state: state,
            report: (status['report'] as Map?)?.cast<String, Object?>(),
            error: status['error'] as String?,
          );
        }
        await Future<void>.delayed(pollInterval);
      }
    } finally {
      // 作者: long
      // 只有终态句柄才能被 Rust 回收；异常时尝试回收，若仍在运行则保留句柄避免丢失可观测状态。
      try {
        core.queueRunForget(runId);
      } on Object {
        // 运行句柄仍在执行时由 Rust 保留，下一次状态轮询可以继续接管。
      }
    }
  }

  Map<String, Object?> _requestFor(DownloadTask task) {
    return {
      'taskId': task.id,
      'source': task.source,
      'outputDir': task.outputFolder,
      'fileName': task.fileName,
      'expectedSha256': task.expectedSha256,
      'torrentFileIndices': task.selectedTorrentFileIndexes,
      'torrentName': task.torrentName,
      'torrentFiles': task.torrentFiles
          .map(
            (file) => {
              'index': file.index,
              'path': file.path,
              'name': file.name,
              'size': file.size,
              'isStreamable': file.isStreamable,
            },
          )
          .toList(growable: false),
      'hlsVariantIndex': task.hlsVariantIndex,
      'hlsKeepTransportStream': task.hlsKeepTransportStream,
    };
  }
}
