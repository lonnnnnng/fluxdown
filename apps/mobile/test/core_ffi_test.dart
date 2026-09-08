import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdown_mobile/src/core_bridge.dart';
import 'package:fluxdown_mobile/src/ffi/fluxdown_ffi.dart';

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
