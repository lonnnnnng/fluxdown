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
    final subscription = server.listen((request) async {
      request.response.headers.contentType = ContentType.binary;
      request.response.contentLength = payload.length;
      if (request.method != 'HEAD') request.response.add(payload);
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
      final directCompleted = controller.tasks.first;
      expect(directCompleted.state, DownloadState.finished);
      expect(directCompleted.startedAt, isNotNull);
      expect(directCompleted.finishedAt, isNotNull);
      expect(
        await File(
          p.join(outputDir.path, directCompleted.fileName),
        ).readAsBytes(),
        payload,
      );

      // ignore: avoid_print
      print(
        'FLUXDOWN_RUST_E2E_RESULT ${jsonEncode({'ffiVersion': core.version(), 'queuedTaskId': queued.id, 'directTaskId': direct.id, 'outputBytes': payload.length, 'queuedState': completed.state.name, 'directState': directCompleted.state.name})}',
      );
    } finally {
      await subscription.cancel();
      await server.close(force: true);
      await baseDir.delete(recursive: true);
    }
  }, timeout: Timeout.none);
}
