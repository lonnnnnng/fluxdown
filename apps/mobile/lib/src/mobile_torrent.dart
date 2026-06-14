import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:path/path.dart' as p;

import 'download_task.dart';
import 'transfer_metrics.dart';

class TorrentDownloadCancelled implements Exception {
  const TorrentDownloadCancelled();
}

class TorrentMetadataSelectionCancelled implements Exception {
  const TorrentMetadataSelectionCancelled();
}

class TorrentMetadata {
  const TorrentMetadata({required this.name, required this.files});

  final String name;
  final List<TorrentFileEntry> files;

  int get totalBytes => files.fold<int>(0, (total, file) => total + file.size);

  bool get hasMultipleFiles => files.length > 1;
}

class TorrentFileSelection {
  const TorrentFileSelection({required this.selectedIndexes});

  final List<int> selectedIndexes;
}

typedef TorrentMetadataSelector =
    Future<TorrentFileSelection?> Function(
      DownloadTask task,
      TorrentMetadata metadata,
    );

class MobileTorrentRunner {
  MobileTorrentRunner({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  Future<DownloadTask> download(
    DownloadTask task, {
    required FutureOr<void> Function(DownloadTask task) onProgress,
    required bool Function() isCancelled,
    TorrentMetadataSelector? onMetadata,
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
        ? engine.addMagnet(
            await _magnetSourceWithTrackers(task.source),
            outputDir.path,
          )
        : engine.addTorrentFile(torrentSource, outputDir.path);

    var current = task.copyWith(
      state: DownloadState.running,
      downloadedBytes: 0,
      totalBytes: task.selectedTorrentTotalBytes,
      clearTotalBytes: task.selectedTorrentTotalBytes == null,
      clearError: true,
    );
    await onProgress(current);
    final speedSampler = TransferSpeedSampler();

    StreamSubscription<Map<int, TorrentInfo>>? subscription;
    final completion = Completer<DownloadTask>();
    var metadataHandled = false;
    Future<void>? metadataHandling;

    Future<void> applyMetadataBody(TorrentInfo info) async {
      final files = engine.getFiles(torrentId);
      if (files.isEmpty) {
        return;
      }

      final metadata = _metadataFromLibtorrent(info.name, files);
      var selectedIndexes = current.selectedTorrentFileIndexes;
      var pausedForSelection = false;
      if (selectedIndexes == null || selectedIndexes.isEmpty) {
        if (metadata.hasMultipleFiles && onMetadata != null) {
          engine.pauseTorrent(torrentId);
          pausedForSelection = true;
          final selection = await onMetadata(current, metadata);
          if (selection == null || selection.selectedIndexes.isEmpty) {
            try {
              engine.pauseTorrent(torrentId);
            } finally {
              completion.completeError(
                const TorrentMetadataSelectionCancelled(),
              );
            }
            return;
          }
          selectedIndexes = selection.selectedIndexes;
        } else {
          selectedIndexes = metadata.files.map((file) => file.index).toList();
        }
      }

      final validSelectedIndexes = _validSelectedIndexes(
        metadata.files,
        selectedIndexes,
      );
      final selectedFiles = _selectedFiles(
        metadata.files,
        validSelectedIndexes,
      );
      if (selectedFiles.isEmpty) {
        throw StateError('No torrent files selected.');
      }

      engine.setFilePriorities(
        torrentId,
        metadata.files
            .map((file) => validSelectedIndexes.contains(file.index) ? 1 : 0)
            .toList(growable: false),
      );

      final selectedTotal = selectedFiles.fold<int>(
        0,
        (total, file) => total + file.size,
      );
      current = current.copyWith(
        fileName: torrentDisplayName(
          metadata,
          selectedIndexes: validSelectedIndexes,
        ),
        torrentName: metadata.name,
        torrentFiles: metadata.files,
        selectedTorrentFileIndexes: validSelectedIndexes,
        totalBytes: selectedTotal,
        clearError: true,
      );
      await onProgress(current);
      metadataHandled = true;
      if (pausedForSelection && !completion.isCompleted) {
        engine.resumeTorrent(torrentId);
      }
    }

    Future<void> applyMetadata(TorrentInfo info) {
      if (metadataHandled || !info.hasMetadata) {
        return Future.value();
      }
      final pending = metadataHandling;
      if (pending != null) {
        return pending;
      }
      final future = applyMetadataBody(info);
      metadataHandling = future.whenComplete(() {
        metadataHandling = null;
      });
      return metadataHandling!;
    }

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

      try {
        await applyMetadata(info);
      } catch (error, stackTrace) {
        if (!completion.isCompleted) {
          completion.completeError(error, stackTrace);
        }
        return;
      }
      if (completion.isCompleted) {
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

      final selectedTotal = current.selectedTorrentTotalBytes;
      final total =
          selectedTotal ?? (info.totalWanted > 0 ? info.totalWanted : null);
      final reportedDone = total == null
          ? info.totalDone
          : math.min(info.totalDone, total);
      final sampledSpeed = speedSampler.sample(reportedDone);
      current = current.copyWith(
        downloadedBytes: reportedDone,
        totalBytes: total,
        clearTotalBytes: total == null,
        currentSpeedBytesPerSecond: info.downloadRate > 0
            ? info.downloadRate
            : sampledSpeed,
      );
      await onProgress(current);

      final doneByBytes = total != null && reportedDone >= total;
      final doneWithoutKnownTotal =
          total == null &&
          (info.isFinished || info.state.isDone) &&
          reportedDone > 0;
      if (doneByBytes || doneWithoutKnownTotal) {
        completion.complete(
          current.copyWith(
            state: DownloadState.finished,
            downloadedBytes: reportedDone,
            totalBytes: total ?? reportedDone,
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

  Future<String> _magnetSourceWithTrackers(String source) async {
    await TrackerManager.fetchBestTrackers();
    return _appendFallbackTrackers(source);
  }

  String _appendFallbackTrackers(String source) {
    var magnet = source;
    for (final tracker in _fallbackMagnetTrackers) {
      final encoded = Uri.encodeComponent(tracker);
      if (magnet.contains('tr=$encoded') || magnet.contains('tr=$tracker')) {
        continue;
      }
      magnet = '$magnet&tr=$encoded';
    }
    return magnet;
  }
}

Future<TorrentMetadata?> inspectTorrentMetadataFromSource(
  String source, {
  http.Client? client,
}) async {
  final bytes = await _readTorrentBytesFromSource(source, client: client);
  if (bytes == null) {
    return null;
  }
  return parseTorrentMetadataBytes(bytes);
}

TorrentMetadata parseTorrentMetadataBytes(List<int> bytes) {
  final parser = _BencodeParser(Uint8List.fromList(bytes));
  final root = parser.parse();
  if (root is! Map<String, Object?>) {
    throw const FormatException('Torrent root must be a dictionary.');
  }
  final info = root['info'];
  if (info is! Map<String, Object?>) {
    throw const FormatException('Torrent info dictionary is missing.');
  }

  final name =
      _bencodedString(info['name.utf-8']) ??
      _bencodedString(info['name']) ??
      'torrent-download';
  final files = <TorrentFileEntry>[];
  final rawFiles = info['files'];
  if (rawFiles is List<Object?>) {
    for (final rawFile in rawFiles) {
      if (rawFile is! Map<String, Object?>) {
        continue;
      }
      final pathParts =
          _bencodedStringList(rawFile['path.utf-8']) ??
          _bencodedStringList(rawFile['path']) ??
          const <String>[];
      final path = pathParts.where((part) => part.trim().isNotEmpty).join('/');
      final length = _bencodedInt(rawFile['length']) ?? 0;
      if (path.trim().isEmpty || length < 0) {
        continue;
      }
      files.add(
        TorrentFileEntry(
          index: files.length,
          path: path,
          name: p.basename(path),
          size: length,
          isStreamable: _isStreamable(path),
        ),
      );
    }
  } else {
    final length = _bencodedInt(info['length']) ?? 0;
    files.add(
      TorrentFileEntry(
        index: 0,
        path: name,
        name: p.basename(name),
        size: length,
        isStreamable: _isStreamable(name),
      ),
    );
  }

  if (files.isEmpty) {
    throw const FormatException('Torrent does not contain downloadable files.');
  }
  return TorrentMetadata(name: name, files: List.unmodifiable(files));
}

String torrentDisplayName(
  TorrentMetadata metadata, {
  required List<int> selectedIndexes,
}) {
  final selected = _selectedFiles(metadata.files, selectedIndexes);
  if (selected.length == 1) {
    return normalizeFileName(selected.single.name);
  }

  final baseName = metadata.name.trim().isEmpty
      ? 'torrent-download'
      : metadata.name.trim();
  if (selected.length == metadata.files.length) {
    return normalizeFileName(baseName);
  }
  return normalizeFileName('$baseName (${selected.length} files)');
}

Future<List<int>?> _readTorrentBytesFromSource(
  String source, {
  http.Client? client,
}) async {
  final normalized = source.trim();
  if (normalized.isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(normalized);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    final ownedClient = client == null;
    final effectiveClient = client ?? http.Client();
    try {
      final response = await effectiveClient.get(uri);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      return response.bodyBytes;
    } finally {
      if (ownedClient) {
        effectiveClient.close();
      }
    }
  }

  final path = uri != null && uri.scheme == 'file'
      ? uri.toFilePath()
      : normalized;
  final file = File(path);
  if (!await file.exists()) {
    return null;
  }
  return file.readAsBytes();
}

TorrentMetadata _metadataFromLibtorrent(String name, List<FileInfo> files) {
  final entries = files
      .map(
        (file) => TorrentFileEntry(
          index: file.index,
          path: file.path.trim().isEmpty ? file.name : file.path,
          name: file.name.trim().isEmpty ? p.basename(file.path) : file.name,
          size: file.size,
          isStreamable: file.isStreamable,
        ),
      )
      .toList(growable: false);
  final metadataName = name.trim().isEmpty ? 'torrent-download' : name.trim();
  return TorrentMetadata(name: metadataName, files: List.unmodifiable(entries));
}

List<int> _validSelectedIndexes(
  List<TorrentFileEntry> files,
  List<int> selectedIndexes,
) {
  final known = files.map((file) => file.index).toSet();
  return selectedIndexes.where(known.contains).toSet().toList(growable: false)
    ..sort();
}

List<TorrentFileEntry> _selectedFiles(
  List<TorrentFileEntry> files,
  List<int> selectedIndexes,
) {
  final selected = selectedIndexes.toSet();
  return files
      .where((file) => selected.contains(file.index))
      .toList(growable: false);
}

String? _bencodedString(Object? value) {
  if (value is Uint8List) {
    return utf8.decode(value, allowMalformed: true);
  }
  if (value is String) {
    return value;
  }
  return null;
}

List<String>? _bencodedStringList(Object? value) {
  if (value is! List<Object?>) {
    return null;
  }
  return value.map(_bencodedString).whereType<String>().toList(growable: false);
}

int? _bencodedInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

bool _isStreamable(String path) {
  final extension = p.extension(path).toLowerCase();
  return const {
    '.mp4',
    '.mkv',
    '.avi',
    '.mov',
    '.m4v',
    '.webm',
    '.ts',
    '.mp3',
    '.m4a',
    '.aac',
    '.flac',
  }.contains(extension);
}

class _BencodeParser {
  _BencodeParser(this.bytes);

  final Uint8List bytes;
  var offset = 0;

  Object? parse() {
    if (offset >= bytes.length) {
      throw const FormatException('Unexpected end of bencode data.');
    }
    final code = bytes[offset];
    if (code == 0x69) {
      return _parseInt();
    }
    if (code == 0x6c) {
      return _parseList();
    }
    if (code == 0x64) {
      return _parseDict();
    }
    if (code >= 0x30 && code <= 0x39) {
      return _parseBytes();
    }
    throw FormatException('Invalid bencode token at $offset.');
  }

  int _parseInt() {
    offset += 1;
    final start = offset;
    while (offset < bytes.length && bytes[offset] != 0x65) {
      offset += 1;
    }
    if (offset >= bytes.length) {
      throw const FormatException('Unterminated bencode integer.');
    }
    final value = utf8.decode(bytes.sublist(start, offset));
    offset += 1;
    return int.parse(value);
  }

  List<Object?> _parseList() {
    offset += 1;
    final list = <Object?>[];
    while (offset < bytes.length && bytes[offset] != 0x65) {
      list.add(parse());
    }
    if (offset >= bytes.length) {
      throw const FormatException('Unterminated bencode list.');
    }
    offset += 1;
    return list;
  }

  Map<String, Object?> _parseDict() {
    offset += 1;
    final map = <String, Object?>{};
    while (offset < bytes.length && bytes[offset] != 0x65) {
      final key = _parseBytes();
      map[utf8.decode(key, allowMalformed: true)] = parse();
    }
    if (offset >= bytes.length) {
      throw const FormatException('Unterminated bencode dictionary.');
    }
    offset += 1;
    return map;
  }

  Uint8List _parseBytes() {
    final start = offset;
    while (offset < bytes.length && bytes[offset] != 0x3a) {
      final code = bytes[offset];
      if (code < 0x30 || code > 0x39) {
        throw FormatException('Invalid bencode byte string at $offset.');
      }
      offset += 1;
    }
    if (offset >= bytes.length) {
      throw const FormatException('Unterminated bencode byte string length.');
    }
    final length = int.parse(utf8.decode(bytes.sublist(start, offset)));
    offset += 1;
    final end = offset + length;
    if (end > bytes.length) {
      throw const FormatException('Bencode byte string exceeds input length.');
    }
    final value = Uint8List.fromList(bytes.sublist(offset, end));
    offset = end;
    return value;
  }
}

const _fallbackMagnetTrackers = [
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://opentracker.i2p.rocks:6969/announce',
  'http://tracker.openbittorrent.com:80/announce',
  'udp://open.stealth.si:80/announce',
  'udp://tracker.openbittorrent.com:6969/announce',
  'udp://tracker.tiny-vps.com:6969/announce',
  'udp://epider.me:6969/announce',
  'udp://movies.zsw.ca:6969/announce',
  'udp://open.free-tracker.ga:6969/announce',
  'udp://p4p.arenabg.com:1337/announce',
  'udp://retracker01-msk-virt.corbina.net:80/announce',
  'udp://tracker.bittor.pw:1337/announce',
  'udp://tracker.dump.cl:6969/announce',
  'udp://tracker.moeking.me:6969/announce',
  'udp://tracker.theoks.net:6969/announce',
  'udp://tracker1.bt.moack.co.kr:80/announce',
  'udp://uploads.gamecoast.net:6969/announce',
  'udp://explodie.org:6969/announce',
  'udp://exodus.desync.com:6969/announce',
  'udp://tracker.torrent.eu.org:451/announce',
  'udp://open.demonii.com:1337/announce',
  'https://tracker.nanoha.org:443/announce',
];
