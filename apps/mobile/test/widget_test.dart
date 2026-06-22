import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdown_mobile/src/download_controller.dart';
import 'package:fluxdown_mobile/src/download_task.dart';
import 'package:fluxdown_mobile/src/mobile_downloader.dart';
import 'package:fluxdown_mobile/src/mobile_ftp.dart';
import 'package:fluxdown_mobile/src/mobile_sftp.dart';
import 'package:fluxdown_mobile/src/mobile_smb.dart';
import 'package:fluxdown_mobile/src/mobile_torrent.dart';
import 'package:fluxdown_mobile/src/protocol.dart';
import 'package:fluxdown_mobile/src/task_store.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart';

const _mediaChannel = MethodChannel('dev.fluxdown.mobile/media');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_mediaChannel, (call) async {
          if (call.method != 'remuxTsToMp4') {
            return null;
          }
          final arguments = Map<String, Object?>.from(call.arguments as Map);
          final sourcePath = arguments['sourcePath'] as String;
          final outputPath = arguments['outputPath'] as String;
          final outputFile = await File(sourcePath).copy(outputPath);
          return {'outputBytes': await outputFile.length()};
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_mediaChannel, null);
  });

  test('detects common protocols', () {
    expect(detectProtocol('https://example.com/file.bin'), 'https');
    expect(detectProtocol('http://example.com/file.bin'), 'http');
    expect(
      detectProtocol('webdav://cloud.example.com/remote.php/dav/files/a.zip'),
      'webdav',
    );
    expect(
      detectProtocol('webdavs://cloud.example.com/remote.php/dav/files/a.zip'),
      'webdavs',
    );
    expect(detectProtocol('ftp://example.com/file.bin'), 'ftp');
    expect(detectProtocol('ftps://example.com/file.bin'), 'ftps');
    expect(detectProtocol('sftp://example.com/file.bin'), 'sftp');
    expect(detectProtocol('ipfs://bafybeigdyrzt/readme.txt'), 'ipfs');
    expect(detectProtocol('magnet:?xt=urn:btih:abc'), 'magnet');
    expect(detectProtocol('ed2k://|file|x|1|hash|/'), 'ed2k');
    expect(detectProtocol('/tmp/file.torrent'), 'torrent');
    expect(detectProtocol('https://example.com/video.m3u8'), 'm3u8');
    expect(
      detectProtocol('https://example.com/file.torrent?token=1'),
      'torrent',
    );
    expect(detectProtocol('https://example.com/video.m3u8?token=1'), 'm3u8');
  });

  test('serializes queued mobile tasks', () {
    final task = DownloadTask.create(
      source: 'https://example.com/archive.zip',
      outputFolder: '/tmp/downloads',
    );

    final restored = DownloadTask.fromJson(task.toJson());

    expect(restored.id, task.id);
    expect(restored.protocol, 'https');
    expect(restored.fileName, 'archive.zip');
    expect(restored.state, DownloadState.queued);
    expect(restored.outputFolder, '/tmp/downloads');
  });

  test('serializes mobile task download metrics', () {
    final startedAt = DateTime.utc(2026, 6, 13, 8, 0, 0);
    final finishedAt = DateTime.utc(2026, 6, 13, 8, 0, 5);
    final task =
        DownloadTask.create(
          source: 'https://example.com/archive.zip',
          outputFolder: '/tmp/downloads',
        ).copyWith(
          state: DownloadState.finished,
          downloadedBytes: 10 * 1024,
          totalBytes: 10 * 1024,
          startedAt: startedAt,
          finishedAt: finishedAt,
          currentSpeedBytesPerSecond: 0,
        );

    final restored = DownloadTask.fromJson(task.toJson());

    expect(restored.startedAt, startedAt);
    expect(restored.finishedAt, finishedAt);
    expect(restored.elapsed, const Duration(seconds: 5));
    expect(restored.averageSpeedBytesPerSecond, 2048);
  });

  test('serializes torrent metadata and selected file indexes', () {
    final task = DownloadTask.create(
      source: 'https://example.com/bundle.torrent',
      outputFolder: '/tmp/downloads',
      fileName: 'movie.mp4',
      torrentName: 'bundle',
      torrentFiles: const [
        TorrentFileEntry(
          index: 0,
          path: 'bundle/movie.mp4',
          name: 'movie.mp4',
          size: 1024,
          isStreamable: true,
        ),
        TorrentFileEntry(
          index: 1,
          path: 'bundle/readme.txt',
          name: 'readme.txt',
          size: 128,
        ),
      ],
      selectedTorrentFileIndexes: const [0],
    );

    final restored = DownloadTask.fromJson(task.toJson());

    expect(restored.torrentName, 'bundle');
    expect(restored.torrentFiles, hasLength(2));
    expect(restored.torrentFiles.first.path, 'bundle/movie.mp4');
    expect(restored.selectedTorrentFileIndexes, [0]);
    expect(restored.selectedTorrentFiles.single.name, 'movie.mp4');
    expect(restored.selectedTorrentTotalBytes, 1024);
  });

  test('parses single-file and multi-file torrent metadata', () {
    final single = parseTorrentMetadataBytes(
      utf8Bytes('d4:infod4:name10:sample.mp46:lengthi12345eee'),
    );
    expect(single.name, 'sample.mp4');
    expect(single.files.single.name, 'sample.mp4');
    expect(single.files.single.size, 12345);

    final multi = parseTorrentMetadataBytes(
      utf8Bytes(
        'd4:infod4:name6:bundle5:filesld6:lengthi5e4:pathl9:video.mp4ee'
        'd6:lengthi3e4:pathl3:sub8:file.srteeeee',
      ),
    );
    expect(multi.name, 'bundle');
    expect(multi.files, hasLength(2));
    expect(multi.files.first.path, 'video.mp4');
    expect(multi.files.last.path, 'sub/file.srt');
    expect(torrentDisplayName(multi, selectedIndexes: const [0]), 'video.mp4');
    expect(torrentDisplayName(multi, selectedIndexes: const [0, 1]), 'bundle');
  });

  test('freezes mobile task elapsed time while paused', () async {
    final startedAt = DateTime.utc(2026, 6, 13, 8, 0, 0);
    final pausedAt = DateTime.utc(2026, 6, 13, 8, 0, 7);
    final task =
        DownloadTask.create(
          source: 'https://example.com/archive.zip',
          outputFolder: '/tmp/downloads',
        ).copyWith(
          state: DownloadState.paused,
          downloadedBytes: 7 * 1024,
          startedAt: startedAt,
          pausedAt: pausedAt,
          currentSpeedBytesPerSecond: 0,
        );

    final firstElapsed = task.elapsed;
    await Future<void>.delayed(const Duration(milliseconds: 25));

    expect(firstElapsed, const Duration(seconds: 7));
    expect(task.elapsed, firstElapsed);
  });

  test('migrates legacy paused tasks without pause timestamps', () async {
    final startedAt = DateTime.utc(2026, 6, 13, 8, 0, 0);
    final updatedAt = DateTime.utc(2026, 6, 13, 8, 0, 9);
    final json =
        DownloadTask.create(
              source: 'https://example.com/archive.zip',
              outputFolder: '/tmp/downloads',
            )
            .copyWith(
              state: DownloadState.paused,
              downloadedBytes: 9 * 1024,
              startedAt: startedAt,
              updatedAt: updatedAt,
              currentSpeedBytesPerSecond: 0,
            )
            .toJson()
          ..remove('pausedAt');

    final restored = DownloadTask.fromJson(json);
    final firstElapsed = restored.elapsed;
    await Future<void>.delayed(const Duration(milliseconds: 25));

    expect(restored.pausedAt, updatedAt);
    expect(firstElapsed, const Duration(seconds: 9));
    expect(restored.elapsed, firstElapsed);
  });

  test('mobile task store atomically replaces queue files', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_store_test_',
    );
    final store = TaskStore(baseDirectory: tempDir);
    final existingFile = await store.queueFile;
    await existingFile.parent.create(recursive: true);
    await existingFile.writeAsString('[]');

    try {
      final task = DownloadTask.create(
        source: 'https://example.com/archive.zip',
        outputFolder: tempDir.path,
      );
      await store.save([task]);

      final raw = await existingFile.readAsString();
      expect(raw, contains('https://example.com/archive.zip'));
      expect(jsonDecode(raw), isA<List<Object?>>());
      final entries = existingFile.parent
          .listSync()
          .whereType<File>()
          .map((file) => p.basename(file.path))
          .toList();
      expect(entries, ['queue.json']);
      expect((await store.load()).single.id, task.id);
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test('reports mobile executable support for built-in download engines', () {
    expect(supportStatus('https').executable, isTrue);
    expect(supportStatus('http').executable, isTrue);
    expect(supportStatus('webdav').executable, isTrue);
    expect(supportStatus('webdavs').executable, isTrue);
    expect(supportStatus('ftp').executable, isTrue);
    expect(supportStatus('ftps').executable, isTrue);
    expect(supportStatus('sftp').executable, isTrue);
    expect(supportStatus('ipfs').executable, isTrue);
    expect(supportStatus('m3u8').executable, isTrue);
    expect(supportStatus('torrent').executable, isTrue);
    expect(supportStatus('magnet').executable, isTrue);
    expect(supportStatus('smb').executable, isTrue);
    expect(supportStatus('ed2k').executable, isTrue);
  });

  test('mobile controller hands off ed2k tasks to an external app', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_ed2k_test_',
    );
    Uri? launchedUri;
    final controller = DownloadController(
      store: TaskStore(baseDirectory: tempDir),
      runner: MobileDownloadRunner.withLauncher(
        ed2kLauncher: (uri) async {
          launchedUri = uri;
          return true;
        },
      ),
    );

    try {
      final task = await controller.add(
        source: 'ed2k://|file|example.iso|123|ABCDEF|/',
        outputFolder: tempDir.path,
      );

      await controller.start(task.id);

      expect(launchedUri, Uri.parse('ed2k://|file|example.iso|123|ABCDEF|/'));
      expect(controller.tasks.single.state, DownloadState.finished);
      expect(controller.tasks.single.downloadedBytes, 0);
      expect(controller.tasks.single.totalBytes, 0);
      expect(controller.tasks.single.error, isNull);
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'mobile controller runs queued tasks with bounded concurrency',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'fluxdown_mobile_controller_test_',
      );
      final runner = _FakeMobileDownloadRunner();
      final controller = DownloadController(
        store: TaskStore(baseDirectory: tempDir),
        runner: runner,
      );

      try {
        await controller.add(
          source: 'https://example.com/one.bin',
          outputFolder: tempDir.path,
        );
        await controller.add(
          source: 'https://example.com/two.bin',
          outputFolder: tempDir.path,
        );
        await controller.add(
          source: 'https://example.com/three.bin',
          outputFolder: tempDir.path,
        );

        final report = await controller.runQueued(concurrency: 2);

        expect(report.totalQueued, 3);
        expect(report.started, 3);
        expect(report.finished, 3);
        expect(report.failed, 0);
        expect(runner.maxActive, 2);
        expect(controller.tasks.map((task) => task.state).toSet(), {
          DownloadState.finished,
        });
        expect((await TaskStore(baseDirectory: tempDir).load()).length, 3);
      } finally {
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('mobile controller retries failed downloads when configured', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_retry_test_',
    );
    final runner = _FlakyMobileDownloadRunner(failuresBeforeSuccess: 1);
    final controller = DownloadController(
      store: TaskStore(baseDirectory: tempDir),
      runner: runner,
    );

    try {
      final task = await controller.add(
        source: 'https://example.com/retry.bin',
        outputFolder: tempDir.path,
      );

      await controller.start(task.id, maxRetries: 1);

      expect(runner.attempts, 2);
      expect(controller.tasks.single.state, DownloadState.finished);
      expect(controller.tasks.single.error, isNull);
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test('mobile controller keeps running state while retrying', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_retry_running_state_test_',
    );
    final runner = _FlakyMobileDownloadRunner(failuresBeforeSuccess: 1);
    late final DownloadController controller;
    final states = <DownloadState>[];
    controller = DownloadController(
      store: TaskStore(baseDirectory: tempDir),
      runner: runner,
      onChanged: () {
        if (controller.tasks.isNotEmpty) {
          states.add(controller.tasks.single.state);
        }
      },
    );

    try {
      final task = await controller.add(
        source: 'https://example.com/retry-running.bin',
        outputFolder: tempDir.path,
      );
      states.clear();

      await controller.start(task.id, maxRetries: 1);

      expect(states, contains(DownloadState.running));
      expect(states, isNot(contains(DownloadState.queued)));
      expect(states, isNot(contains(DownloadState.failed)));
      expect(controller.tasks.single.state, DownloadState.finished);
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test('mobile controller passes speed limit to downloads', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_speed_limit_test_',
    );
    final runner = _FakeMobileDownloadRunner();
    final controller = DownloadController(
      store: TaskStore(baseDirectory: tempDir),
      runner: runner,
    );

    try {
      final task = await controller.add(
        source: 'https://example.com/limited.bin',
        outputFolder: tempDir.path,
      );

      await controller.start(task.id, speedLimitKbps: 1024);

      expect(runner.speedLimitKbpsValues, [1024]);
      expect(controller.tasks.single.state, DownloadState.finished);
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test('mobile controller passes thread count to downloads', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_thread_count_test_',
    );
    final runner = _FakeMobileDownloadRunner();
    final controller = DownloadController(
      store: TaskStore(baseDirectory: tempDir),
      runner: runner,
    );

    try {
      final task = await controller.add(
        source: 'https://example.com/threaded.bin',
        outputFolder: tempDir.path,
      );

      await controller.start(task.id, threadCount: 16);

      expect(runner.threadCountValues, [16]);
      expect(controller.tasks.single.state, DownloadState.finished);
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'mobile controller keeps picking queued tasks added during a run',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'fluxdown_mobile_dynamic_queue_test_',
      );
      final runner = _FakeMobileDownloadRunner();
      final controller = DownloadController(
        store: TaskStore(baseDirectory: tempDir),
        runner: runner,
      );

      try {
        await controller.add(
          source: 'https://example.com/first.bin',
          outputFolder: tempDir.path,
        );

        final run = controller.runQueued(concurrency: 1);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await controller.add(
          source: 'https://example.com/second.bin',
          outputFolder: tempDir.path,
        );

        final report = await run;

        expect(report.totalQueued, 2);
        expect(report.started, 2);
        expect(report.finished, 2);
        expect(runner.maxActive, 1);
        expect(controller.tasks.map((task) => task.state).toSet(), {
          DownloadState.finished,
        });
      } finally {
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('mobile controller fails once retry budget is exhausted', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_retry_exhausted_test_',
    );
    final runner = _FlakyMobileDownloadRunner(failuresBeforeSuccess: 2);
    final controller = DownloadController(
      store: TaskStore(baseDirectory: tempDir),
      runner: runner,
    );

    try {
      await controller.add(
        source: 'https://example.com/fails.bin',
        outputFolder: tempDir.path,
      );

      final report = await controller.runQueued(concurrency: 1, maxRetries: 1);

      expect(report.totalQueued, 1);
      expect(report.started, 1);
      expect(report.finished, 0);
      expect(report.failed, 1);
      expect(runner.attempts, 2);
      expect(controller.tasks.single.state, DownloadState.failed);
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test('mobile controller records download timing metrics', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_download_metrics_test_',
    );
    final runner = _FakeMobileDownloadRunner();
    final controller = DownloadController(
      store: TaskStore(baseDirectory: tempDir),
      runner: runner,
    );

    try {
      final task = await controller.add(
        source: 'https://example.com/metrics.bin',
        outputFolder: tempDir.path,
      );

      await controller.start(task.id);

      final finished = controller.tasks.single;
      expect(finished.state, DownloadState.finished);
      expect(finished.startedAt, isNotNull);
      expect(finished.finishedAt, isNotNull);
      expect(finished.elapsed, isNotNull);
      expect(finished.averageSpeedBytesPerSecond, greaterThan(0));
      expect(finished.currentSpeedBytesPerSecond, 0);
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test('mobile controller records pause time after cancellation', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_pause_metrics_test_',
    );
    final runner = _CancellableMobileDownloadRunner();
    final controller = DownloadController(
      store: TaskStore(baseDirectory: tempDir),
      runner: runner,
    );

    try {
      final task = await controller.add(
        source: 'https://example.com/pause.bin',
        outputFolder: tempDir.path,
      );

      final run = controller.start(task.id);
      await runner.started.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await controller.pause(task.id);
      await run;

      final paused = controller.tasks.single;
      final elapsed = paused.elapsed;
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(paused.state, DownloadState.paused);
      expect(paused.pausedAt, isNotNull);
      expect(paused.currentSpeedBytesPerSecond, 0);
      expect(paused.elapsed, elapsed);
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'mobile queue starts the next task after pausing an active task',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'fluxdown_mobile_pause_queue_test_',
      );
      final runner = _PauseThenFinishMobileDownloadRunner();
      final controller = DownloadController(
        store: TaskStore(baseDirectory: tempDir),
        runner: runner,
      );

      try {
        final first = await controller.add(
          source: 'https://example.com/first-paused.bin',
          outputFolder: tempDir.path,
        );
        await Future<void>.delayed(const Duration(milliseconds: 2));
        final second = await controller.add(
          source: 'https://example.com/second-finished.bin',
          outputFolder: tempDir.path,
        );

        final run = controller.runQueued(concurrency: 1);
        await runner.firstStarted.future;
        await controller.pause(first.id);
        final report = await run;

        final firstAfter = controller.tasks.firstWhere(
          (task) => task.id == first.id,
        );
        final secondAfter = controller.tasks.firstWhere(
          (task) => task.id == second.id,
        );

        expect(report.started, 2);
        expect(report.finished, 1);
        expect(report.failed, 0);
        expect(firstAfter.state, DownloadState.paused);
        expect(secondAfter.state, DownloadState.finished);
        expect(runner.startedSources, [
          'https://example.com/first-paused.bin',
          'https://example.com/second-finished.bin',
        ]);
      } finally {
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('parses FTPS transfer specs with implicit TLS defaults', () {
    final spec = FtpTransferSpec.fromUri(
      Uri.parse(
        'ftps://user:pass@example.com/pub/file.bin?allowBadCertificate=true',
      ),
    );

    expect(spec.host, 'example.com');
    expect(spec.port, 990);
    expect(spec.username, 'user');
    expect(spec.password, 'pass');
    expect(spec.remotePath, 'pub/file.bin');
    expect(spec.fileName, 'file.bin');
    expect(spec.secure, isTrue);
    expect(spec.implicitTls, isTrue);
    expect(spec.allowBadCertificate, isTrue);
  });

  test('parses SFTP transfer specs with password auth defaults', () {
    final spec = SftpTransferSpec.fromUri(
      Uri.parse('sftp://user:p%40ss@example.com/pub/file.bin'),
    );

    expect(spec.host, 'example.com');
    expect(spec.port, 22);
    expect(spec.username, 'user');
    expect(spec.password, 'p@ss');
    expect(spec.remotePath, 'pub/file.bin');
    expect(spec.fileName, 'file.bin');
  });

  test('parses SMB transfer specs with credentials and security options', () {
    final spec = SmbTransferSpec.fromUri(
      Uri.parse(
        'smb://domain%5Cuser:p%40ss@nas.local/Media/Movies/file.mkv?domain=WORKGROUP&seal=true&signing=true',
      ),
    );

    expect(spec.host, 'nas.local');
    expect(spec.share, 'Media');
    expect(spec.remotePath, 'Movies/file.mkv');
    expect(spec.fileName, 'file.mkv');
    expect(spec.username, r'domain\user');
    expect(spec.password, 'p@ss');
    expect(spec.domain, 'WORKGROUP');
    expect(spec.seal, isTrue);
    expect(spec.signing, isTrue);
  });

  test('downloads HTTP files and resumes partial files with Range', () async {
    final payload = List<int>.generate(4096, (index) => index % 251);
    final tempDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_test_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var sawRange = false;
    final serverDone = server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range == 'bytes=128-') {
        sawRange = true;
        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 128-${payload.length - 1}/${payload.length}',
          )
          ..headers.contentLength = payload.length - 128;
        request.response.add(payload.sublist(128));
      } else {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentLength = payload.length;
        request.response.add(payload);
      }
      await request.response.close();
    });

    try {
      final source = 'http://${server.address.host}:${server.port}/file.bin';
      final task = DownloadTask.create(
        source: source,
        outputFolder: tempDir.path,
        fileName: 'file.bin',
      );
      final runner = MobileDownloadRunner();

      final finished = await runner.downloadHttp(task, onProgress: (_) {});
      expect(finished.state, DownloadState.finished);
      expect(
        await File(p.join(tempDir.path, 'file.bin')).readAsBytes(),
        payload,
      );

      final resumedTask = DownloadTask.create(
        source: source,
        outputFolder: tempDir.path,
        fileName: 'resume.bin',
      );
      await File(
        p.join(tempDir.path, 'resume.bin'),
      ).writeAsBytes(payload.take(128).toList());

      final resumed = await runner.downloadHttp(
        resumedTask,
        onProgress: (_) {},
      );
      expect(resumed.state, DownloadState.finished);
      expect(resumed.downloadedBytes, payload.length);
      expect(
        await File(p.join(tempDir.path, 'resume.bin')).readAsBytes(),
        payload,
      );
      expect(sawRange, isTrue);
    } finally {
      await server.close(force: true);
      await serverDone.cancel();
      await tempDir.delete(recursive: true);
    }
  });

  test('downloads HTTP files with multiple Range threads', () async {
    final payload = List<int>.generate(8192, (index) => index % 251);
    final tempDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_threaded_http_test_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ranges = <String>[];
    final serverDone = server.listen((request) async {
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (request.method == 'HEAD') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentLength = payload.length;
        await request.response.close();
        return;
      }

      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        ranges.add(range);
        final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range);
        final start = int.parse(match!.group(1)!);
        final end = int.parse(match.group(2)!);
        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${payload.length}',
          )
          ..headers.contentLength = end - start + 1;
        request.response.add(payload.sublist(start, end + 1));
      } else {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentLength = payload.length;
        request.response.add(payload);
      }
      await request.response.close();
    });

    try {
      final source = 'http://${server.address.host}:${server.port}/file.bin';
      final task = DownloadTask.create(
        source: source,
        outputFolder: tempDir.path,
        fileName: 'threaded.bin',
      );
      final runner = MobileDownloadRunner();

      final finished = await runner.downloadHttp(
        task,
        threadCount: 4,
        onProgress: (_) {},
      );

      expect(finished.state, DownloadState.finished);
      expect(finished.downloadedBytes, payload.length);
      expect(ranges, hasLength(4));
      expect(
        await File(p.join(tempDir.path, 'threaded.bin')).readAsBytes(),
        payload,
      );
    } finally {
      await server.close(force: true);
      await serverDone.cancel();
      await tempDir.delete(recursive: true);
    }
  });

  test('retries incomplete HTTP Range parts', () async {
    final payload = List<int>.generate(4096, (index) => index % 251);
    final tempDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_threaded_http_retry_test_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var shortResponseSent = false;
    var rangeRequestCount = 0;
    final serverDone = server.listen((request) async {
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (request.method == 'HEAD') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentLength = payload.length;
        await request.response.close();
        return;
      }

      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        rangeRequestCount += 1;
        final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range);
        final start = int.parse(match!.group(1)!);
        final end = int.parse(match.group(2)!);
        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${payload.length}',
          );
        if (!shortResponseSent) {
          shortResponseSent = true;
          request.response.add(payload.sublist(start, start + 1));
        } else {
          request.response.headers.contentLength = end - start + 1;
          request.response.add(payload.sublist(start, end + 1));
        }
      } else {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentLength = payload.length;
        request.response.add(payload);
      }
      await request.response.close();
    });

    try {
      final source = 'http://${server.address.host}:${server.port}/file.bin';
      final task = DownloadTask.create(
        source: source,
        outputFolder: tempDir.path,
        fileName: 'threaded-retry.bin',
      );
      final runner = MobileDownloadRunner();

      final finished = await runner.downloadHttp(
        task,
        threadCount: 4,
        onProgress: (_) {},
      );

      expect(finished.state, DownloadState.finished);
      expect(finished.downloadedBytes, payload.length);
      expect(shortResponseSent, isTrue);
      expect(rangeRequestCount, greaterThan(4));
      expect(
        await File(p.join(tempDir.path, 'threaded-retry.bin')).readAsBytes(),
        payload,
      );
    } finally {
      await server.close(force: true);
      await serverDone.cancel();
      await tempDir.delete(recursive: true);
    }
  });

  test('downloads WebDAV files through HTTP transport', () async {
    final payload = utf8Bytes('webdav-payload-data');
    final tempDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_webdav_test_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverDone = server.listen((request) async {
      expect(request.uri.path, '/remote.php/dav/files/file.bin');
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentLength = payload.length
        ..add(payload);
      await request.response.close();
    });

    try {
      final source =
          'webdav://${server.address.host}:${server.port}/remote.php/dav/files/file.bin';
      final task = DownloadTask.create(
        source: source,
        outputFolder: tempDir.path,
      );
      final runner = MobileDownloadRunner();

      final finished = await runner.download(task, onProgress: (_) {});
      expect(finished.state, DownloadState.finished);
      expect(finished.protocol, 'webdav');
      expect(finished.downloadedBytes, payload.length);
      expect(
        await File(p.join(tempDir.path, 'file.bin')).readAsBytes(),
        payload,
      );
    } finally {
      await server.close(force: true);
      await serverDone.cancel();
      await tempDir.delete(recursive: true);
    }
  });

  test('downloads IPFS files through a configured gateway', () async {
    final payload = utf8Bytes('Hello IPFS');
    final cid = 'bafkreidfdrlkeq4m4xnxuyx6iae76fdm4wgl5d4xzsb77ixhyqwumhz244';
    final tempDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_ipfs_test_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverDone = server.listen((request) async {
      expect(request.uri.path, '/ipfs/$cid/readme.txt');
      expect(request.uri.queryParameters['download'], '1');
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentLength = payload.length
        ..add(payload);
      await request.response.close();
    });

    try {
      final gateway = Uri.encodeComponent(
        'http://${server.address.host}:${server.port}',
      );
      final source = 'ipfs://$cid/readme.txt?gateway=$gateway&download=1';
      final task = DownloadTask.create(
        source: source,
        outputFolder: tempDir.path,
        fileName: 'ipfs-hello.txt',
      );
      final runner = MobileDownloadRunner();

      final finished = await runner.download(task, onProgress: (_) {});
      expect(finished.state, DownloadState.finished);
      expect(finished.protocol, 'ipfs');
      expect(finished.downloadedBytes, payload.length);
      expect(
        await File(p.join(tempDir.path, 'ipfs-hello.txt')).readAsString(),
        'Hello IPFS',
      );
    } finally {
      await server.close(force: true);
      await serverDone.cancel();
      await tempDir.delete(recursive: true);
    }
  });

  test('downloads simple m3u8 playlists into an mp4 file', () async {
    final first = [1, 2, 3, 4];
    final second = [5, 6, 7];
    final tempDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_hls_test_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverDone = server.listen((request) async {
      switch (request.uri.path) {
        case '/playlist.m3u8':
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType(
              'application',
              'vnd.apple.mpegurl',
            )
            ..write('''
#EXTM3U
#EXT-X-VERSION:3
#EXTINF:1,
seg-1.ts
#EXTINF:1,
seg-2.ts
#EXT-X-ENDLIST
''');
        case '/seg-1.ts':
          request.response
            ..statusCode = HttpStatus.ok
            ..add(first);
        case '/seg-2.ts':
          request.response
            ..statusCode = HttpStatus.ok
            ..add(second);
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    try {
      final source =
          'http://${server.address.host}:${server.port}/playlist.m3u8';
      final task = DownloadTask.create(
        source: source,
        outputFolder: tempDir.path,
      );
      final runner = MobileDownloadRunner();

      final finished = await runner.download(task, onProgress: (_) {});
      expect(finished.state, DownloadState.finished);
      expect(finished.fileName, 'playlist.mp4');
      expect(finished.downloadedBytes, first.length + second.length);
      expect(await File(p.join(tempDir.path, 'playlist.mp4')).readAsBytes(), [
        ...first,
        ...second,
      ]);
    } finally {
      await server.close(force: true);
      await serverDone.cancel();
      await tempDir.delete(recursive: true);
    }
  });

  test('downloads fragmented mp4 m3u8 playlists into an mp4 file', () async {
    final init = <int>[
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
    final first = [1, 2, 3, 4];
    final second = [5, 6, 7];
    final tempDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_hls_fmp4_test_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverDone = server.listen((request) async {
      switch (request.uri.path) {
        case '/playlist.m3u8':
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType(
              'application',
              'vnd.apple.mpegurl',
            )
            ..write('''
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-MAP:URI="init.mp4"
#EXTINF:1,
seg-1.m4s
#EXTINF:1,
seg-2.m4s
#EXT-X-ENDLIST
''');
        case '/init.mp4':
          request.response
            ..statusCode = HttpStatus.ok
            ..add(init);
        case '/seg-1.m4s':
          request.response
            ..statusCode = HttpStatus.ok
            ..add(first);
        case '/seg-2.m4s':
          request.response
            ..statusCode = HttpStatus.ok
            ..add(second);
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    try {
      final source =
          'http://${server.address.host}:${server.port}/playlist.m3u8';
      final task = DownloadTask.create(
        source: source,
        outputFolder: tempDir.path,
      );
      final runner = MobileDownloadRunner();

      final finished = await runner.download(task, onProgress: (_) {});
      expect(finished.state, DownloadState.finished);
      expect(finished.fileName, 'playlist.mp4');
      expect(
        finished.downloadedBytes,
        init.length + first.length + second.length,
      );
      expect(await File(p.join(tempDir.path, 'playlist.mp4')).readAsBytes(), [
        ...init,
        ...first,
        ...second,
      ]);
    } finally {
      await server.close(force: true);
      await serverDone.cancel();
      await tempDir.delete(recursive: true);
    }
  });

  test('downloads byte-range fragmented mp4 m3u8 playlists', () async {
    final init = <int>[
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
    final first = [1, 2, 3, 4];
    final second = [5, 6, 7];
    final media = <int>[...init, ...first, ...second];
    final requestedRanges = <String>[];
    final tempDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_hls_byterange_test_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverDone = server.listen((request) async {
      switch (request.uri.path) {
        case '/playlist.m3u8':
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType(
              'application',
              'vnd.apple.mpegurl',
            )
            ..write('''
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-MAP:URI="media.mp4",BYTERANGE="${init.length}@0"
#EXTINF:1,
#EXT-X-BYTERANGE:${first.length}@${init.length}
media.mp4
#EXTINF:1,
#EXT-X-BYTERANGE:${second.length}
media.mp4
#EXT-X-ENDLIST
''');
        case '/media.mp4':
          final range = request.headers.value(HttpHeaders.rangeHeader);
          requestedRanges.add(range ?? '');
          final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range ?? '');
          if (match == null) {
            request.response.statusCode =
                HttpStatus.requestedRangeNotSatisfiable;
          } else {
            final start = int.parse(match.group(1)!);
            final end = int.parse(match.group(2)!);
            request.response
              ..statusCode = HttpStatus.partialContent
              ..headers.set(
                HttpHeaders.contentRangeHeader,
                'bytes $start-$end/${media.length}',
              )
              ..add(media.sublist(start, end + 1));
          }
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    try {
      final source =
          'http://${server.address.host}:${server.port}/playlist.m3u8';
      final task = DownloadTask.create(
        source: source,
        outputFolder: tempDir.path,
      );
      final runner = MobileDownloadRunner();

      final finished = await runner.download(task, onProgress: (_) {});
      expect(finished.state, DownloadState.finished);
      expect(finished.fileName, 'playlist.mp4');
      expect(finished.downloadedBytes, media.length);
      expect(await File(p.join(tempDir.path, 'playlist.mp4')).readAsBytes(), [
        ...init,
        ...first,
        ...second,
      ]);
      expect(
        requestedRanges,
        unorderedEquals([
          'bytes=0-${init.length - 1}',
          'bytes=${init.length}-${init.length + first.length - 1}',
          'bytes=${init.length + first.length}-${media.length - 1}',
        ]),
      );
    } finally {
      await server.close(force: true);
      await serverDone.cancel();
      await tempDir.delete(recursive: true);
    }
  });

  test('downloads m3u8 segments concurrently and preserves order', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_hls_parallel_test_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var activeSegments = 0;
    var maxActiveSegments = 0;
    final serverDone = server.listen((request) async {
      if (request.uri.path == '/playlist.m3u8') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          )
          ..write('''
#EXTM3U
#EXT-X-VERSION:3
#EXTINF:1,
seg-1.ts
#EXTINF:1,
seg-2.ts
#EXTINF:1,
seg-3.ts
#EXTINF:1,
seg-4.ts
#EXTINF:1,
seg-5.ts
#EXTINF:1,
seg-6.ts
#EXT-X-ENDLIST
''');
      } else if (request.uri.path.startsWith('/seg-')) {
        final value = int.parse(
          request.uri.path.replaceFirst('/seg-', '').replaceFirst('.ts', ''),
        );
        activeSegments += 1;
        if (activeSegments > maxActiveSegments) {
          maxActiveSegments = activeSegments;
        }
        await Future<void>.delayed(const Duration(milliseconds: 60));
        request.response
          ..statusCode = HttpStatus.ok
          ..add([value]);
        activeSegments -= 1;
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    try {
      final source =
          'http://${server.address.host}:${server.port}/playlist.m3u8';
      final task = DownloadTask.create(
        source: source,
        outputFolder: tempDir.path,
      );
      final runner = MobileDownloadRunner();

      final finished = await runner.download(
        task,
        threadCount: 3,
        onProgress: (_) {},
      );

      expect(finished.state, DownloadState.finished);
      expect(finished.downloadedBytes, 6);
      expect(maxActiveSegments, greaterThan(1));
      expect(maxActiveSegments, lessThanOrEqualTo(3));
      expect(await File(p.join(tempDir.path, 'playlist.mp4')).readAsBytes(), [
        1,
        2,
        3,
        4,
        5,
        6,
      ]);
    } finally {
      await server.close(force: true);
      await serverDone.cancel();
      await tempDir.delete(recursive: true);
    }
  });

  test('downloads m3u8 master playlists through the first variant', () async {
    final first = [10, 11, 12];
    final second = [13, 14];
    final tempDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_hls_master_test_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverDone = server.listen((request) async {
      switch (request.uri.path) {
        case '/master.m3u8':
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType(
              'application',
              'vnd.apple.mpegurl',
            )
            ..write('''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=640x360
variants/low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2560000,RESOLUTION=1280x720
variants/high.m3u8
''');
        case '/variants/low.m3u8':
          request.response
            ..statusCode = HttpStatus.ok
            ..write('''
#EXTM3U
#EXT-X-VERSION:3
#EXTINF:1,
../low-1.ts
#EXTINF:1,
../low-2.ts
#EXT-X-ENDLIST
''');
        case '/low-1.ts':
          request.response
            ..statusCode = HttpStatus.ok
            ..add(first);
        case '/low-2.ts':
          request.response
            ..statusCode = HttpStatus.ok
            ..add(second);
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    try {
      final source = 'http://${server.address.host}:${server.port}/master.m3u8';
      final task = DownloadTask.create(
        source: source,
        outputFolder: tempDir.path,
      );
      final runner = MobileDownloadRunner();

      final finished = await runner.download(task, onProgress: (_) {});
      expect(finished.state, DownloadState.finished);
      expect(finished.downloadedBytes, first.length + second.length);
      expect(await File(p.join(tempDir.path, 'master.mp4')).readAsBytes(), [
        ...first,
        ...second,
      ]);
    } finally {
      await server.close(force: true);
      await serverDone.cancel();
      await tempDir.delete(recursive: true);
    }
  });

  test('downloads AES-128 encrypted m3u8 playlists', () async {
    final key = Uint8List.fromList(utf8Bytes('0123456789abcdef'));
    final firstIv = Uint8List.fromList([
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      7,
    ]);
    final secondPlain = utf8Bytes('second clear transport stream chunk');
    final firstPlain = utf8Bytes('first clear transport chunk');
    final firstEncrypted = _encryptAes128Cbc(
      Uint8List.fromList(firstPlain),
      key,
      firstIv,
    );
    final secondEncrypted = _encryptAes128Cbc(
      Uint8List.fromList(secondPlain),
      key,
      _sequenceIv(8),
    );
    final tempDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_hls_aes_test_',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverDone = server.listen((request) async {
      switch (request.uri.path) {
        case '/playlist.m3u8':
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType(
              'application',
              'vnd.apple.mpegurl',
            )
            ..write('''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-MEDIA-SEQUENCE:7
#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x00000000000000000000000000000007
#EXTINF:1,
seg-1.ts
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXTINF:1,
seg-2.ts
#EXT-X-ENDLIST
''');
        case '/key.bin':
          request.response
            ..statusCode = HttpStatus.ok
            ..add(key);
        case '/seg-1.ts':
          request.response
            ..statusCode = HttpStatus.ok
            ..add(firstEncrypted);
        case '/seg-2.ts':
          request.response
            ..statusCode = HttpStatus.ok
            ..add(secondEncrypted);
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    try {
      final source =
          'http://${server.address.host}:${server.port}/playlist.m3u8';
      final task = DownloadTask.create(
        source: source,
        outputFolder: tempDir.path,
      );
      final runner = MobileDownloadRunner();

      final finished = await runner.download(task, onProgress: (_) {});
      expect(finished.state, DownloadState.finished);
      expect(finished.downloadedBytes, firstPlain.length + secondPlain.length);
      expect(await File(p.join(tempDir.path, 'playlist.mp4')).readAsBytes(), [
        ...firstPlain,
        ...secondPlain,
      ]);
    } finally {
      await server.close(force: true);
      await serverDone.cancel();
      await tempDir.delete(recursive: true);
    }
  });

  test('downloads FTP files and resumes partial files with REST', () async {
    final payload = utf8Bytes('ftp-payload-data');
    final tempDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_ftp_test_',
    );
    final ftpServer = await _TestFtpServer.start(payload);

    try {
      final source =
          'ftp://user:pass@${ftpServer.host}:${ftpServer.port}/pub/file.bin';
      final task = DownloadTask.create(
        source: source,
        outputFolder: tempDir.path,
      );
      final runner = MobileDownloadRunner();

      final finished = await runner.download(task, onProgress: (_) {});
      expect(finished.state, DownloadState.finished);
      expect(finished.downloadedBytes, payload.length);
      expect(
        await File(p.join(tempDir.path, 'file.bin')).readAsBytes(),
        payload,
      );

      final resumedTask = DownloadTask.create(
        source: source,
        outputFolder: tempDir.path,
        fileName: 'resume.bin',
      );
      await File(
        p.join(tempDir.path, 'resume.bin'),
      ).writeAsBytes(payload.take(3).toList());

      final resumed = await runner.download(resumedTask, onProgress: (_) {});
      expect(resumed.state, DownloadState.finished);
      expect(resumed.downloadedBytes, payload.length);
      expect(ftpServer.restOffsets, contains(3));
      expect(
        await File(p.join(tempDir.path, 'resume.bin')).readAsBytes(),
        payload,
      );
    } finally {
      await ftpServer.close();
      await tempDir.delete(recursive: true);
    }
  });
}

class _FakeMobileDownloadRunner extends MobileDownloadRunner {
  var active = 0;
  var maxActive = 0;
  final speedLimitKbpsValues = <int>[];
  final threadCountValues = <int>[];

  @override
  Future<DownloadTask> download(
    DownloadTask task, {
    int speedLimitKbps = 0,
    int threadCount = 8,
    TorrentMetadataSelector? onTorrentMetadata,
    required FutureOr<void> Function(DownloadTask task) onProgress,
  }) async {
    speedLimitKbpsValues.add(speedLimitKbps);
    threadCountValues.add(threadCount);
    active += 1;
    if (active > maxActive) {
      maxActive = active;
    }

    try {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final progress = task.copyWith(
        state: DownloadState.running,
        downloadedBytes: 8,
        totalBytes: 8,
        clearError: true,
      );
      await onProgress(progress);
      return progress.copyWith(state: DownloadState.finished);
    } finally {
      active -= 1;
    }
  }
}

class _FlakyMobileDownloadRunner extends MobileDownloadRunner {
  _FlakyMobileDownloadRunner({required this.failuresBeforeSuccess});

  var failuresBeforeSuccess = 0;
  var attempts = 0;

  @override
  Future<DownloadTask> download(
    DownloadTask task, {
    int speedLimitKbps = 0,
    int threadCount = 8,
    TorrentMetadataSelector? onTorrentMetadata,
    required FutureOr<void> Function(DownloadTask task) onProgress,
  }) async {
    attempts += 1;
    if (failuresBeforeSuccess > 0) {
      failuresBeforeSuccess -= 1;
      throw const SocketException('temporary failure');
    }

    final progress = task.copyWith(
      state: DownloadState.running,
      downloadedBytes: 8,
      totalBytes: 8,
      clearError: true,
    );
    await onProgress(progress);
    return progress.copyWith(state: DownloadState.finished);
  }
}

class _CancellableMobileDownloadRunner extends MobileDownloadRunner {
  final started = Completer<void>();
  final cancelled = Completer<void>();

  @override
  void cancel(String taskId) {
    if (!cancelled.isCompleted) {
      cancelled.complete();
    }
  }

  @override
  Future<DownloadTask> download(
    DownloadTask task, {
    int speedLimitKbps = 0,
    int threadCount = 8,
    TorrentMetadataSelector? onTorrentMetadata,
    required FutureOr<void> Function(DownloadTask task) onProgress,
  }) async {
    if (!started.isCompleted) {
      started.complete();
    }
    await onProgress(
      task.copyWith(
        state: DownloadState.running,
        downloadedBytes: 4,
        totalBytes: 8,
        clearError: true,
      ),
    );
    await cancelled.future;
    throw const DownloadCancelled();
  }
}

class _PauseThenFinishMobileDownloadRunner extends MobileDownloadRunner {
  final firstStarted = Completer<void>();
  final _firstCancelled = Completer<void>();
  final startedSources = <String>[];
  var _attempt = 0;

  @override
  void cancel(String taskId) {
    if (!_firstCancelled.isCompleted) {
      _firstCancelled.complete();
    }
  }

  @override
  Future<DownloadTask> download(
    DownloadTask task, {
    int speedLimitKbps = 0,
    int threadCount = 8,
    TorrentMetadataSelector? onTorrentMetadata,
    required FutureOr<void> Function(DownloadTask task) onProgress,
  }) async {
    _attempt += 1;
    startedSources.add(task.source);
    if (_attempt == 1) {
      firstStarted.complete();
      await onProgress(
        task.copyWith(
          state: DownloadState.running,
          downloadedBytes: 4,
          totalBytes: 8,
          clearError: true,
        ),
      );
      await _firstCancelled.future;
      throw const DownloadCancelled();
    }

    final progress = task.copyWith(
      state: DownloadState.running,
      downloadedBytes: 8,
      totalBytes: 8,
      clearError: true,
    );
    await onProgress(progress);
    return progress.copyWith(state: DownloadState.finished);
  }
}

List<int> utf8Bytes(String value) => value.codeUnits;

Uint8List _encryptAes128Cbc(Uint8List plaintext, Uint8List key, Uint8List iv) {
  final cipher = PaddedBlockCipher('AES/CBC/PKCS7')
    ..init(
      true,
      PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
        ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
        null,
      ),
    );
  return cipher.process(plaintext);
}

Uint8List _sequenceIv(int sequence) {
  final iv = Uint8List(16);
  final byteData = ByteData.view(iv.buffer);
  byteData.setUint64(8, sequence);
  return iv;
}

class _TestFtpServer {
  _TestFtpServer._(this._server, this.payload);

  final ServerSocket _server;
  final List<int> payload;
  final restOffsets = <int>[];

  String get host => _server.address.host;
  int get port => _server.port;

  static Future<_TestFtpServer> start(List<int> payload) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final ftp = _TestFtpServer._(server, payload);
    server.listen(ftp._handleControlClient);
    return ftp;
  }

  Future<void> close() async {
    await _server.close();
  }

  void _handleControlClient(Socket control) {
    var restOffset = 0;
    ServerSocket? passiveServer;
    control.write('220 FluxDown test FTP\r\n');
    utf8.decoder.bind(control).transform(const LineSplitter()).listen((
      line,
    ) async {
      final command = line.trim();
      if (command.startsWith('USER ')) {
        control.write('331 Password required\r\n');
      } else if (command.startsWith('PASS ')) {
        control.write('230 Logged in\r\n');
      } else if (command == 'TYPE I') {
        control.write('200 Type set\r\n');
      } else if (command.startsWith('SIZE ')) {
        control.write('213 ${payload.length}\r\n');
      } else if (command.startsWith('REST ')) {
        restOffset = int.parse(command.substring(5));
        restOffsets.add(restOffset);
        control.write('350 Restarting at $restOffset\r\n');
      } else if (command == 'EPSV') {
        passiveServer = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        control.write(
          '229 Entering Extended Passive Mode (|||${passiveServer!.port}|)\r\n',
        );
      } else if (command == 'PASV') {
        passiveServer = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final p1 = passiveServer!.port ~/ 256;
        final p2 = passiveServer!.port % 256;
        control.write('227 Entering Passive Mode (127,0,0,1,$p1,$p2)\r\n');
      } else if (command.startsWith('RETR ')) {
        final data = await passiveServer!.first;
        control.write('150 Opening data connection\r\n');
        data.add(payload.sublist(restOffset));
        await data.flush();
        await data.close();
        await passiveServer!.close();
        passiveServer = null;
        restOffset = 0;
        control.write('226 Transfer complete\r\n');
      } else if (command == 'QUIT') {
        control.write('221 Bye\r\n');
        await control.flush();
        await control.close();
      } else {
        control.write('502 Command not implemented\r\n');
      }
    });
  }
}
