import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

class SftpTransferSpec {
  const SftpTransferSpec({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.remotePath,
    required this.fileName,
  });

  factory SftpTransferSpec.fromUri(Uri uri, {String? fileName}) {
    if (uri.scheme != 'sftp' || uri.host.isEmpty || uri.pathSegments.isEmpty) {
      throw FormatException('Invalid SFTP URL: $uri');
    }
    if (uri.userInfo.isEmpty) {
      throw FormatException('SFTP URL must include a username: $uri');
    }

    final parts = uri.userInfo.split(':');
    final username = Uri.decodeComponent(parts.first);
    final password = parts.length > 1
        ? Uri.decodeComponent(parts.skip(1).join(':'))
        : '';
    final segment = uri.pathSegments
        .where((part) => part.trim().isNotEmpty)
        .last;

    return SftpTransferSpec(
      host: uri.host,
      port: uri.hasPort ? uri.port : 22,
      username: username,
      password: password,
      remotePath: uri.pathSegments.map(Uri.decodeComponent).join('/'),
      fileName: fileName?.trim().isNotEmpty == true
          ? fileName!.trim()
          : Uri.decodeComponent(segment),
    );
  }

  final String host;
  final int port;
  final String username;
  final String password;
  final String remotePath;
  final String fileName;
}

class MobileSftpClient {
  MobileSftpClient._(this._client, this._sftp);

  final SSHClient _client;
  final SftpClient _sftp;

  static Future<MobileSftpClient> connect(SftpTransferSpec spec) async {
    final socket = await SSHSocket.connect(
      spec.host,
      spec.port,
      timeout: const Duration(seconds: 20),
    );
    final client = SSHClient(
      socket,
      username: spec.username,
      onPasswordRequest: () => spec.password,
    );
    final sftp = await client.sftp();
    return MobileSftpClient._(client, sftp);
  }

  Future<int?> size(String remotePath) async {
    return (await _sftp.stat(remotePath)).size;
  }

  Future<int> download({
    required String remotePath,
    required IOSink sink,
    required int startingBytes,
    required bool Function() isCancelled,
    required FutureOr<void> Function(int downloadedBytes) onProgress,
  }) async {
    var downloaded = startingBytes;
    final file = await _sftp.open(remotePath, mode: SftpFileOpenMode.read);
    try {
      await for (final chunk in file.read(offset: startingBytes)) {
        if (isCancelled()) {
          throw const SftpDownloadCancelled();
        }
        sink.add(chunk);
        downloaded += chunk.length;
        await onProgress(downloaded);
      }
      return downloaded;
    } finally {
      await file.close();
    }
  }

  Future<void> close() async {
    _client.close();
    await _client.done.catchError((_) {});
  }
}

class SftpDownloadCancelled implements Exception {
  const SftpDownloadCancelled();
}
