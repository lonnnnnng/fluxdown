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
/// Flutter 队列仍负责承载 handedOff 等移动端专属状态；可由 Rust 执行的任务
/// 会通过完整字段导入 native queue.json，再以任务 ID 幂等对齐，避免重启后重复入队。
class RustQueueBackend {
  RustQueueBackend({required this.core, required this.storePath});

  final FluxDownCoreFfi core;
  final String storePath;

  bool supportsTask(DownloadTask task) {
    // 作者: long
    // Rust 队列覆盖 HTTP/WebDAV 家族、HLS VOD，以及已经完成 metadata 选择的
    // Torrent/Magnet。移动端仍用 libtorrent 负责二次确认和文件树选择，确认结果写入任务后
    // 再交给 Rust 执行，避免在 metadata 选择完成前改变用户行为。
    return switch (task.protocol) {
      'http' ||
      'https' ||
      'webdav' ||
      'webdavs' ||
      'ftp' ||
      'ftps' ||
      'sftp' ||
      'smb' ||
      'm3u8' => true,
      'torrent' || 'magnet' => task.torrentFiles.isNotEmpty,
      _ => false,
    };
  }

  FluxDownCoreTask enqueue(DownloadTask task) {
    return core.queueAdd(storePath, _requestFor(task));
  }

  void ensureTasks(Iterable<DownloadTask> tasks) {
    final existing = list().map((task) => task.id).toSet();
    for (final task in tasks) {
      if (supportsTask(task) && !existing.contains(task.id)) {
        core.queueUpsert(storePath, _taskPayload(task));
      }
    }
  }

  /// 将冲突合并后的完整快照写回 Rust 队列。
  ///
  /// `ensureTasks` 只负责补齐缺失任务，不能覆盖 native 中较旧的同 ID 快照；
  /// 迁移事务需要显式 upsert，才能把 Flutter 侧较新的设置、状态和进度同步回去。
  void upsertTasks(Iterable<DownloadTask> tasks) {
    for (final task in tasks) {
      if (supportsTask(task)) {
        core.queueUpsert(storePath, _taskPayload(task));
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
    Map<String, Map<String, String>> runtimeCredentials = const {},
    Duration pollInterval = const Duration(milliseconds: 200),
    FutureOr<void> Function(List<FluxDownCoreTask> tasks)? onProgress,
  }) async {
    final handle = core.queueRunQueuedAsync(storePath, {
      'concurrency': concurrency,
      'threadCount': threadCount,
      'retryAttempts': retryAttempts,
      'speedLimitKbps': speedLimitKbps,
      'runtimeCredentials': runtimeCredentials,
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
    Map<String, String>? runtimeCredential,
    Duration pollInterval = const Duration(milliseconds: 200),
    FutureOr<void> Function(List<FluxDownCoreTask> tasks)? onProgress,
  }) async {
    final handle = core.queueRunWithOptionsAsync(storePath, taskId, {
      'threadCount': threadCount,
      'retryAttempts': retryAttempts,
      'speedLimitKbps': speedLimitKbps,
      if (runtimeCredential != null)
        'runtimeCredentials': {taskId: runtimeCredential},
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
      'credentialRef': task.credentialRef,
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
      'state': task.state.name,
      'downloadedBytes': task.downloadedBytes,
      'totalBytes': task.totalBytes,
      'currentSpeedBytesPerSecond': task.currentSpeedBytesPerSecond,
      'error': task.error,
      'speedLimitMbps': task.speedLimitMbps,
      'createdAtMs': task.createdAt.millisecondsSinceEpoch,
      'updatedAtMs': task.updatedAt.millisecondsSinceEpoch,
      'startedAtMs': task.startedAt?.millisecondsSinceEpoch,
      'finishedAtMs': task.finishedAt?.millisecondsSinceEpoch,
      'handoffBackend': task.handoffBackend,
      'handedOffAtMs': task.handedOffAt?.millisecondsSinceEpoch,
    };
  }

  Map<String, Object?> _taskPayload(DownloadTask task) => _requestFor(task);
}
