import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart';

import 'download_task.dart';
import 'mobile_ed2k.dart';
import 'mobile_ftp.dart';
import 'mobile_sftp.dart';
import 'mobile_smb.dart';
import 'mobile_torrent.dart';

class DownloadCancelled implements Exception {
  const DownloadCancelled();
}

class MobileDownloadRunner {
  MobileDownloadRunner({http.Client? client})
    : this.withLauncher(client: client);

  MobileDownloadRunner.withLauncher({
    http.Client? client,
    Ed2kLauncher? ed2kLauncher,
  }) : _client = client ?? http.Client(),
       _ed2kLauncher = ed2kLauncher ?? launchEd2kUri;

  final http.Client _client;
  final Ed2kLauncher _ed2kLauncher;
  final _cancelled = <String>{};

  void cancel(String taskId) {
    _cancelled.add(taskId);
  }

  Future<DownloadTask> download(
    DownloadTask task, {
    required FutureOr<void> Function(DownloadTask task) onProgress,
  }) {
    if (task.protocol == 'ftp' || task.protocol == 'ftps') {
      return downloadFtp(task, onProgress: onProgress);
    }

    if (task.protocol == 'sftp') {
      return downloadSftp(task, onProgress: onProgress);
    }

    if (task.protocol == 'm3u8') {
      return downloadM3u8(task, onProgress: onProgress);
    }

    if (task.protocol == 'torrent' || task.protocol == 'magnet') {
      return downloadTorrent(task, onProgress: onProgress);
    }

    if (task.protocol == 'smb') {
      return downloadSmb(task, onProgress: onProgress);
    }

    if (task.protocol == 'ed2k') {
      return handOffEd2kTask(
        task,
        onProgress: onProgress,
        launcher: _ed2kLauncher,
      );
    }

    return downloadHttp(task, onProgress: onProgress);
  }

  Future<DownloadTask> downloadHttp(
    DownloadTask task, {
    required FutureOr<void> Function(DownloadTask task) onProgress,
  }) async {
    _cancelled.remove(task.id);
    final outputDir = Directory(task.outputFolder);
    await outputDir.create(recursive: true);
    final outputFile = File(p.join(outputDir.path, task.fileName));
    final partialBytes = await outputFile.exists()
        ? await outputFile.length()
        : 0;

    final sourceUri = _downloadUri(task.source);
    final request = http.Request('GET', sourceUri);
    if (partialBytes > 0) {
      request.headers['Range'] = 'bytes=$partialBytes-';
    }

    final response = await _client.send(request);
    if (partialBytes > 0 && response.statusCode == HttpStatus.ok) {
      await outputFile.writeAsBytes(const []);
    } else if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      throw HttpException('HTTP ${response.statusCode}', uri: sourceUri);
    }

    final append =
        partialBytes > 0 && response.statusCode == HttpStatus.partialContent;
    final startingBytes = append ? partialBytes : 0;
    final contentLength = response.contentLength;
    final totalBytes = contentLength == null
        ? null
        : startingBytes + contentLength;
    var current = task.copyWith(
      state: DownloadState.running,
      downloadedBytes: startingBytes,
      totalBytes: totalBytes,
      clearError: true,
    );
    await onProgress(current);

    final sink = outputFile.openWrite(
      mode: append ? FileMode.append : FileMode.write,
    );
    var downloaded = startingBytes;
    var lastEmit = DateTime.now();

    try {
      await for (final chunk in response.stream) {
        if (_cancelled.contains(task.id)) {
          throw const DownloadCancelled();
        }

        sink.add(chunk);
        downloaded += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastEmit).inMilliseconds >= 250 ||
            downloaded == totalBytes) {
          current = current.copyWith(
            downloadedBytes: downloaded,
            totalBytes: totalBytes,
          );
          await onProgress(current);
          lastEmit = now;
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    _cancelled.remove(task.id);
    return current.copyWith(
      state: DownloadState.finished,
      downloadedBytes: downloaded,
      totalBytes: totalBytes ?? downloaded,
      clearError: true,
    );
  }

