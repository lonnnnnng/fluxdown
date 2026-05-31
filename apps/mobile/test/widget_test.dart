import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdown_mobile/src/download_controller.dart';
import 'package:fluxdown_mobile/src/download_task.dart';
import 'package:fluxdown_mobile/src/mobile_downloader.dart';
import 'package:fluxdown_mobile/src/mobile_ftp.dart';
import 'package:fluxdown_mobile/src/mobile_sftp.dart';
import 'package:fluxdown_mobile/src/mobile_smb.dart';
import 'package:fluxdown_mobile/src/protocol.dart';
import 'package:fluxdown_mobile/src/task_store.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart';

void main() {
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

  test('parses FTPS transfer specs with implicit TLS defaults', () {
    final spec = FtpTransferSpec.fromUri(
      Uri.parse('ftps://user:pass@example.com/pub/file.bin'),
    );

    expect(spec.host, 'example.com');
    expect(spec.port, 990);
    expect(spec.username, 'user');
    expect(spec.password, 'pass');
    expect(spec.remotePath, 'pub/file.bin');
    expect(spec.fileName, 'file.bin');
    expect(spec.secure, isTrue);
    expect(spec.implicitTls, isTrue);
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

  test('downloads simple m3u8 playlists into a transport stream', () async {
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
      expect(finished.fileName, 'playlist.m3u8');
      expect(finished.downloadedBytes, first.length + second.length);
      expect(await File(p.join(tempDir.path, 'playlist.ts')).readAsBytes(), [
        ...first,
        ...second,
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
      expect(await File(p.join(tempDir.path, 'master.ts')).readAsBytes(), [
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
      expect(await File(p.join(tempDir.path, 'playlist.ts')).readAsBytes(), [
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

  @override
  Future<DownloadTask> download(
    DownloadTask task, {
    required FutureOr<void> Function(DownloadTask task) onProgress,
  }) async {
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
