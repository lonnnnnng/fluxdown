import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'download_task.dart';
import 'ffi/fluxdown_ffi.dart';

/// 移动端队列文件格式版本；旧版直接保存 JSON 数组，读取时继续兼容。
const int mobileQueueSchemaVersion = 1;
const int rustQueueSchemaVersion = 2;
const int queueMigrationBackupVersion = 1;

class TaskQueueSnapshot {
  const TaskQueueSnapshot({required this.tasks, required this.deletedTaskIds});

  final List<DownloadTask> tasks;
  final Map<String, int> deletedTaskIds;
}

/// 双队列迁移的可恢复快照。
///
/// 迁移前先把 Flutter/Rust 两份队列写入固定目录，并用 manifest 标记
/// `prepared`。如果 App 在两份文件更新之间被杀死，下次启动可以根据
/// 这个标记恢复原始快照，而不是把半套迁移结果继续当成新状态使用。
class QueueMigrationBackup {
  QueueMigrationBackup._({
    required this.directory,
    required this.manifestFile,
    required this.flutterTarget,
    required this.rustTarget,
    required this.flutterBackup,
    required this.rustBackup,
    required this.flutterExisted,
    required this.rustExisted,
  });

  final Directory directory;
  final File manifestFile;
  final File flutterTarget;
  final File rustTarget;
  final File flutterBackup;
  final File rustBackup;
  final bool flutterExisted;
  final bool rustExisted;

  Future<void> restore() async {
    if (flutterExisted) {
      await _restoreFile(flutterBackup, flutterTarget);
    } else {
      await _deleteIfExists(flutterTarget);
    }
    if (rustExisted) {
      await _restoreFile(rustBackup, rustTarget);
    } else {
      await _deleteIfExists(rustTarget);
    }
    await _writeManifestState('recovered');
  }

  Future<void> commit() => _writeManifestState('committed');

  Future<void> _writeManifestState(String state) async {
    await _writeJsonAtomically(manifestFile, {
      'version': queueMigrationBackupVersion,
      'state': state,
      'flutterExisted': flutterExisted,
      'rustExisted': rustExisted,
      'rustPath': rustTarget.path,
    });
  }
}

class TaskStore {
  TaskStore({Directory? baseDirectory}) : _baseDirectory = baseDirectory;

  final Directory? _baseDirectory;

  Future<File> get queueFile async {
    final base = _baseDirectory ?? await getApplicationDocumentsDirectory();
    return File(p.join(base.path, 'fluxdown', 'queue.json'));
  }

  /// 在 Flutter/Rust 双文件同步前建立可恢复快照。
  Future<QueueMigrationBackup> beginMigrationBackup({
    required String rustQueuePath,
  }) async {
    await recoverPendingMigration(rustQueuePath: rustQueuePath);

    final flutterTarget = await queueFile;
    final rustTarget = File(rustQueuePath);
    final directory = Directory(
      p.join(flutterTarget.parent.path, '.queue-migration'),
    );
    await directory.create(recursive: true);

    final manifestFile = File(p.join(directory.path, 'manifest.json'));
    final flutterBackup = File(p.join(directory.path, 'flutter-queue.json'));
    final rustBackup = File(p.join(directory.path, 'rust-queue.json'));
    final flutterExisted = await flutterTarget.exists();
    final rustExisted = await rustTarget.exists();

    // 作者: long
    // 先写 preparing 状态；若进程在复制快照期间退出，下次启动不会误把半截备份当成可恢复事务。
    await _writeJsonAtomically(manifestFile, {
      'version': queueMigrationBackupVersion,
      'state': 'preparing',
      'flutterExisted': flutterExisted,
      'rustExisted': rustExisted,
    });
    if (flutterExisted) {
      await _copyAtomically(flutterTarget, flutterBackup);
    } else {
      await _deleteIfExists(flutterBackup);
    }
    if (rustExisted) {
      await _copyAtomically(rustTarget, rustBackup);
    } else {
      await _deleteIfExists(rustBackup);
    }

    final backup = QueueMigrationBackup._(
      directory: directory,
      manifestFile: manifestFile,
      flutterTarget: flutterTarget,
      rustTarget: rustTarget,
      flutterBackup: flutterBackup,
      rustBackup: rustBackup,
      flutterExisted: flutterExisted,
      rustExisted: rustExisted,
    );
    await backup._writeManifestState('prepared');
    return backup;
  }

