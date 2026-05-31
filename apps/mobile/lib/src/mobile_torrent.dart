import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:path/path.dart' as p;

import 'download_task.dart';

class TorrentDownloadCancelled implements Exception {
  const TorrentDownloadCancelled();
}

class MobileTorrentRunner {
  MobileTorrentRunner({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  Future<DownloadTask> download(
    DownloadTask task, {
    required FutureOr<void> Function(DownloadTask task) onProgress,
    required bool Function() isCancelled,
  }) async {
    final outputDir = Directory(task.outputFolder);
    await outputDir.create(recursive: true);

    await LibtorrentFlutter.init(
      defaultSavePath: outputDir.path,
      pollInterval: const Duration(milliseconds: 500),
    );
    final engine = LibtorrentFlutter.instance;
    final torrentSource = await _torrentSourcePath(task);
    final torrentId = task.protocol == 'magnet'
        ? engine.addMagnet(task.source, outputDir.path)
        : engine.addTorrentFile(torrentSource, outputDir.path);

    var current = task.copyWith(
      state: DownloadState.running,
      downloadedBytes: 0,
      totalBytes: null,
      clearTotalBytes: true,
      clearError: true,
    );
    await onProgress(current);

    StreamSubscription<Map<int, TorrentInfo>>? subscription;
    final completion = Completer<DownloadTask>();

    Future<void> emit(TorrentInfo info) async {
      if (completion.isCompleted) {
        return;
      }

      if (isCancelled()) {
        try {
          engine.pauseTorrent(torrentId);
        } finally {
          completion.completeError(const TorrentDownloadCancelled());
        }
        return;
      }

      if (info.state == TorrentState.error) {
        completion.completeError(
          StateError(
            info.errorMsg.isEmpty ? 'Torrent download failed.' : info.errorMsg,
          ),
        );
        return;
      }

      final total = info.totalWanted > 0 ? info.totalWanted : null;
      current = current.copyWith(
        downloadedBytes: info.totalDone,
        totalBytes: total,
        clearTotalBytes: total == null,
      );
      await onProgress(current);

      final doneByBytes = total != null && info.totalDone >= total;
      if (info.isFinished || info.state.isDone || doneByBytes) {
        completion.complete(
          current.copyWith(
            state: DownloadState.finished,
            downloadedBytes: info.totalDone,
            totalBytes: total ?? info.totalDone,
            clearError: true,
          ),
        );
      }
    }

    subscription = engine.torrentUpdates.listen((snapshot) {
      final info = snapshot[torrentId];
      if (info == null) {
        return;
      }
      unawaited(emit(info));
    }, onError: completion.completeError);

    final initial = engine.torrents[torrentId];
    if (initial != null) {
      await emit(initial);
    }

    Timer? cancelPoller;
    cancelPoller = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!completion.isCompleted && isCancelled()) {
        try {
          engine.pauseTorrent(torrentId);
        } finally {
          completion.completeError(const TorrentDownloadCancelled());
        }
      }
    });

    try {
      final finished = await completion.future;
      engine.removeTorrent(torrentId, deleteFiles: false);
      return finished;
    } finally {
      cancelPoller.cancel();
      await subscription.cancel();
    }
  }

  Future<String> _torrentSourcePath(DownloadTask task) async {
    if (task.protocol != 'torrent') {
      return task.source;
    }

    final uri = Uri.tryParse(task.source);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return _downloadTorrentFile(uri, task.id);
    }
    if (uri != null && uri.scheme == 'file') {
      return uri.toFilePath();
    }
    return task.source;
  }

  Future<String> _downloadTorrentFile(Uri uri, String taskId) async {
    final response = await _client.get(uri);
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }

    final tempDir = await Directory.systemTemp.createTemp('fluxdown_torrent_');
    final fileName = p.basename(uri.path).trim().isEmpty
        ? '$taskId.torrent'
        : p.basename(uri.path);
    final file = File(p.join(tempDir.path, fileName));
    await file.writeAsBytes(response.bodyBytes);
    return file.path;
  }
}
