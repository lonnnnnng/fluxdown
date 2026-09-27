import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdown_mobile/src/download_controller.dart';
import 'package:fluxdown_mobile/src/download_task.dart';
import 'package:fluxdown_mobile/src/ffi/fluxdown_ffi.dart';
import 'package:fluxdown_mobile/src/rust_queue_backend.dart';
import 'package:fluxdown_mobile/src/task_store.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Rust queue downloads a real local HTTP file on device', (
    tester,
  ) async {
    final baseDir = await (await getTemporaryDirectory()).createTemp(
      'fluxdown-rust-e2e-',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final payload = List<int>.generate(128 * 1024, (index) => index % 251);
    final hlsPayload = <int>[31, 139, 17, 5, 99, 42];
    final hlsFmp4Init = <int>[
      0,
      0,
      0,
      24,
      0x66,
      0x74,
      0x79,
      0x70,
      ...utf8.encode('isom'),
      0,
      0,
      0,
      0,
      ...utf8.encode('isomiso6'),
    ];
    final hlsFmp4First = <int>[41, 42, 43, 44];
    final hlsFmp4Second = <int>[45, 46, 47];
    final subscription = server.listen((request) async {
      switch (request.uri.path) {
        case '/playlist.m3u8':
          request.response
            ..headers.contentType = ContentType(
              'application',
              'vnd.apple.mpegurl',
            )
            ..write('#EXTM3U\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n');
        case '/master.m3u8':
          request.response
            ..headers.contentType = ContentType(
              'application',
              'vnd.apple.mpegurl',
            )
            ..write('''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=64000,RESOLUTION=640x360
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=256000,RESOLUTION=1280x720
high.m3u8
''');
        case '/low.m3u8':
          request.response
            ..headers.contentType = ContentType(
              'application',
              'vnd.apple.mpegurl',
            )
            ..write('#EXTM3U\n#EXTINF:1,\nlow.ts\n#EXT-X-ENDLIST\n');
        case '/high.m3u8':
          request.response
            ..headers.contentType = ContentType(
              'application',
              'vnd.apple.mpegurl',
            )
            ..write('''
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-MAP:URI="init.mp4"
#EXTINF:1,
high-1.m4s
#EXTINF:1,
high-2.m4s
#EXT-X-ENDLIST
''');
        case '/init.mp4':
          request.response.add(hlsFmp4Init);
        case '/high-1.m4s':
          request.response.add(hlsFmp4First);
        case '/high-2.m4s':
          request.response.add(hlsFmp4Second);
        default:
          final responseBody = request.uri.path == '/segment.ts'
              ? hlsPayload
              : payload;
          request.response.headers.contentType = ContentType.binary;
          request.response.contentLength = responseBody.length;
          if (request.method != 'HEAD') {
            request.response.add(responseBody);
          }
      }
      await request.response.close();
    });

    try {
      final core = FluxDownCoreFfi.open();
      expect(core.abi(), 1);
      final outputDir = Directory(p.join(baseDir.path, 'downloads'));
      await outputDir.create(recursive: true);
      final backend = RustQueueBackend(
        core: core,
        storePath: p.join(baseDir.path, 'rust-queue.json'),
      );
      final controller = DownloadController(
        store: TaskStore(baseDirectory: baseDir),
        rustBackend: backend,
      );
      await controller.load();

      // 作者: long
      // 真机上验证旧双队列一次性收敛的关键边界：Rust 的较新进度必须覆盖 Flutter 旧快照，
      // 收敛成功后留下 committed marker，且普通任务不再写回 Flutter 投影。
      final migrationDir = Directory(p.join(baseDir.path, 'migration'));
      final migrationOutput = Directory(p.join(migrationDir.path, 'downloads'));
      await migrationOutput.create(recursive: true);
      final migrationStore = TaskStore(baseDirectory: migrationDir);
      final migrationRustPath = p.join(
        migrationDir.path,
        'fluxdown',
        'rust-queue.json',
      );
      final migrationBackend = RustQueueBackend(
        core: core,
        storePath: migrationRustPath,
      );
      final migrationTask = DownloadTask.create(
        source: 'http://127.0.0.1:${server.port}/migration.bin',
        outputFolder: migrationOutput.path,
      );
      final staleFlutterTask = migrationTask.copyWith(
        updatedAt: DateTime.now().toUtc().subtract(const Duration(seconds: 5)),
      );
      await migrationStore.save([staleFlutterTask]);
      final nativeUpdatedAt = DateTime.now().toUtc().add(
        const Duration(seconds: 5),
      );
      core.queueUpsert(migrationRustPath, {
        'taskId': migrationTask.id,
        'source': migrationTask.source,
        'outputDir': migrationTask.outputFolder,
        'fileName': migrationTask.fileName,
        'state': 'paused',
        'downloadedBytes': 42,
        'totalBytes': 128,
        'updatedAtMs': nativeUpdatedAt.millisecondsSinceEpoch,
      });
      final restoredController = DownloadController(
        store: migrationStore,
        rustBackend: migrationBackend,
      );
      await restoredController.load();
      expect(restoredController.tasks.single.state, DownloadState.paused);
      expect(restoredController.tasks.single.downloadedBytes, 42);
      final migrationManifest = File(
        p.join(
          migrationDir.path,
          'fluxdown',
          '.queue-migration',
          'manifest.json',
        ),
      );
      expect(
        jsonDecode(await migrationManifest.readAsString())['state'],
        'committed',
      );

      // 作者: long
      // 用设备内 HTTP 服务验证真实 native 网络请求、文件落盘与 Flutter 状态回写，
      // 不依赖开发机端口映射或公网资源，Android 真机和 iOS simulator 可复用同一用例。
      final queued = await controller.add(
        source: 'http://127.0.0.1:${server.port}/queued.bin',
        outputFolder: outputDir.path,
      );
      final report = await controller
          .runQueued(concurrency: 1, threadCount: 1, maxRetries: 0)
          .timeout(const Duration(seconds: 40));
      final nativeTasks = backend.list();
      expect(
        report.finished,
        1,
        reason: jsonEncode({
          'report': {
            'queued': report.totalQueued,
            'started': report.started,
            'finished': report.finished,
            'failed': report.failed,
          },
          'tasks': nativeTasks
              .map(
                (task) => {
                  'state': task.state,
                  'error': task.error,
                  'outputDir': task.outputDir,
                  'fileName': task.fileName,
                  'downloadedBytes': task.downloadedBytes,
                },
              )
              .toList(),
        }),
      );
      final completed = controller.tasks.single;
      expect(completed.id, queued.id);
      expect(completed.state, DownloadState.finished);
      expect(completed.startedAt, isNotNull);
      expect(completed.finishedAt, isNotNull);
      expect(completed.downloadedBytes, payload.length);
      expect(
        await File(p.join(outputDir.path, completed.fileName)).readAsBytes(),
        payload,
      );

      final direct = await controller.add(
        source: 'http://127.0.0.1:${server.port}/direct.bin',
        outputFolder: outputDir.path,
      );
      await controller.pause(direct.id);
      expect(controller.tasks.first.state, DownloadState.paused);
      await controller
          .start(direct.id, threadCount: 1, maxRetries: 0)
          .timeout(const Duration(seconds: 40));
      final directCompleted = controller.tasks.firstWhere(
        (task) => task.id == direct.id,
      );
      expect(directCompleted.state, DownloadState.finished);
      expect(directCompleted.startedAt, isNotNull);
      expect(directCompleted.finishedAt, isNotNull);
      expect(
        await File(
          p.join(outputDir.path, directCompleted.fileName),
        ).readAsBytes(),
        payload,
      );

      final hls = await controller.add(
        source: 'http://127.0.0.1:${server.port}/playlist.m3u8',
        outputFolder: outputDir.path,
        hlsKeepTransportStream: true,
      );
      final hlsReport = await controller
          .runQueued(concurrency: 1, threadCount: 1, maxRetries: 0)
          .timeout(const Duration(seconds: 40));
      expect(hlsReport.finished, 1);
      final hlsCompleted = controller.tasks.firstWhere(
        (task) => task.id == hls.id,
      );
      expect(hlsCompleted.id, hls.id);
      expect(hlsCompleted.state, DownloadState.finished);
      expect(hlsCompleted.fileName, 'playlist.ts');
      expect(
        await File(p.join(outputDir.path, hlsCompleted.fileName)).readAsBytes(),
        hlsPayload,
      );

      final hlsVariant = await controller.add(
        source: 'http://127.0.0.1:${server.port}/master.m3u8',
        outputFolder: outputDir.path,
        hlsVariantIndex: 1,
      );
      final hlsVariantReport = await controller
          .runQueued(concurrency: 1, threadCount: 2, maxRetries: 0)
          .timeout(const Duration(seconds: 40));
      expect(
        hlsVariantReport.finished,
        1,
        reason: jsonEncode({
          'report': {
            'totalQueued': hlsVariantReport.totalQueued,
            'started': hlsVariantReport.started,
            'finished': hlsVariantReport.finished,
            'failed': hlsVariantReport.failed,
          },
          'tasks': controller.tasks
              .map(
                (task) => {
                  'id': task.id,
                  'state': task.state.name,
                  'fileName': task.fileName,
                  'error': task.error,
                  'downloadedBytes': task.downloadedBytes,
                  'totalBytes': task.totalBytes,
                  'hlsVariantIndex': task.hlsVariantIndex,
                },
              )
              .toList(),
        }),
      );
      final hlsVariantCompleted = controller.tasks.firstWhere(
        (task) => task.id == hlsVariant.id,
      );
      expect(hlsVariantCompleted.id, hlsVariant.id);
      expect(hlsVariantCompleted.state, DownloadState.finished);
      expect(hlsVariantCompleted.fileName, 'master.mp4');
      final hlsVariantBytes = await File(
        p.join(outputDir.path, hlsVariantCompleted.fileName),
      ).readAsBytes();
      expect(hlsVariantBytes, [
        ...hlsFmp4Init,
        ...hlsFmp4First,
        ...hlsFmp4Second,
      ]);
      expect(String.fromCharCodes(hlsVariantBytes.sublist(4, 8)), 'ftyp');

      // 作者: long
      // 真机上验证删除 tombstone 与 Flutter 投影边界：普通 Rust 任务删除后不能被迟到
      // 的旧 upsert 复活，canonical 启用后 Flutter queue.json 只保留移动端专属投影。
      final removed = await controller.add(
        source: 'http://127.0.0.1:${server.port}/removed.bin',
        outputFolder: outputDir.path,
      );
      await controller.remove(removed.id);
      final rustQueueFile = File(backend.storePath);
      final rustQueue = jsonDecode(await rustQueueFile.readAsString()) as Map;
      expect(
        (rustQueue['tasks'] as List).whereType<Map>().any(
          (task) => task['id'] == removed.id,
        ),
        isFalse,
      );
      expect((rustQueue['deleted_task_ids'] as Map)[removed.id], isNotNull);
      core.queueUpsert(backend.storePath, {
        'taskId': removed.id,
        'source': removed.source,
        'outputDir': removed.outputFolder,
        'fileName': removed.fileName,
        'state': 'queued',
        'createdAtMs': removed.createdAt.millisecondsSinceEpoch,
        'updatedAtMs': removed.createdAt.millisecondsSinceEpoch,
      });
      expect(backend.list().any((task) => task.id == removed.id), isFalse);

      final flutterProjection = File(
        p.join(baseDir.path, 'fluxdown', 'queue.json'),
      );
      final projection =
          jsonDecode(await flutterProjection.readAsString()) as Map;
      expect(projection['tasks'], isEmpty);

      // ignore: avoid_print
      print(
        'FLUXDOWN_RUST_E2E_RESULT ${jsonEncode({'ffiVersion': core.version(), 'queuedTaskId': queued.id, 'directTaskId': direct.id, 'hlsTaskId': hls.id, 'hlsVariantTaskId': hlsVariant.id, 'outputBytes': payload.length, 'hlsBytes': hlsPayload.length, 'hlsVariantBytes': hlsVariantBytes.length, 'queuedState': completed.state.name, 'directState': directCompleted.state.name, 'hlsState': hlsCompleted.state.name, 'hlsVariantState': hlsVariantCompleted.state.name})}',
      );
    } finally {
      await subscription.cancel();
      await server.close(force: true);
      await baseDir.delete(recursive: true);
    }
  }, timeout: Timeout.none);
}