  /// 恢复上一次未提交的迁移事务；没有 pending marker 时保持队列不变。
  Future<bool> recoverPendingMigration({required String rustQueuePath}) async {
    final flutterTarget = await queueFile;
    final directory = Directory(
      p.join(flutterTarget.parent.path, '.queue-migration'),
    );
    final manifestFile = File(p.join(directory.path, 'manifest.json'));
    if (!await manifestFile.exists()) {
      return false;
    }

    final decoded = jsonDecode(await manifestFile.readAsString());
    if (decoded is! Map) {
      throw const FormatException(
        'Queue migration manifest must be an object.',
      );
    }
    final version = _intValue(decoded['version']);
    if (version != queueMigrationBackupVersion) {
      throw FormatException(
        'Queue migration backup version $version is not supported.',
      );
    }
    final state = decoded['state']?.toString();
    if (state != 'prepared') {
      return false;
    }
    final recordedRustPath = decoded['rustPath']?.toString().trim();
    final rustTarget = File(
      recordedRustPath == null || recordedRustPath.isEmpty
          ? rustQueuePath
          : recordedRustPath,
    );
    final backup = QueueMigrationBackup._(
      directory: directory,
      manifestFile: manifestFile,
      flutterTarget: flutterTarget,
      rustTarget: rustTarget,
      flutterBackup: File(p.join(directory.path, 'flutter-queue.json')),
      rustBackup: File(p.join(directory.path, 'rust-queue.json')),
      flutterExisted: decoded['flutterExisted'] == true,
      rustExisted: decoded['rustExisted'] == true,
    );
    await backup.restore();
    return true;
  }

  Future<List<DownloadTask>> load() async => (await loadSnapshot()).tasks;