  Future<DownloadTask> downloadFtp(
    DownloadTask task, {
    required FutureOr<void> Function(DownloadTask task) onProgress,
  }) async {
    _cancelled.remove(task.id);
    final spec = FtpTransferSpec.fromUri(
      Uri.parse(task.source),
      fileName: task.fileName,
    );
    final outputDir = Directory(task.outputFolder);
    await outputDir.create(recursive: true);
    final outputFile = File(p.join(outputDir.path, spec.fileName));
    final partialBytes = await outputFile.exists()
        ? await outputFile.length()
        : 0;
    final ftp = await MobileFtpClient.connect(spec);
    try {
      await ftp.login(spec);
      await ftp.binary();
      await ftp.protectDataConnections();
      final totalBytes = await ftp.size(spec.remotePath);
      if (partialBytes > 0) {
        await ftp.resume(partialBytes);
      }

      var current = task.copyWith(
        state: DownloadState.running,
        downloadedBytes: partialBytes,
        totalBytes: totalBytes,
        clearError: true,
      );
      await onProgress(current);

      final dataSocket = await ftp.openPassiveDataSocket();
      await ftp.beginRetrieve(spec.remotePath);
      final sink = outputFile.openWrite(
        mode: partialBytes > 0 ? FileMode.append : FileMode.write,
      );
      var downloaded = partialBytes;
      try {
        downloaded = await pipeFtpData(
          dataSocket: dataSocket,
          sink: sink,
          startingBytes: partialBytes,
          isCancelled: () => _cancelled.contains(task.id),
          onProgress: (bytes) async {
            current = current.copyWith(
              downloadedBytes: bytes,
              totalBytes: totalBytes,
            );
            await onProgress(current);
          },
        );
      } on FtpException catch (error) {
        if (error.message.contains('cancelled')) {
          throw const DownloadCancelled();
        }
        rethrow;
      } finally {
        await sink.flush();
        await sink.close();
      }
      await ftp.completeRetrieve();
      _cancelled.remove(task.id);
      return current.copyWith(
        state: DownloadState.finished,
        downloadedBytes: downloaded,
        totalBytes: totalBytes ?? downloaded,
        clearError: true,
      );
    } finally {
      await ftp.close();
    }
  }

