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

      test(
        'controller can opt into Rust queue execution without changing Dart default',
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
            expect(restored.tasks.single.state, DownloadState.queued);
            final recoveredReport = await restored.runQueued();
            expect(recoveredReport.totalQueued, 0);
            expect(restored.tasks.single.state, DownloadState.finished);
            expect(restored.tasks.single.startedAt, isNotNull);
            expect(restored.tasks.single.finishedAt, isNotNull);
            expect(
              (await flutterStore.load()).single.state,
              DownloadState.finished,
            );
          } finally {
            ready.close();
            server.kill(priority: Isolate.immediate);
          }
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
            backend.enqueue(task);

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
    },
    skip: _libraryPath.isEmpty
        ? 'Pass FLUXDOWN_FFI_TEST_LIBRARY for native tests'
        : false,
  );
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
