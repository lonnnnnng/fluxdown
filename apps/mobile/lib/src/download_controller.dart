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
  Future<void> _saveQueue = Future.value();

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
    _replace(id, (task) => task.copyWith(state: DownloadState.paused));
    await _save();
    _emit();
  }

  Future<void> start(String id) async {
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

    _replace(
      id,
      (current) =>
          current.copyWith(state: DownloadState.running, clearError: true),
    );
    await _save();
    _emit();

    try {
      final finished = await _runner.download(
        _taskById(id),
        onProgress: (progress) async {
          _replace(progress.id, (_) => progress);
          await _save();
          _emit();
        },
      );
      _replace(id, (_) => finished);
    } on DownloadCancelled {
      final latest = _maybeTaskById(id);
      if (latest == null) {
        return;
      }
      _replace(id, (_) => latest.copyWith(state: DownloadState.paused));
    } on Object catch (error) {
      final latest = _maybeTaskById(id);
      if (latest == null) {
        return;
      }
      _replace(
        id,
        (_) => latest.copyWith(
          state: DownloadState.failed,
          error: error.toString(),
        ),
      );
    }

    await _save();
    _emit();
  }

  Future<MobileQueueRunReport> runQueued({int concurrency = 2}) async {
    final pending = _tasks
        .where(
          (task) =>
              task.state == DownloadState.queued ||
              task.state == DownloadState.paused ||
              task.state == DownloadState.failed,
        )
        .map((task) => task.id)
        .toList();
    final totalQueued = pending.length;
    if (pending.isEmpty) {
      return const MobileQueueRunReport(
        totalQueued: 0,
        started: 0,
        finished: 0,
        failed: 0,
      );
    }

    var nextIndex = 0;
    var started = 0;
    var finished = 0;
    var failed = 0;

    Future<void> worker() async {
      while (true) {
        if (nextIndex >= pending.length) {
          return;
        }
        final id = pending[nextIndex];
        nextIndex += 1;
        final before = _maybeTaskById(id);
        if (before == null || !before.canRun) {
          continue;
        }

        started += 1;
        await start(id);
        final after = _maybeTaskById(id);
        if (after?.state == DownloadState.finished) {
          finished += 1;
        } else if (after?.state == DownloadState.failed) {
          failed += 1;
        }
      }
    }

    final workerCount = concurrency.clamp(1, pending.length).toInt();
    await Future.wait(List.generate(workerCount, (_) => worker()));
    return MobileQueueRunReport(
      totalQueued: totalQueued,
      started: started,
      finished: finished,
      failed: failed,
    );
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
