import 'dart:async';
import 'dart:io';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:path/path.dart' as p;

import 'download_task.dart';
import 'transfer_metrics.dart';

class SmbDownloadCancelled implements Exception {
  const SmbDownloadCancelled();
}

class SmbTransferSpec {
  const SmbTransferSpec({
    required this.host,
    required this.share,
    required this.remotePath,
    required this.fileName,
    this.username,
    this.password,
    this.domain,
    this.seal = false,
    this.signing = false,
  });

  factory SmbTransferSpec.fromUri(Uri uri, {String? fileName}) {
    if (uri.scheme != 'smb') {
      throw FormatException('Expected smb:// URL, got ${uri.scheme}.');
    }
    if (uri.host.isEmpty) {
      throw const FormatException('SMB URL must include a host.');
    }

    final segments = uri.pathSegments
        .map(Uri.decodeComponent)
        .where((part) => part.trim().isNotEmpty)
        .toList(growable: false);
    if (segments.length < 2) {
      throw const FormatException(
        'SMB URL must include a share and file path.',
      );
    }

    return SmbTransferSpec(
      host: uri.host,
      share: segments.first,
      remotePath: segments.skip(1).join('/'),
      fileName: fileName?.trim().isNotEmpty == true
          ? fileName!.trim()
          : segments.last,
      username: uri.userInfo.isEmpty
          ? null
          : Uri.decodeComponent(uri.userInfo.split(':').first),
      password: uri.userInfo.contains(':')
          ? Uri.decodeComponent(uri.userInfo.split(':').skip(1).join(':'))
          : null,
      domain: uri.queryParameters['domain'],
      seal: uri.queryParameters['seal'] == 'true',
      signing: uri.queryParameters['signing'] == 'true',
    );
  }

  final String host;
  final String share;
  final String remotePath;
  final String fileName;
  final String? username;
  final String? password;
  final String? domain;
  final bool seal;
  final bool signing;
}

class MobileSmbClient {
  MobileSmbClient(this._pool);

  final Smb2Pool _pool;

  static Future<MobileSmbClient> connect(SmbTransferSpec spec) async {
    final pool = await Smb2Pool.connect(
      host: spec.host,
      share: spec.share,
      user: spec.username,
      password: spec.password,
      domain: spec.domain,
      workers: 1,
      seal: spec.seal,
      signing: spec.signing,
    );
    return MobileSmbClient(pool);
  }

  Future<int> download({
    required String remotePath,
    required File outputFile,
    required bool Function() isCancelled,
    required FutureOr<void> Function(int downloaded, int total) onProgress,
  }) async {
    return _pool.downloadToFile(
      remotePath,
      outputFile,
      onProgress: (downloaded, total) {
        onProgress(downloaded, total);
      },
      isCanceled: isCancelled,
    );
  }

  Future<void> close() => _pool.disconnect();
}

Future<DownloadTask> downloadSmbTask(
  DownloadTask task, {
  required FutureOr<void> Function(DownloadTask task) onProgress,
  required bool Function() isCancelled,
}) async {
  final spec = SmbTransferSpec.fromUri(
    Uri.parse(task.source),
    fileName: task.fileName,
  );
  final outputDir = Directory(task.outputFolder);
  await outputDir.create(recursive: true);
  final outputFile = File(p.join(outputDir.path, spec.fileName));
  final client = await MobileSmbClient.connect(spec);

  var current = task.copyWith(
    state: DownloadState.running,
    downloadedBytes: 0,
    totalBytes: null,
    clearTotalBytes: true,
    clearError: true,
  );
  await onProgress(current);
  final speedSampler = TransferSpeedSampler();

  try {
    final downloaded = await client.download(
      remotePath: spec.remotePath,
      outputFile: outputFile,
      isCancelled: isCancelled,
      onProgress: (bytes, total) async {
        current = current.copyWith(
          downloadedBytes: bytes,
          totalBytes: total > 0 ? total : null,
          clearTotalBytes: total <= 0,
          currentSpeedBytesPerSecond: speedSampler.sample(bytes),
        );
        await onProgress(current);
      },
    );
    return current.copyWith(
      state: DownloadState.finished,
      downloadedBytes: downloaded,
      totalBytes: current.totalBytes ?? downloaded,
      clearError: true,
    );
  } on Smb2Exception catch (error) {
    if (error.message.toLowerCase().contains('cancel')) {
      throw const SmbDownloadCancelled();
    }
    rethrow;
  } finally {
    await client.close();
  }
}
