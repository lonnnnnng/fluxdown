import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdown_mobile/src/core_bridge.dart';
import 'package:fluxdown_mobile/src/download_controller.dart';
import 'package:fluxdown_mobile/src/download_task.dart';
import 'package:fluxdown_mobile/src/ffi/fluxdown_ffi.dart';
import 'package:fluxdown_mobile/src/rust_queue_backend.dart';
import 'package:fluxdown_mobile/src/task_store.dart';

const _libraryPath = String.fromEnvironment('FLUXDOWN_FFI_TEST_LIBRARY');
const _downloadText = 'FluxDown native FFI download\n';

void main() {
  test('decodes a successful FFI envelope exactly once', () {
    final data = FluxDownCoreEnvelope.parse(
      '{"ok":true,"data":{"protocol":"https"}}',
    ).unwrap();
    expect(data, {'protocol': 'https'});
  });

  test('decodes list and null payloads', () {
    expect(FluxDownCoreEnvelope.parse('{"ok":true,"data":[]}').unwrap(), []);
    expect(
      FluxDownCoreEnvelope.parse('{"ok":true,"data":null}').unwrap(),
      isNull,
    );
  });

  test('preserves native error messages', () {
    expect(
      () => FluxDownCoreEnvelope.parse(
        '{"ok":false,"error":"missing task"}',
      ).unwrap(),
      throwsA(
        isA<FluxDownCoreException>().having(
          (error) => error.message,
          'message',
          'missing task',
        ),
      ),
    );
  });

  test('rejects malformed JSON and non-object envelopes', () {
    for (final raw in ['not json', '[]', 'null']) {
      expect(() => FluxDownCoreEnvelope.parse(raw), throwsFormatException);
    }
  });

  test('skips native tasks with unknown states instead of re-queuing them', () {
    final task = FluxDownCoreTask.fromJson({
      'id': 'future-task',
      'source': 'https://example.com/future.bin',
      'protocol': 'https',
      'state': 'awaiting-metadata-v2',
      'output_dir': '/tmp/fluxdown',
      'file_name': 'future.bin',
    });

    expect(task.toDownloadTask(), isNull);
  });

  test('maps native handed-off tasks without treating them as finished', () {
    final task = FluxDownCoreTask.fromJson({
      'id': 'ed2k-task',
      'source': 'ed2k://|file|example.iso|123|ABCDEF|/',
      'protocol': 'ed2k',
      'state': 'handed-off',
      'output_dir': '/tmp/fluxdown',
      'file_name': 'example.iso',
      'handoff_backend': 'system-handoff',
      'handed_off_at_ms': 1234,
      'finished_at_ms': null,
    }).toDownloadTask();

    expect(task, isNotNull);
    expect(task!.state, DownloadState.handedOff);
    expect(task.handoffBackend, 'system-handoff');
    expect(
      task.handedOffAt,
      DateTime.fromMillisecondsSinceEpoch(1234, isUtc: true),
    );
    expect(task.finishedAt, isNull);
  });

  test(
    'maps native credential references without exposing credential contents',
    () {
      final task = FluxDownCoreTask.fromJson({
        'id': 'credential-task',
        'source': 'https://example.com/private.bin',
        'protocol': 'https',
        'state': 'queued',
        'output_dir': '/tmp/fluxdown',
        'file_name': 'private.bin',
        'credential_ref': 'office-http',
      }).toDownloadTask();

      expect(task, isNotNull);
      expect(task!.credentialRef, 'office-http');
      expect(task.toJson(), isNot(contains('password')));
    },
  );

  // 作者: long
  // 原生测试必须显式提供本次构建的库，避免仅测试 JSON 类或静默回退 Dart 也被算作 FFI 通过。
  group(
    'native Rust binding',
    () {
      late FluxDownCoreFfi core;
      late Directory directory;
      late String storePath;

      setUpAll(() {
        core = FluxDownCoreFfi.open(libraryPath: _libraryPath);
      });
      setUp(() async {
        directory = await Directory.systemTemp.createTemp('fluxdown-ffi-test-');
        storePath = '${directory.path}/queue.json';
      });
      tearDown(() async {
        await directory.delete(recursive: true);
      });

      test(
        'loads ABI, version, protocol and support through the native library',
        () {
          expect(core.abi(), 1);
          expect(core.version(), matches(RegExp(r'^\d+\.\d+\.\d+')));
          final sources = {
            'https://example.com/file.zip': 'https',
            'http://example.com/file.zip': 'http',
            'https://example.com/video.m3u8?token=test': 'm3u8',
            'https://example.com/data.torrent': 'torrent',
            'magnet:?xt=urn:btih:0123456789012345678901234567890123456789':
                'magnet',
            'ed2k://|file|test.txt|1|01234567890123456789012345678901|/':
                'ed2k',
            'webdav://example.com/a': 'webdav',
            'webdavs://example.com/a': 'webdavs',
            'ftp://example.com/a': 'ftp',
            'ftps://example.com/a': 'ftps',
            'sftp://example.com/a': 'sftp',
            'smb://example.com/share/a': 'smb',
          };
          for (final entry in sources.entries) {
            expect(core.detect(entry.key)['protocol'], entry.value);
            expect(
              FluxDownCoreBridge.detectProtocol(entry.key, core: core),
              entry.value,
            );
          }
          expect(core.support('https://example.com/a')['executable'], isTrue);
        },
      );

      test(
        'reads Torrent metadata and file selection data through Rust FFI',
        () async {
          final torrentFile = File('${directory.path}/metadata.torrent');
          await torrentFile.writeAsString(
            [
              'd4:info',
              'd5:files',
              'l',
              'd6:lengthi3e4:pathl4:a.ts',
              'ee', // 作者: long：关闭文件路径列表和文件字典。
              'e', // 作者: long：关闭多文件列表。
              '4:name4:demo',
              'ee', // 作者: long：关闭 info 字典和种子顶层字典。
            ].join(),
          );
          final details = await FluxDownCoreBridge.inspectTorrentMetadata(
            torrentFile.path,
            core: core,
            timeout: const Duration(seconds: 5),
          );

          expect(details?['name'], 'demo');
          final files = (details?['files'] as List).cast<Map>();
          expect(files, hasLength(1));
          expect(files.single['index'], 0);
          expect(files.single['path'], 'a.ts');
          expect(files.single['size'], 3);
        },
      );

      test('adds and lists a task with unicode and native field names', () {
        final task = core.queueAdd(storePath, {
          'source': 'https://example.com/test.zip',
          'outputDir': directory.path,
          'fileName': '资料.zip',
        });
        expect(task.fileName, '资料.zip');
        expect(task.state, 'queued');
        final tasks = core.queueList(storePath);
        expect(tasks.single.id, task.id);
        expect(tasks.single.outputDir, directory.path);
      });

      test(
        'routes selected Torrent and Magnet tasks through the Rust queue',
        () {
          final backend = RustQueueBackend(core: core, storePath: storePath);
          final httpTask = DownloadTask.create(
            source: 'https://example.com/file.zip',
            outputFolder: directory.path,
          );
          final hlsTask = DownloadTask.create(
            source: 'https://example.com/playlist.m3u8',
            outputFolder: directory.path,
            hlsKeepTransportStream: true,
          );
          final credentialTask = DownloadTask.create(
            source: 'https://example.com/private.zip',
            outputFolder: directory.path,
            credentialRef: 'office-http',
          );
          final torrentTask = DownloadTask.create(
            source:
                'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
            outputFolder: directory.path,
          );
          final selectedTorrentTask = DownloadTask.create(
            source: 'https://example.com/bundle.torrent',
            outputFolder: directory.path,
            torrentName: 'bundle',
            torrentFiles: const [
              TorrentFileEntry(
                index: 0,
                path: 'bundle/file.bin',
                name: 'file.bin',
                size: 42,
                isStreamable: false,
              ),
            ],
            selectedTorrentFileIndexes: const [0],
          );
          expect(backend.supportsTask(httpTask), isTrue);
          expect(backend.supportsTask(hlsTask), isTrue);
          expect(backend.supportsTask(credentialTask), isTrue);
          expect(backend.supportsTask(torrentTask), isFalse);
          expect(backend.supportsTask(selectedTorrentTask), isTrue);
          backend.ensureTasks([torrentTask, selectedTorrentTask]);
          expect(backend.list().map((task) => task.id), [
            selectedTorrentTask.id,
          ]);
        },
      );

      test(
        'round trips the complete Flutter task schema through Rust import',
        () async {
          final createdAt = DateTime.utc(2026, 9, 27, 1, 2, 3);
          final startedAt = createdAt.add(const Duration(minutes: 1));
          final task =
              DownloadTask.create(
                source: 'https://example.com/bundle.bin',
                outputFolder: directory.path,
                fileName: 'bundle.mp4',
                torrentName: 'bundle',
                torrentFiles: const [
                  TorrentFileEntry(
                    index: 0,
                    path: 'bundle/video.mp4',
                    name: 'video.mp4',
                    size: 2048,
                    isStreamable: true,
                  ),
                ],
                selectedTorrentFileIndexes: const [0],
                expectedSha256:
                    '671e23b189bb7a2041eff1b29f077b4e59460d30db56248fdcccafa012babfc8',
                credentialRef: 'office-http',
                speedLimitMbps: 1.5,
                hlsVariantIndex: 2,
                hlsKeepTransportStream: true,
              ).copyWith(
                state: DownloadState.paused,
                downloadedBytes: 512,
                totalBytes: 2048,
                currentSpeedBytesPerSecond: 128,
                createdAt: createdAt,
                updatedAt: startedAt,
                startedAt: startedAt,
                pausedAt: startedAt,
              );
          final backend = RustQueueBackend(core: core, storePath: storePath);
          backend.ensureTasks([task]);

          final native = backend.list().single;
          expect(native.id, task.id);
          expect(native.state, 'paused');
          expect(native.fileName, 'bundle.mp4');
          expect(native.torrentName, 'bundle');
          expect(native.torrentFiles.single.name, 'video.mp4');
          expect(native.selectedTorrentFileIndexes, [0]);
          expect(native.credentialRef, 'office-http');
          expect(native.speedLimitMbps, 1.5);
          expect(native.hlsVariantIndex, 2);
          expect(native.hlsKeepTransportStream, isTrue);
          expect(native.downloadedBytes, 512);
          expect(native.totalBytes, 2048);
          expect(native.createdAt, createdAt);
          expect(native.startedAt, startedAt);
        },
      );

      test('propagates a failed native queue operation', () {
        expect(
          () => core.queueRun(storePath, 'missing-task'),
          throwsA(isA<FluxDownCoreException>()),
        );
      });

      test('uses non-blocking run status and pause/resume controls', () async {
        final handle = core.queueRunAsync(storePath, 'missing-task');
        final runId = handle['runId'] as String;
        Map<String, Object?>? terminal;
        for (var attempt = 0; attempt < 50; attempt += 1) {
          final status = core.queueRunStatus(runId);
          if (status['state'] == 'failed') {
            terminal = status;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(terminal?['state'], 'failed');
        core.queueRunForget(runId);

        final task = core.queueAdd(storePath, {
          'source': 'https://example.com/file.bin',
          'outputDir': directory.path,
        });
        expect(core.queuePause(storePath, task.id).state, 'paused');
        expect(core.queueResume(storePath, task.id).state, 'queued');
      });

      test('passes queue settings through the async native runner', () async {
        final handle = core.queueRunQueuedAsync(storePath, {
          'concurrency': 2,
          'threadCount': 4,
          'retryAttempts': 1,
          'speedLimitKbps': 0,
        });
        final runId = handle['runId'] as String;
        Map<String, Object?>? terminal;
        for (var attempt = 0; attempt < 50; attempt += 1) {
          final status = core.queueRunStatus(runId);
          if (status['state'] == 'finished') {
            terminal = status;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(terminal?['state'], 'finished');
        expect((terminal?['report'] as Map?)?['total_queued'], 0);
        core.queueRunForget(runId);
      });

      test(
        'runs an actual HTTP task and verifies the downloaded file',
        () async {
          final ready = ReceivePort();
          final server = await Isolate.spawn(_serveDownload, ready.sendPort);
          try {
            final port = await ready.first as int;
            final task = core.queueAdd(storePath, {
              'source': 'http://127.0.0.1:$port/ffi-download.txt',
              'outputDir': directory.path,
            });
            final report = core.queueRun(storePath, task.id);
            expect((report['task'] as Map)['state'], 'finished');
            final completed = core.queueList(storePath).single;
            expect(completed.state, 'finished');
            expect(
              completed.downloadedBytes,
              utf8.encode(_downloadText).length,
            );
            expect(
              await File(
                '${directory.path}/${completed.fileName}',
              ).readAsString(),
              _downloadText,
            );
          } finally {
            ready.close();
            server.kill(priority: Isolate.immediate);
          }
        },
      );

      test(
        'maps a Flutter task into the isolated Rust queue backend',
        () async {
          final ready = ReceivePort();
          final server = await Isolate.spawn(_serveDownload, ready.sendPort);
          try {
            final port = await ready.first as int;
            final task = DownloadTask.create(
              source: 'http://127.0.0.1:$port/ffi-download.txt',
              outputFolder: directory.path,
            );
            final backend = RustQueueBackend(core: core, storePath: storePath);
            final nativeTask = backend.enqueue(task);
            expect(nativeTask.id, task.id);

            final result = await backend.runQueued(
              concurrency: 2,
              threadCount: 4,
              retryAttempts: 1,
            );
            expect(result.finished, isTrue);
            expect(backend.list().single.state, 'finished');
            expect(
              await File('${directory.path}/${task.fileName}').readAsString(),
              _downloadText,
            );
          } finally {
            ready.close();
            server.kill(priority: Isolate.immediate);
          }
        },
      );

      test('controller executes an HTTP task through the Rust queue', () async {
        final ready = ReceivePort();
        final server = await Isolate.spawn(_serveDownload, ready.sendPort);
        try {
          final port = await ready.first as int;
          final controller = DownloadController(
            store: TaskStore(baseDirectory: directory),
            rustBackend: RustQueueBackend(core: core, storePath: storePath),
          );
          await controller.load();
          final task = await controller.add(
            source: 'http://127.0.0.1:$port/ffi-download.txt',
            outputFolder: directory.path,
          );
          final report = await controller.runQueued(
            concurrency: 1,
            maxRetries: 1,
            threadCount: 2,
          );
          expect(report.finished, 1);
          expect(controller.tasks.single.id, task.id);
          expect(controller.tasks.single.state, DownloadState.finished);
          expect(controller.tasks.single.startedAt, isNotNull);
          expect(controller.tasks.single.finishedAt, isNotNull);

          // 作者: long
          // 模拟 App 在 Rust 完成后、Flutter 状态落库前退出；下一轮队列运行应从
          // native 终态修复旧 queued 记录，而不是再次下载同一文件。
          final flutterStore = TaskStore(baseDirectory: directory);
          await flutterStore.save([task]);
          final restored = DownloadController(
            store: flutterStore,
            rustBackend: RustQueueBackend(core: core, storePath: storePath),
          );
          await restored.load();
          expect(restored.tasks.single.state, DownloadState.finished);
          expect(restored.tasks.single.startedAt, isNotNull);
          expect(restored.tasks.single.finishedAt, isNotNull);
          final recoveredReport = await restored.runQueued();
          expect(recoveredReport.totalQueued, 0);
          expect(restored.tasks.single.state, DownloadState.finished);
          expect(restored.tasks.single.startedAt, isNotNull);
          expect(restored.tasks.single.finishedAt, isNotNull);
          expect((await flutterStore.load()), isEmpty);
          final canonical = await flutterStore.loadRustSnapshot(storePath);
          expect(canonical!.tasks.single.state, DownloadState.finished);
        } finally {
          ready.close();
          server.kill(priority: Isolate.immediate);
        }
      });

      test(
        'imports a native orphan task into the mobile task projection on startup',
        () async {
          final native = core.queueAdd(storePath, {
            'taskId': 'orphan-native-task',
            'source': 'https://example.com/orphan.zip',
            'outputDir': directory.path,
            'fileName': '真实文件.zip',
            'torrentName': 'metadata-root',
            'torrentFiles': [
              {
                'index': 0,
                'path': 'metadata-root/真实文件.zip',
                'name': '真实文件.zip',
                'size': 4096,
                'isStreamable': false,
              },
            ],
          });
          expect(native.state, 'queued');

          final flutterStore = TaskStore(baseDirectory: directory);
          final controller = DownloadController(
            store: flutterStore,
            rustBackend: RustQueueBackend(core: core, storePath: storePath),
          );
          await controller.load();

          expect(controller.tasks, hasLength(1));
          final imported = controller.tasks.single;
          expect(imported.id, 'orphan-native-task');
          expect(imported.fileName, '真实文件.zip');
          expect(imported.torrentName, 'metadata-root');
          expect(imported.torrentFiles.single.path, 'metadata-root/真实文件.zip');
          expect(imported.state, DownloadState.queued);
          expect(await flutterStore.load(), isEmpty);
          expect(
            (await flutterStore.loadRustSnapshot(storePath))!.tasks.single.id,
            'orphan-native-task',
          );
        },
      );

      test(
        'load does not regress a completed Flutter task to native queued',
        () async {
          final backend = RustQueueBackend(core: core, storePath: storePath);
          final task = DownloadTask.create(
            source: 'http://127.0.0.1:1/stale.bin',
            outputFolder: directory.path,
          );
          backend.enqueue(task);
          final flutterStore = TaskStore(baseDirectory: directory);
          await flutterStore.save([
            task.copyWith(
              state: DownloadState.finished,
              finishedAt: DateTime.now().toUtc(),
            ),
          ]);

          final controller = DownloadController(
            store: flutterStore,
            rustBackend: backend,
          );
          await controller.load();
          expect(controller.tasks.single.state, DownloadState.finished);
          expect((await flutterStore.load()), isEmpty);
        },
      );

      test(
        'load adopts a newer native progress snapshot over stale Flutter data',
        () async {
          final backend = RustQueueBackend(core: core, storePath: storePath);
          final task = DownloadTask.create(
            source: 'http://127.0.0.1:1/newer-native.bin',
            outputFolder: directory.path,
          );
          backend.enqueue(task);
          final newer = task.toJson()
            ..['state'] = 'paused'
            ..['downloadedBytes'] = 64
            ..['totalBytes'] = 128
            ..['currentSpeedBytesPerSecond'] = 0
            ..['updatedAt'] = DateTime.now()
                .toUtc()
                .add(const Duration(seconds: 5))
                .toIso8601String();
          final updatedAt = DateTime.parse(
            newer['updatedAt'] as String,
          ).millisecondsSinceEpoch;
          core.queueUpsert(storePath, {
            'taskId': task.id,
            'source': task.source,
            'outputDir': task.outputFolder,
            'fileName': task.fileName,
            'state': 'paused',
            'downloadedBytes': 64,
            'totalBytes': 128,
            'updatedAtMs': updatedAt,
          });

          final flutterStore = TaskStore(baseDirectory: directory);
          await flutterStore.save([task]);
          final controller = DownloadController(
            store: flutterStore,
            rustBackend: backend,
          );
          await controller.load();

          expect(controller.tasks.single.state, DownloadState.paused);
          expect(controller.tasks.single.downloadedBytes, 64);
          expect(controller.tasks.single.totalBytes, 128);
        },
      );

      test(
        'controller pause, resume, reset and remove stay in sync with Rust queue',
        () async {
          final ready = ReceivePort();
          final server = await Isolate.spawn(_serveDownload, ready.sendPort);
          try {
            final port = await ready.first as int;
            final controller = DownloadController(
              store: TaskStore(baseDirectory: directory),
              rustBackend: RustQueueBackend(core: core, storePath: storePath),
            );
            await controller.load();
            final task = await controller.add(
              source: 'http://127.0.0.1:$port/ffi-download.txt',
              outputFolder: directory.path,
            );
            final backend = RustQueueBackend(core: core, storePath: storePath);

            await controller.pause(task.id);
            expect(controller.tasks.single.state, DownloadState.paused);
            expect(backend.list().single.state, 'paused');

            await controller.start(task.id, maxRetries: 0);
            expect(controller.tasks.single.state, DownloadState.finished);
            expect(controller.tasks.single.finishedAt, isNotNull);

            await controller.resetForRedownload(task.id);
            expect(controller.tasks.single.state, DownloadState.queued);
            expect(backend.list().single.state, 'queued');
            expect(backend.list().single.downloadedBytes, 0);

            await controller.remove(task.id);
            expect(controller.tasks, isEmpty);
            expect(backend.list(), isEmpty);
          } finally {
            ready.close();
            server.kill(priority: Isolate.immediate);
          }
        },
      );

      test(
        'deleted task tombstone prevents a stale native orphan from returning',
        () async {
          final backend = RustQueueBackend(core: core, storePath: storePath);
          final store = TaskStore(baseDirectory: directory);
          final controller = DownloadController(
            store: store,
            rustBackend: backend,
          );
          await controller.load();
          final task = await controller.add(
            source: 'https://example.com/deleted.bin',
            outputFolder: directory.path,
          );

          await controller.remove(task.id);
          final canonicalAfterRemove = await store.loadRustSnapshot(
            backend.storePath,
          );
          expect(canonicalAfterRemove!.deletedTaskIds, contains(task.id));

          // 模拟 native 运行句柄在删除后迟到写回旧快照；时间戳早于 tombstone 时不能复活任务。
          core.queueUpsert(storePath, {
            'taskId': task.id,
            'source': task.source,
            'outputDir': task.outputFolder,
            'fileName': task.fileName,
            'state': 'queued',
            'updatedAtMs': task.updatedAt.millisecondsSinceEpoch,
          });
          final restoredBackend = RustQueueBackend(
            core: core,
            storePath: storePath,
          );
          final restored = DownloadController(
            store: store,
            rustBackend: restoredBackend,
          );
          await restored.load();

          expect(restored.tasks, isEmpty);
          expect(restoredBackend.list(), isEmpty);
        },
      );

      test('shows a failed Rust queue handle on the Flutter task', () async {
        final controller = DownloadController(
          store: TaskStore(baseDirectory: directory),
          rustBackend: _FailedRustQueueBackend(core, storePath),
        );
        await controller.load();
        final task = await controller.add(
          source: 'http://127.0.0.1:1/unreachable.bin',
          outputFolder: directory.path,
        );

        final report = await controller.runQueued();
        expect(report.finished, 0);
        expect(report.failed, 1);
        expect(controller.tasks.single.id, task.id);
        expect(controller.tasks.single.state, DownloadState.failed);
        expect(controller.tasks.single.error, 'native store unavailable');
        expect(controller.tasks.single.finishedAt, isNotNull);
      });

      test(
        'records an exception from Rust queue execution instead of falling back',
        () async {
          final controller = DownloadController(
            store: TaskStore(baseDirectory: directory),
            rustBackend: _ThrowingRustQueueBackend(core, storePath),
          );
          await controller.load();
          final task = await controller.add(
            source: 'http://127.0.0.1:1/unreachable.bin',
            outputFolder: directory.path,
          );

          final report = await controller.runQueued();
          expect(report.finished, 0);
          expect(report.failed, 1);
          expect(controller.tasks.single.id, task.id);
          expect(controller.tasks.single.state, DownloadState.failed);
          expect(
            controller.tasks.single.error,
            contains('queue handle unavailable'),
          );
        },
      );
    },
    skip: _libraryPath.isEmpty
        ? 'Pass FLUXDOWN_FFI_TEST_LIBRARY for native tests'
        : false,
  );
}

class _FailedRustQueueBackend extends RustQueueBackend {
  _FailedRustQueueBackend(FluxDownCoreFfi core, String storePath)
    : super(core: core, storePath: storePath);

  @override
  void ensureTasks(Iterable<DownloadTask> tasks) {}

  @override
  Future<RustQueueRunResult> runQueued({
    int concurrency = 5,
    int threadCount = 16,
    int retryAttempts = 3,
    int speedLimitKbps = 0,
    Map<String, Map<String, String>> runtimeCredentials = const {},
    Duration pollInterval = const Duration(milliseconds: 200),
    FutureOr<void> Function(List<FluxDownCoreTask> tasks)? onProgress,
  }) async => const RustQueueRunResult(
    state: 'failed',
    error: 'native store unavailable',
  );
}

class _ThrowingRustQueueBackend extends RustQueueBackend {
  _ThrowingRustQueueBackend(FluxDownCoreFfi core, String storePath)
    : super(core: core, storePath: storePath);

  @override
  void ensureTasks(Iterable<DownloadTask> tasks) {}

  @override
  Future<RustQueueRunResult> runQueued({
    int concurrency = 5,
    int threadCount = 16,
    int retryAttempts = 3,
    int speedLimitKbps = 0,
    Map<String, Map<String, String>> runtimeCredentials = const {},
    Duration pollInterval = const Duration(milliseconds: 200),
    FutureOr<void> Function(List<FluxDownCoreTask> tasks)? onProgress,
  }) async {
    throw StateError('queue handle unavailable');
  }
}

Future<void> _serveDownload(SendPort ready) async {
  // 作者: long
  // queueRun 是阻塞 C ABI，HTTP 服务放在独立 isolate，防止测试主 isolate 阻塞导致下载死锁。
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  ready.send(server.port);
  await for (final request in server) {
    final body = utf8.encode(_downloadText);
    request.response.contentLength = body.length;
    if (request.method != 'HEAD') request.response.add(body);
    await request.response.close();
  }
}
