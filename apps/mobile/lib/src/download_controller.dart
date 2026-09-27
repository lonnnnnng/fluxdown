import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:pointycastle/digests/sha256.dart';

import 'download_defaults.dart';
import 'download_failure.dart';
import 'download_task.dart';
import 'ffi/fluxdown_ffi.dart';
import 'mobile_downloader.dart';
import 'mobile_credential_store.dart';
import 'mobile_torrent.dart';
import 'protocol.dart';
import 'rust_queue_backend.dart';
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
    RustQueueBackend? rustBackend,
    MobileCredentialVault? credentialVault,
    String? sftpKnownHosts,
    String? rustQueuePath,
    void Function()? onChanged,
  }) : _store = store ?? TaskStore(),
       _runner = runner ?? MobileDownloadRunner(),
       _rustBackend = rustBackend,
       _credentialVault = credentialVault ?? MobileCredentialStore(),
       _sftpKnownHosts = sftpKnownHosts,
       _rustQueuePath = rustQueuePath ?? rustBackend?.storePath,
       _onChanged = onChanged {
    _runner.setSftpKnownHosts(_sftpKnownHosts);
  }

  final TaskStore _store;
  final MobileDownloadRunner _runner;
  final RustQueueBackend? _rustBackend;
  final MobileCredentialVault _credentialVault;
  String? _sftpKnownHosts;
  final String? _rustQueuePath;
  final void Function()? _onChanged;
  final List<DownloadTask> _tasks = [];
  final Map<String, int> _deletedTaskIds = {};
  final Set<String> _activeTaskIds = {};
  final Map<String, _StartRequest> _pendingStarts = {};
  Future<void> _saveQueue = Future.value();
  bool _canonicalPersistenceReady = false;
  Future<MobileQueueRunReport>? _queueRun;
  _QueueRunRequest? _pendingQueueRun;

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  // 作者: long
  /// 设置移动端 SFTP 主机身份策略；内容只作为应用配置传给本次连接，任务 JSON
  /// 仍只保存源链接和凭据引用，避免把主机密钥配置复制到每个任务。
  void setSftpKnownHosts(String? content) {
    final normalized = content?.trim();
    _sftpKnownHosts = normalized == null || normalized.isEmpty
        ? null
        : normalized;
    _runner.setSftpKnownHosts(_sftpKnownHosts);
  }

  bool get hasRunnableTasks => _tasks.any((task) => task.canRun);

  Future<void> load() async {
    final backend = _rustBackend;
    _canonicalPersistenceReady = false;
    if (backend != null) {
      try {
        // 作者: long
        // 先处理上次未提交的迁移事务，再读取 Flutter 队列；否则内存可能继续使用
        // 被中断事务写入的半套快照，导致恢复后的磁盘状态又被旧内存覆盖。
        await _store.recoverPendingMigration(rustQueuePath: backend.storePath);
      } on Object {
        // 恢复异常时不覆盖原始文件；后续 beginMigrationBackup 会再次建立保护边界。
      }
    }
    final flutterSnapshot = await _store.loadSnapshot();
    TaskQueueSnapshot? rustFallbackSnapshot;
    final rustQueuePath = _rustQueuePath;
    if (backend == null && rustQueuePath != null) {
      try {
        rustFallbackSnapshot = await _store.loadRustSnapshot(rustQueuePath);
      } on Object {
        // Rust 文件损坏或版本过新时保留 Flutter 侧快照，避免一次升级直接清空列表。
        rustFallbackSnapshot = null;
      }
    }
    final initialTasks = rustFallbackSnapshot == null
        ? flutterSnapshot.tasks
        : [
            ...rustFallbackSnapshot.tasks,
            ...flutterSnapshot.tasks.where(
              (task) => task.state == DownloadState.handedOff,
            ),
          ];
    _tasks
      ..clear()
      ..addAll(initialTasks);
    _deletedTaskIds
      ..clear()
      ..addAll(rustFallbackSnapshot?.deletedTaskIds ?? const {})
      ..addAll(flutterSnapshot.deletedTaskIds);
    _tasks.removeWhere((task) => _deletedTaskIds.containsKey(task.id));
    QueueMigrationBackup? migrationBackup;
    var migrationFailed = false;
    if (backend != null) {
      try {
        // 作者: long
        // Flutter/Rust 队列在迁移期间必须共享同一份可恢复快照；先建立事务 marker，
        // 再处理 running 恢复和双向合并，避免 App 在中途被杀后留下半套状态。
        migrationBackup = await _store.beginMigrationBackup(
          rustQueuePath: backend.storePath,
        );
      } on Object {
        // 备份失败时不触碰 native 队列，保留 Flutter 队列并让本次启动走 Dart 回退。
        migrationBackup = null;
      }
    }
    final interruptedAt = DateTime.now().toUtc();
    final interruptedTaskIds = <String>{
      for (final task in _tasks)
        if (task.state == DownloadState.running) task.id,
    };
    var recoveredInterruptedTask = false;
    // 作者: long
    // 先记录上次进程留下的 running，不立即把它改成 paused；否则 copyWith 会刷新
    // updatedAt，反而可能让 stale Flutter 快照压过 Rust 已经落盘的 finished 状态。
    // 双队列合并完成后，只对仍没有更可靠 native 终态的任务做中断恢复。
    if (backend == null || migrationBackup == null) {
      recoveredInterruptedTask = _recoverInterruptedTasks(
        interruptedTaskIds,
        interruptedAt,
      );
    }
    _tasks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    var reconciledRustQueue = false;
    if (backend != null && migrationBackup != null) {
      try {
        _purgeRustTombstones(backend);
        // 作者: long
        // App 重新启动后，Rust 的 running 任务已没有可接管的 Flutter 运行句柄；
        // 先转为暂停，再按任务时间戳合并两份快照，避免旧 native 进度覆盖用户保存的队列。
        for (final native in backend.list()) {
          if (native.state == 'running') {
            backend.pause(native.id);
          }
        }
        final merged = _mergeRustTasks(
          backend.list(),
          interruptedTaskIds: interruptedTaskIds,
        );
        _tasks
          ..clear()
          ..addAll(merged);
        recoveredInterruptedTask = _recoverInterruptedTasks(
          interruptedTaskIds,
          interruptedAt,
        );
        // 作者: long
        // 合并结果以任务 ID 为唯一键回写两侧；本地较新的设置/进度会覆盖 native，
        // native 孤儿或较新的运行态则先导入 Flutter，避免双文件各自继续分叉。
        backend.upsertTasks(merged);
        final synchronizedNativeTasks = backend.list();
        _tasks
          ..clear()
          ..addAll(
            _mergeRustTasks(
              synchronizedNativeTasks,
              interruptedTaskIds: interruptedTaskIds,
            ),
          );
        _tasks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        // 作者: long
        // 成功完成首次合并后，Rust 文件成为活动任务的唯一来源；Flutter 文件只保留
        // handedOff 投影。forceCanonical 确保本次迁移不会先写回旧的双队列格式。
        await _save(forceCanonical: true);
        await migrationBackup.commit();
        _canonicalPersistenceReady = true;
        reconciledRustQueue = true;
      } on Object {
        migrationFailed = true;
        try {
          await migrationBackup.restore();
          final restored = await _store.loadSnapshot();
          _tasks
            ..clear()
            ..addAll(restored.tasks);
          _deletedTaskIds
            ..clear()
            ..addAll(restored.deletedTaskIds);
        } on Object {
          // 恢复失败时保留内存中的任务，不覆盖磁盘上的原始文件；下次启动仍会看到 pending marker。
        }
        recoveredInterruptedTask = false;
      }
    }
    if (!migrationFailed && !reconciledRustQueue && recoveredInterruptedTask) {
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
    String? credentialRef,
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
      credentialRef: credentialRef,
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
    _runner.discardTorrent(id);
    // 作者: long
    // 先在内存记录删除时间；canonical 保存会把它写入 Rust deleted_task_ids，
    // 即使 native 队列被运行句柄占用，下一次启动也不会把同一个 ID 重新导入。
    _deletedTaskIds[id] = DateTime.now().toUtc().millisecondsSinceEpoch;
    // 作者: long
    // 删除时同步清掉 native 任务；tombstone 负责处理迟到的进度写回，避免已删除任务复活或继续占用队列。
    try {
      _rustBackend?.remove(id);
    } on Object {
      // Dart-only 任务尚未同步到 Rust 队列时，native 删除失败不应阻止本地删除。
    }
    _pendingStarts.remove(id);
    _tasks.removeWhere((task) => task.id == id);
    await _save();
    _emit();
  }

  Future<void> pause(String id) async {
    _runner.cancel(id);
    try {
      _rustBackend?.pause(id);
    } on Object {
      // 任务仍由 Dart/原生适配器执行，或尚未进入 Rust 队列时忽略 native 侧未找到错误。
    }
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
    _runner.discardTorrent(id);
    try {
      _rustBackend?.reset(id);
    } on Object {
      // 旧任务可能只存在于 Flutter 队列；本地重置仍需继续完成。
    }
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
        clearHandoffBackend: true,
        clearHandedOffAt: true,
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
    final runtime = await _resolveRuntimeTask(task);
    if (runtime == null) return;
    final runtimeTask = runtime.task;
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

    // 作者: long
    // 密码凭据只在本次 FFI 运行参数中注入 Rust；SFTP 私钥没有 Rust 内存协议，继续走
    // Dart 适配器。两条路径都只把 credentialRef 写入任务 JSON，不把秘密落盘。
    final rustCredential = await _loadPasswordCredentialForRust(task);
    if (_rustBackend?.supportsTask(task) == true &&
        (task.credentialRef?.trim().isNotEmpty != true ||
            rustCredential != null)) {
      await _startActiveTaskWithRust(
        task,
        maxRetries: maxRetries,
        speedLimitKbps: speedLimitKbps,
        threadCount: threadCount,
        runtimeCredential: rustCredential,
      );
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
          clearHandoffBackend: true,
          clearHandedOffAt: true,
          currentSpeedBytesPerSecond: 0,
        ),
      );
      await _save();
      _emit();

      try {
        final activeTask = _taskById(id).copyWith(source: runtimeTask.source);
        final finished = await _runner.download(
          activeTask,
          speedLimitKbps: speedLimitKbps,
          threadCount: effectiveThreadCount,
          sftpCredential: runtime.sftpCredential,
          onTorrentMetadata: onTorrentMetadata,
          onProgress: (progress) async {
            _replace(progress.id, (current) {
              // 作者: long
              // 暂停已先写入队列，旧下载 Future 可能仍送达最后一次进度；保留用户的暂停状态，避免它被迟到回调改回 downloading。
              if (current.state == DownloadState.paused) return current;
              // 作者: long
              // 凭据只允许在本次下载请求中存在；进度对象可能被最终持久化，必须恢复原始 URL 和引用名。
              return progress.copyWith(
                source: current.source,
                credentialRef: current.credentialRef,
              );
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
          source: task.source,
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

  Future<_ResolvedRuntimeTask?> _resolveRuntimeTask(DownloadTask task) async {
    final reference = task.credentialRef?.trim();
    if (reference == null || reference.isEmpty) {
      return _ResolvedRuntimeTask(task: task);
    }

    try {
      final credential = await _credentialVault.getCredential(reference);
      if (credential == null) {
        throw const FormatException('凭据引用不存在或无法解密');
      }
      if (credential.usesPrivateKey && task.protocol != 'sftp') {
        throw const FormatException('SFTP 私钥凭据只能用于 SFTP 任务');
      }
      final runtimeSource = credential.usesPrivateKey
          ? sourceWithMobileUsername(task.source, credential.username)
          : sourceWithMobileCredential(task.source, credential);
      // 作者: long
      // 返回值只供当前 Future 使用；保留 credentialRef 让进度/完成快照继续指向安全存储，密码不会进入任务 JSON。
      return _ResolvedRuntimeTask(
        task: task.copyWith(source: runtimeSource),
        sftpCredential: credential.usesPrivateKey ? credential : null,
      );
    } on Object {
      _replace(
        task.id,
        (current) => current.copyWith(
          state: DownloadState.failed,
          error: '移动端凭据不可用，请检查安全存储中的凭据引用。',
          finishedAt: DateTime.now().toUtc(),
          currentSpeedBytesPerSecond: 0,
        ),
      );
      await _save();
      _emit();
      return null;
    }
  }

  Future<MobileCredential?> _loadPasswordCredentialForRust(
    DownloadTask task,
  ) async {
    final reference = task.credentialRef?.trim();
    if (reference == null || reference.isEmpty) return null;
    final credential = await _credentialVault.getCredential(reference);
    if (credential == null || credential.usesPrivateKey) return null;
    return credential;
  }

  Future<void> _startActiveTaskWithRust(
    DownloadTask task, {
    required int maxRetries,
    required int speedLimitKbps,
    required int threadCount,
    MobileCredential? runtimeCredential,
  }) async {
    final backend = _rustBackend!;
    try {
      // 作者: long
      // 单任务入口允许 queued/paused/failed 继续执行；先确保 Flutter 任务已映射到
      // Rust 队列，避免直接启动一个不存在的 native ID。
      final native = backend.list().where((item) => item.id == task.id);
      if (native.isEmpty) {
        backend.enqueue(task);
      }
      final result = await backend.runTask(
        task.id,
        threadCount: threadCount,
        retryAttempts: maxRetries,
        speedLimitKbps: speedLimitKbps,
        runtimeCredential: runtimeCredential == null
            ? null
            : {
                'username': runtimeCredential.username,
                'password': runtimeCredential.password,
              },
        onProgress: (nativeTasks) async {
          _applyRustTasks(nativeTasks);
          await _save();
          _emit();
        },
      );
      _applyRustTasks(backend.list());
      if (result.failed) {
        _replace(
          task.id,
          (current) => current.state == DownloadState.failed
              ? current
              : current.copyWith(
                  state: DownloadState.failed,
                  error: result.error ?? 'Rust 下载失败',
                  finishedAt: DateTime.now().toUtc(),
                  currentSpeedBytesPerSecond: 0,
                ),
        );
      }
      await _save();
      _emit();
    } on Object catch (error) {
      // 这是显式注入 Rust 后端的路径；句柄启动失败时将错误写回任务，避免静默停在 queued。
      _replace(
        task.id,
        (current) => current.copyWith(
          state: DownloadState.failed,
          error: 'Rust 队列启动失败：$error',
          finishedAt: DateTime.now().toUtc(),
          currentSpeedBytesPerSecond: 0,
        ),
      );
      await _save();
      _emit();
    }
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
    final rustReport = await _runQueuedWithRust(
      concurrency: concurrency,
      maxRetries: maxRetries,
      speedLimitKbps: speedLimitKbps,
      threadCount: threadCount,
    );
    final workerCount = concurrency.clamp(1, 30).toInt();
    final seen = <String>{};
    var started = rustReport?.started ?? 0;
    var finished = rustReport?.finished ?? 0;
    var failed = rustReport?.failed ?? 0;
    var totalQueued = rustReport?.totalQueued ?? 0;

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
      totalQueued: totalQueued + seen.length,
      started: started,
      finished: finished,
      failed: failed,
    );
  }

  Future<MobileQueueRunReport?> _runQueuedWithRust({
    required int concurrency,
    required int maxRetries,
    required int speedLimitKbps,
    required int threadCount,
  }) async {
    final backend = _rustBackend;
    if (backend == null) return null;

    try {
      // 作者: long
      // 先把 Rust 中已有的同 ID 终态同步到 Flutter，再决定本轮 queued 集合；
      // 这样应用重启或上次运行完成后不会把同一任务重复下载或永久显示为 queued。
      _applyRustTasks(backend.list());
      await _save();
      _emit();
    } on Object {
      return null;
    }
    final runtimeCredentials = <String, Map<String, String>>{};
    final queued = <DownloadTask>[];
    for (final task in _tasks.where(
      (task) => task.state == DownloadState.queued,
    )) {
      if (!backend.supportsTask(task)) continue;
      final reference = task.credentialRef?.trim();
      if (reference != null && reference.isNotEmpty) {
        final credential = await _loadPasswordCredentialForRust(task);
        if (credential == null) continue;
        runtimeCredentials[task.id] = {
          'username': credential.username,
          'password': credential.password,
        };
      }
      queued.add(task);
    }
    if (queued.isEmpty) {
      return null;
    }

    // 作者: long
    // 只有 Rust 句柄尚未启动时允许初始化失败回退；启动后不能再让 Dart 复制执行同一批任务。
    try {
      backend.ensureTasks(queued);
    } on Object {
      return null;
    }

    late final RustQueueRunResult result;
    try {
      result = await backend.runQueued(
        concurrency: concurrency,
        threadCount: threadCount,
        retryAttempts: maxRetries,
        speedLimitKbps: speedLimitKbps,
        runtimeCredentials: runtimeCredentials,
        onProgress: (nativeTasks) async {
          _applyRustTasks(nativeTasks);
          await _save();
          _emit();
        },
      );
    } on Object catch (error) {
      final message = 'Rust 队列运行失败：$error';
      for (final queuedTask in queued) {
        _replace(
          queuedTask.id,
          (task) => task.copyWith(
            state: DownloadState.failed,
            error: message,
            finishedAt: DateTime.now().toUtc(),
            currentSpeedBytesPerSecond: 0,
          ),
        );
      }
      await _save();
      _emit();
      return MobileQueueRunReport(
        totalQueued: queued.length,
        started: 0,
        finished: 0,
        failed: queued.length,
      );
    }
    _applyRustTasks(backend.list());
    if (result.failed) {
      final message = result.error?.trim().isNotEmpty == true
          ? result.error!.trim()
          : 'Rust 队列执行失败';
      for (final queuedTask in queued) {
        final current = _maybeTaskById(queuedTask.id);
        if (current == null ||
            (current.state != DownloadState.queued &&
                current.state != DownloadState.running)) {
          continue;
        }
        // 作者: long
        // native 句柄失败后不能回退 Dart 重复执行；把尚未进入终态的任务标为失败，
        // 让用户在列表中看到真实原因并可手动重试。
        _replace(
          queuedTask.id,
          (task) => task.copyWith(
            state: DownloadState.failed,
            error: message,
            finishedAt: DateTime.now().toUtc(),
            currentSpeedBytesPerSecond: 0,
          ),
        );
      }
    }
    await _save();
    _emit();

    final report = result.report;
    return MobileQueueRunReport(
      totalQueued: (report?['total_queued'] as num?)?.toInt() ?? queued.length,
      started: (report?['started'] as num?)?.toInt() ?? 0,
      finished: (report?['finished'] as num?)?.toInt() ?? 0,
      failed:
          (report?['failed'] as num?)?.toInt() ??
          (result.failed
              ? queued
                    .where(
                      (task) =>
                          _maybeTaskById(task.id)?.state ==
                          DownloadState.failed,
                    )
                    .length
              : 0),
    );
  }

  void _applyRustTasks(List<FluxDownCoreTask> nativeTasks) {
    final byId = {for (final task in nativeTasks) task.id: task};
    for (var index = 0; index < _tasks.length; index += 1) {
      final current = _tasks[index];
      final native = byId[current.id];
      if (native == null) continue;
      final candidate = native.toDownloadTask();
      if (candidate == null || !_nativeTaskWins(current, candidate)) {
        continue;
      }
      _tasks[index] = candidate;
    }
  }

  List<DownloadTask> _mergeRustTasks(
    List<FluxDownCoreTask> nativeTasks, {
    Set<String> interruptedTaskIds = const <String>{},
  }) {
    final merged = <String, DownloadTask>{
      for (final task in _tasks) task.id: task,
    };
    for (final native in nativeTasks) {
      final candidate = native.toDownloadTask();
      if (candidate == null ||
          _deletedTaskIds.containsKey(candidate.id) ||
          !_rustBackend!.supportsTask(candidate)) {
        continue;
      }
      final current = merged[candidate.id];
      if (current == null ||
          _nativeTaskWins(
            current,
            candidate,
            localWasInterrupted: interruptedTaskIds.contains(candidate.id),
          )) {
        merged[candidate.id] = candidate;
      }
    }
    return merged.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  bool _nativeTaskWins(
    DownloadTask local,
    DownloadTask native, {
    bool localWasInterrupted = false,
  }) {
    if (local.state == DownloadState.handedOff) {
      return false;
    }
    if (localWasInterrupted && native.state == DownloadState.finished) {
      return true;
    }
    if (native.updatedAt.isAfter(local.updatedAt)) {
      return true;
    }
    if (local.updatedAt.isAfter(native.updatedAt)) {
      return false;
    }
    // 作者: long
    // 同一毫秒内的双写没有可靠的先后顺序，优先保留实际下载进度和完成终态，
    // 但不让相同快照因状态排序反复震荡。
    if (native.downloadedBytes > local.downloadedBytes) {
      return true;
    }
    return native.state == DownloadState.finished &&
        local.state != DownloadState.finished;
  }

  bool _recoverInterruptedTasks(Set<String> taskIds, DateTime interruptedAt) {
    var recovered = false;
    for (var index = 0; index < _tasks.length; index += 1) {
      final task = _tasks[index];
      if (!taskIds.contains(task.id) || task.state != DownloadState.running) {
        continue;
      }
      _tasks[index] = task.copyWith(
        state: DownloadState.paused,
        pausedAt: interruptedAt,
        clearFinishedAt: true,
        currentSpeedBytesPerSecond: 0,
        error: '任务因应用退出中断，已暂停，可继续下载。',
      );
      recovered = true;
    }
    return recovered;
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

  Future<void> _save({bool forceCanonical = false}) {
    final snapshot = List<DownloadTask>.of(_tasks);
    final backend = _rustBackend;
    final useCanonical =
        backend != null && (forceCanonical || _canonicalPersistenceReady);
    _saveQueue = _saveQueue.catchError((_) {}).then((_) async {
      if (!useCanonical) {
        await _store.save(
          snapshot,
          deletedTaskIds: Map<String, int>.of(_deletedTaskIds),
        );
        return;
      }
      // 作者: long
      // Rust queue.json 是 native 任务的 canonical 存储；每次投影只 upsert 当前支持的
      // 任务，并将删除 tombstone 写入 Rust，防止迟到进度回调重新生成已删除任务。
      backend.upsertTasks(snapshot.where(backend.supportsTask));
      for (final id in _deletedTaskIds.keys) {
        try {
          backend.remove(id);
        } on Object {
          // native 任务可能正处于终态写回；tombstone 会在下一次投影继续尝试。
        }
      }
      await _store.saveMobileProjection(snapshot);
    });
    return _saveQueue;
  }

  void _purgeRustTombstones(RustQueueBackend backend) {
    for (final id in _deletedTaskIds.keys) {
      try {
        backend.remove(id);
      } on Object {
        // native 文件可能暂时被运行句柄占用；tombstone 会继续阻止本次及后续导入。
      }
    }
  }

  void _emit() {
    _onChanged?.call();
  }
}

class _ResolvedRuntimeTask {
  const _ResolvedRuntimeTask({required this.task, this.sftpCredential});

  final DownloadTask task;
  final MobileCredential? sftpCredential;
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