  Future<DownloadTask> downloadM3u8(
    DownloadTask task, {
    required FutureOr<void> Function(DownloadTask task) onProgress,
  }) async {
    _cancelled.remove(task.id);
    final outputDir = Directory(task.outputFolder);
    await outputDir.create(recursive: true);
    final outputFile = File(
      p.join(outputDir.path, _hlsFileName(task.fileName)),
    );
    final playlistUri = Uri.parse(task.source);
    final playlistText = await _readText(playlistUri);
    final mediaPlaylistUri = await _mediaPlaylistUri(playlistUri, playlistText);
    final mediaText = mediaPlaylistUri == playlistUri
        ? playlistText
        : await _readText(mediaPlaylistUri);
    final segments = _hlsSegments(mediaPlaylistUri, mediaText);
    if (segments.isEmpty) {
      throw const FormatException(
        'm3u8 playlist has no downloadable segments.',
      );
    }

    var current = task.copyWith(
      state: DownloadState.running,
      downloadedBytes: 0,
      totalBytes: null,
      clearTotalBytes: true,
      clearError: true,
    );
    await onProgress(current);

    final sink = outputFile.openWrite(mode: FileMode.write);
    var downloaded = 0;
    final keyCache = <Uri, Uint8List>{};
    try {
      for (final segment in segments) {
        if (_cancelled.contains(task.id)) {
          throw const DownloadCancelled();
        }
        final response = await _client.send(http.Request('GET', segment.uri));
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException('HTTP ${response.statusCode}', uri: segment.uri);
        }
        final bytes = await response.stream.toBytes();
        if (_cancelled.contains(task.id)) {
          throw const DownloadCancelled();
        }
        final segmentBytes = await _decodeHlsSegment(segment, bytes, keyCache);
        sink.add(segmentBytes);
        downloaded += segmentBytes.length;
        current = current.copyWith(
          downloadedBytes: downloaded,
          totalBytes: null,
          clearTotalBytes: true,
        );
        await onProgress(current);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    _cancelled.remove(task.id);
    return current.copyWith(
      state: DownloadState.finished,
      downloadedBytes: downloaded,
      totalBytes: downloaded,
      clearError: true,
    );
  }

  Future<DownloadTask> downloadSftp(
    DownloadTask task, {
    required FutureOr<void> Function(DownloadTask task) onProgress,
  }) async {
    _cancelled.remove(task.id);
    final spec = SftpTransferSpec.fromUri(
      Uri.parse(task.source),
      fileName: task.fileName,
    );
    final outputDir = Directory(task.outputFolder);
    await outputDir.create(recursive: true);
    final outputFile = File(p.join(outputDir.path, spec.fileName));
    final partialBytes = await outputFile.exists()
        ? await outputFile.length()
        : 0;
    final sftp = await MobileSftpClient.connect(spec);
    try {
      final totalBytes = await sftp.size(spec.remotePath);
      var current = task.copyWith(
        state: DownloadState.running,
        downloadedBytes: partialBytes,
        totalBytes: totalBytes,
        clearError: true,
      );
      await onProgress(current);

      final sink = outputFile.openWrite(
        mode: partialBytes > 0 ? FileMode.append : FileMode.write,
      );
      var downloaded = partialBytes;
      try {
        downloaded = await sftp.download(
          remotePath: spec.remotePath,
          sink: sink,
          startingBytes: partialBytes,
          isCancelled: () => _cancelled.contains(task.id),
          onProgress: (bytes) async {
            current = current.copyWith(
              downloadedBytes: bytes,
              totalBytes: totalBytes,
            );
            await onProgress(current);
          },
        );
      } on SftpDownloadCancelled {
        throw const DownloadCancelled();
      } finally {
        await sink.flush();
        await sink.close();
      }

      _cancelled.remove(task.id);
      return current.copyWith(
        state: DownloadState.finished,
        downloadedBytes: downloaded,
        totalBytes: totalBytes ?? downloaded,
        clearError: true,
      );
    } finally {
      await sftp.close();
    }
  }

  Future<DownloadTask> downloadTorrent(
    DownloadTask task, {
    required FutureOr<void> Function(DownloadTask task) onProgress,
  }) async {
    _cancelled.remove(task.id);
    final runner = MobileTorrentRunner(client: _client);
    try {
      final finished = await runner.download(
        task,
        onProgress: onProgress,
        isCancelled: () => _cancelled.contains(task.id),
      );
      _cancelled.remove(task.id);
      return finished;
    } on TorrentDownloadCancelled {
      throw const DownloadCancelled();
    }
  }

  Future<DownloadTask> downloadSmb(
    DownloadTask task, {
    required FutureOr<void> Function(DownloadTask task) onProgress,
  }) async {
    _cancelled.remove(task.id);
    try {
      final finished = await downloadSmbTask(
        task,
        onProgress: onProgress,
        isCancelled: () => _cancelled.contains(task.id),
      );
      _cancelled.remove(task.id);
      return finished;
    } on SmbDownloadCancelled {
      throw const DownloadCancelled();
    }
  }

  Future<String> _readText(Uri uri) async {
    final response = await _client.get(uri);
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    return response.body;
  }

  Future<Uri> _mediaPlaylistUri(Uri playlistUri, String playlistText) async {
    final lines = _playlistLines(playlistText);
    for (var index = 0; index < lines.length; index += 1) {
      if (lines[index].startsWith('#EXT-X-STREAM-INF')) {
        for (var next = index + 1; next < lines.length; next += 1) {
          if (!lines[next].startsWith('#')) {
            return playlistUri.resolve(lines[next]);
          }
        }
      }
    }
    return playlistUri;
  }

  List<HlsSegment> _hlsSegments(Uri playlistUri, String playlistText) {
    final lines = _playlistLines(playlistText);
    final segments = <HlsSegment>[];
    HlsKey? currentKey;
    var mediaSequence = 0;
    var segmentIndex = 0;

    for (final line in lines) {
      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        mediaSequence =
            int.tryParse(line.substring('#EXT-X-MEDIA-SEQUENCE:'.length)) ?? 0;
      } else if (line.startsWith('#EXT-X-KEY:')) {
        currentKey = _parseHlsKey(playlistUri, line);
      } else if (!line.startsWith('#')) {
        segments.add(
          HlsSegment(
            uri: playlistUri.resolve(line),
            sequence: mediaSequence + segmentIndex,
            key: currentKey,
          ),
        );
        segmentIndex += 1;
      }
    }

    return segments;
  }

  List<String> _playlistLines(String playlistText) {
    return playlistText
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  }

  String _hlsFileName(String fileName) {
    final extension = p.extension(fileName).toLowerCase();
    if (extension == '.ts') {
      return fileName;
    }
    return '${p.basenameWithoutExtension(fileName)}.ts';
  }