  /// 读取 Rust canonical 队列；FFI 动态库暂时不可用时，Dart 仍可直接展示并接管
  /// 已落盘任务，避免开发包缺少 native 库后把用户任务误判为空队列。
  Future<TaskQueueSnapshot?> loadRustSnapshot(String rustQueuePath) async {
    final file = File(rustQueuePath);
    if (!await file.exists()) return null;
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return const TaskQueueSnapshot(tasks: [], deletedTaskIds: {});
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Rust queue file must contain an object.');
    }
    final schemaVersion = _intValue(decoded['schema_version']);
    if (schemaVersion == null || schemaVersion <= 0) {
      throw const FormatException('Rust queue schema_version is missing.');
    }
    if (schemaVersion > rustQueueSchemaVersion) {
      throw FormatException(
        'Rust queue schema_version $schemaVersion is newer than supported version '
        '$rustQueueSchemaVersion.',
      );
    }
    final rawTasks = decoded['tasks'];
    if (rawTasks is! List) {
      throw const FormatException('Rust queue tasks must be a JSON array.');
    }
    final tasks = <DownloadTask>[];
    for (final rawTask in rawTasks) {
      if (rawTask is! Map) {
        throw const FormatException('Rust queue contains a non-object task.');
      }
      final native = FluxDownCoreTask.fromJson(
        Map<String, Object?>.from(rawTask),
      );
      final task = native.toDownloadTask();
      // 作者: long
      // 未知状态属于未来版本任务，不能降级成 queued；保留 canonical 文件，等待支持该状态的版本读取。
      if (task != null) tasks.add(task);
    }
    return TaskQueueSnapshot(
      tasks: tasks,
      deletedTaskIds: _readDeletedTaskIds(decoded['deleted_task_ids']),
    );
  }

  /// native canonical 队列启用后，Flutter 文件只保存 handedOff 等移动端专属投影。
  Future<void> saveMobileProjection(Iterable<DownloadTask> tasks) async {
    await save(
      tasks
          .where((task) => task.state == DownloadState.handedOff)
          .toList(growable: false),
    );
  }

  Future<TaskQueueSnapshot> loadSnapshot() async {
    final file = await queueFile;
    if (!await file.exists()) {
      return const TaskQueueSnapshot(tasks: [], deletedTaskIds: {});
    }

    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return const TaskQueueSnapshot(tasks: [], deletedTaskIds: {});
    }

    final decoded = jsonDecode(raw);
    late final List<Object?> items;
    late final Map<String, int> deletedTaskIds;
    switch (decoded) {
      case List<Object?> value:
        items = value;
        deletedTaskIds = <String, int>{};
      case Map<Object?, Object?> value:
        items = _readVersionedTasks(value);
        deletedTaskIds = _readDeletedTaskIds(value['deletedTaskIds']);
      default:
        throw const FormatException(
          'Queue file must contain a versioned task object or a legacy JSON array.',
        );
    }

    return TaskQueueSnapshot(
      tasks: items
          .map(
            (item) =>
                DownloadTask.fromJson(Map<String, Object?>.from(item as Map)),
          )
          .toList(),
      deletedTaskIds: deletedTaskIds,
    );
  }

  Future<void> save(
    List<DownloadTask> tasks, {
    Map<String, int> deletedTaskIds = const {},
  }) async {
    final file = await queueFile;
    const encoder = JsonEncoder.withIndent('  ');
    // 作者: long
    // 统一走带 finally 清理的原子写入；磁盘空间不足或目录权限撤销时，
    // 只让临时文件失败，不把目标 queue.json 替换成半截内容。
    await _writeBytesAtomically(
      file,
      utf8.encode(
        '${encoder.convert({'schemaVersion': mobileQueueSchemaVersion, 'tasks': tasks.map((task) => task.toJson()).toList(), 'deletedTaskIds': deletedTaskIds})}\n',
      ),
    );
  }

  List<Object?> _readVersionedTasks(Map<Object?, Object?> envelope) {
    final version = _intValue(envelope['schemaVersion']);
    if (version == null || version <= 0) {
      throw const FormatException('Queue file schemaVersion is missing.');
    }
    if (version > mobileQueueSchemaVersion) {
      throw FormatException(
        'Queue file schemaVersion $version is newer than supported version '
        '$mobileQueueSchemaVersion.',
      );
    }
    final tasks = envelope['tasks'];
    if (tasks is! List<Object?>) {
      throw const FormatException('Queue file tasks must be a JSON array.');
    }
    return tasks;
  }

  Map<String, int> _readDeletedTaskIds(Object? value) {
    if (value == null) return <String, int>{};
    if (value is! Map) {
      throw const FormatException(
        'Queue file deletedTaskIds must be an object.',
      );
    }
    final result = <String, int>{};
    for (final entry in value.entries) {
      final id = entry.key.toString().trim();
      final deletedAtMs = _intValue(entry.value);
      if (id.isEmpty || deletedAtMs == null || deletedAtMs < 0) {
        throw const FormatException(
          'Queue file contains an invalid deleted task tombstone.',
        );
      }
      result[id] = deletedAtMs;
    }
    return result;
  }

  int? _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}

Future<void> _copyAtomically(File source, File destination) async {
  final bytes = await source.readAsBytes();
  await _writeBytesAtomically(destination, bytes);
}

Future<void> _restoreFile(File source, File destination) async {
  if (!await source.exists()) {
    throw FileSystemException('Queue migration backup is missing', source.path);
  }
  await _copyAtomically(source, destination);
}

Future<void> _writeJsonAtomically(File file, Object value) async {
  await _writeBytesAtomically(
    file,
    utf8.encode('${const JsonEncoder.withIndent('  ').convert(value)}\n'),
  );
}

Future<void> _writeBytesAtomically(File file, List<int> bytes) async {
  await file.parent.create(recursive: true);
  final lockFile = File('${file.path}.lock');
  final lock = await lockFile.open(mode: FileMode.append);
  final tempFile = File(
    p.join(
      file.parent.path,
      '.${file.uri.pathSegments.last}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    ),
  );
  try {
    // 作者: long
    // 原子替换只能防止半截 JSON；持久化旁路锁还要串行化多个 Flutter/原生进程的读改写，
    // 让后续统一队列文件时不会出现两个进程同时 rename 导致的最后写入覆盖竞态。
    await lock.lock(FileLock.exclusive);
    await tempFile.writeAsBytes(bytes, flush: true);
    await tempFile.rename(file.path);
  } finally {
    await _deleteIfExists(tempFile);
    try {
      await lock.unlock();
    } finally {
      await lock.close();
    }
  }
}

Future<void> _deleteIfExists(File file) async {
  if (await file.exists()) {
    await file.delete();
  }
}