  HlsKey? _parseHlsKey(Uri playlistUri, String line) {
    final attrs = _parseHlsAttributes(line.substring('#EXT-X-KEY:'.length));
    final method = attrs['METHOD']?.toUpperCase();
    if (method == null) {
      throw const FormatException('HLS key is missing METHOD.');
    }
    if (method == 'NONE') {
      return null;
    }
    if (method != 'AES-128') {
      throw FormatException('Unsupported HLS key method: $method');
    }
    final keyFormat = attrs['KEYFORMAT'];
    if (keyFormat != null && keyFormat != 'identity') {
      throw FormatException('Unsupported HLS KEYFORMAT: $keyFormat');
    }
    final uri = attrs['URI'];
    if (uri == null || uri.isEmpty) {
      throw const FormatException('AES-128 HLS key is missing URI.');
    }

    return HlsKey(
      uri: playlistUri.resolve(uri),
      iv: attrs['IV'] == null ? null : _parseHlsIv(attrs['IV']!),
    );
  }

  Map<String, String> _parseHlsAttributes(String value) {
    final attributes = <String, String>{};
    final buffer = StringBuffer();
    final parts = <String>[];
    var quoted = false;

    for (var index = 0; index < value.length; index += 1) {
      final char = value[index];
      if (char == '"') {
        quoted = !quoted;
        continue;
      }
      if (char == ',' && !quoted) {
        parts.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(char);
      }
    }
    if (buffer.isNotEmpty) {
      parts.add(buffer.toString());
    }

    for (final part in parts) {
      final equals = part.indexOf('=');
      if (equals <= 0) {
        continue;
      }
      attributes[part.substring(0, equals).trim()] = part
          .substring(equals + 1)
          .trim();
    }
    return attributes;
  }

  Future<Uint8List> _decodeHlsSegment(
    HlsSegment segment,
    List<int> bytes,
    Map<Uri, Uint8List> keyCache,
  ) async {
    final key = segment.key;
    if (key == null) {
      return Uint8List.fromList(bytes);
    }

    final keyBytes = await _hlsKeyBytes(key.uri, keyCache);
    final iv = key.iv ?? _hlsSequenceIv(segment.sequence);
    return _decryptAes128Cbc(Uint8List.fromList(bytes), keyBytes, iv);
  }

  Future<Uint8List> _hlsKeyBytes(Uri uri, Map<Uri, Uint8List> keyCache) async {
    final cached = keyCache[uri];
    if (cached != null) {
      return cached;
    }

    final response = await _client.get(uri);
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    final bytes = Uint8List.fromList(response.bodyBytes);
    if (bytes.length != 16) {
      throw FormatException(
        'AES-128 HLS key must be 16 bytes, got ${bytes.length}.',
      );
    }
    keyCache[uri] = bytes;
    return bytes;
  }

  Uint8List _parseHlsIv(String value) {
    final hex = value.startsWith('0x') || value.startsWith('0X')
        ? value.substring(2)
        : value;
    if (hex.length != 32) {
      throw FormatException(
        'HLS IV must be 16 bytes of hex, got ${hex.length} hex chars.',
      );
    }

    final bytes = Uint8List(16);
    for (var index = 0; index < 16; index += 1) {
      bytes[index] = int.parse(
        hex.substring(index * 2, index * 2 + 2),
        radix: 16,
      );
    }
    return bytes;
  }

  Uint8List _hlsSequenceIv(int sequence) {
    final iv = Uint8List(16);
    final byteData = ByteData.view(iv.buffer);
    byteData.setUint64(8, sequence);
    return iv;
  }

  Uint8List _decryptAes128Cbc(
    Uint8List ciphertext,
    Uint8List key,
    Uint8List iv,
  ) {
    final cipher = PaddedBlockCipher('AES/CBC/PKCS7')
      ..init(
        false,
        PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
          ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
          null,
        ),
      );
    return cipher.process(ciphertext);
  }

  Uri _downloadUri(String source) {
    final uri = Uri.parse(source);
    if (uri.scheme == 'webdav') {
      return uri.replace(scheme: 'http');
    }
    if (uri.scheme == 'webdavs') {
      return uri.replace(scheme: 'https');
    }
    if (uri.scheme != 'ipfs') {
      return uri;
    }
    final cid = uri.host;
    if (cid.isEmpty) {
      throw FormatException('Invalid IPFS URL: $source');
    }
    return Uri.https('ipfs.io', '/ipfs/$cid${uri.path}', uri.queryParameters);
  }
}

class HlsSegment {
  const HlsSegment({
    required this.uri,
    required this.sequence,
    required this.key,
  });

  final Uri uri;
  final int sequence;
  final HlsKey? key;
}

class HlsKey {
  const HlsKey({required this.uri, required this.iv});

  final Uri uri;
  final Uint8List? iv;
}
