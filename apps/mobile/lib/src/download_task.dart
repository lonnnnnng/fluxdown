import 'package:uuid/uuid.dart';
import 'package:path/path.dart' as p;

import 'protocol.dart';

enum DownloadState { queued, running, paused, finished, failed }

class TorrentFileEntry {
  const TorrentFileEntry({
    required this.index,
    required this.path,
    required this.name,
    required this.size,
    this.isStreamable = false,
  });

  factory TorrentFileEntry.fromJson(Map<String, Object?> json) {
    return TorrentFileEntry(
      index: json['index'] as int? ?? 0,
      path: json['path'] as String? ?? '',
      name: json['name'] as String? ?? '',
      size: json['size'] as int? ?? 0,
      isStreamable: json['isStreamable'] as bool? ?? false,
    );
  }

  final int index;
  final String path;
  final String name;
  final int size;
  final bool isStreamable;

  Map<String, Object?> toJson() {
    return {
      'index': index,
      'path': path,
      'name': name,
      'size': size,
      'isStreamable': isStreamable,
    };
  }
}

class DownloadTask {
  DownloadTask({
    required this.id,
    required this.source,
    required this.outputFolder,
    required this.fileName,
    required this.protocol,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
    this.downloadedBytes = 0,
    this.totalBytes,
    this.error,
    this.startedAt,
    this.pausedAt,
    this.finishedAt,
    this.currentSpeedBytesPerSecond = 0,
    this.torrentName,
    this.torrentFiles = const [],
    this.selectedTorrentFileIndexes,
  });

  factory DownloadTask.create({
    required String source,
    required String outputFolder,
    String? fileName,
    String? torrentName,
    List<TorrentFileEntry> torrentFiles = const [],
    List<int>? selectedTorrentFileIndexes,
  }) {
    final now = DateTime.now().toUtc();
    final protocol = detectProtocol(source);
    return DownloadTask(
      id: const Uuid().v4(),
      source: source.trim(),
      outputFolder: outputFolder.trim(),
      fileName: normalizeFileName(
        fileName?.trim().isNotEmpty == true
            ? fileName!.trim()
            : suggestedFileName(source),
      ),
      protocol: protocol,
      state: DownloadState.queued,
      createdAt: now,
      updatedAt: now,
      torrentName: torrentName,
      torrentFiles: List.unmodifiable(torrentFiles),
      selectedTorrentFileIndexes: selectedTorrentFileIndexes == null
          ? null
          : List.unmodifiable(selectedTorrentFileIndexes),
    );
  }

  factory DownloadTask.fromJson(Map<String, Object?> json) {
    final state = DownloadState.values.byName(json['state'] as String);
    final updatedAt = DateTime.parse(json['updatedAt'] as String);
    final pausedAt =
        _dateTimeFromJson(json['pausedAt']) ??
        (state == DownloadState.paused ? updatedAt : null);
    return DownloadTask(
      id: json['id'] as String,
      source: json['source'] as String,
      outputFolder: json['outputFolder'] as String,
      fileName: json['fileName'] as String,
      protocol: json['protocol'] as String,
      state: state,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: updatedAt,
      downloadedBytes: json['downloadedBytes'] as int? ?? 0,
      totalBytes: json['totalBytes'] as int?,
      error: json['error'] as String?,
      startedAt: _dateTimeFromJson(json['startedAt']),
      pausedAt: pausedAt,
      finishedAt: _dateTimeFromJson(json['finishedAt']),
      currentSpeedBytesPerSecond:
          json['currentSpeedBytesPerSecond'] as int? ?? 0,
      torrentName: json['torrentName'] as String?,
      torrentFiles:
          (json['torrentFiles'] as List<Object?>?)
              ?.whereType<Map>()
              .map(
                (item) =>
                    TorrentFileEntry.fromJson(Map<String, Object?>.from(item)),
              )
              .toList(growable: false) ??
          const [],
      selectedTorrentFileIndexes:
          (json['selectedTorrentFileIndexes'] as List<Object?>?)
              ?.map(_intFromJson)
              .whereType<int>()
              .toList(growable: false),
    );
  }

  final String id;
  final String source;
  final String outputFolder;
  final String fileName;
  final String protocol;
  final DownloadState state;
  final int downloadedBytes;
  final int? totalBytes;
  final String? error;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? startedAt;
  final DateTime? pausedAt;
  final DateTime? finishedAt;
  final int currentSpeedBytesPerSecond;
  final String? torrentName;
  final List<TorrentFileEntry> torrentFiles;
  final List<int>? selectedTorrentFileIndexes;

  double? get progress {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (downloadedBytes / total).clamp(0, 1).toDouble();
  }

  bool get canRun =>
      state == DownloadState.queued ||
      state == DownloadState.paused ||
      state == DownloadState.failed;
  bool get canPause => state == DownloadState.running;
  Duration? get elapsed {
    final start = startedAt;
    if (start == null) return null;
    final end =
        finishedAt ??
        (state == DownloadState.paused ? pausedAt : null) ??
        DateTime.now().toUtc();
    if (end.isBefore(start)) return Duration.zero;
    return end.difference(start);
  }

  int get averageSpeedBytesPerSecond {
    final elapsedTime = elapsed;
    if (elapsedTime == null ||
        elapsedTime.inMilliseconds <= 0 ||
        downloadedBytes <= 0) {
      return 0;
    }
    return (downloadedBytes * 1000 / elapsedTime.inMilliseconds).round();
  }

  bool get isTorrentLike => protocol == 'torrent' || protocol == 'magnet';

  List<int> get effectiveSelectedTorrentFileIndexes {
    final selected = selectedTorrentFileIndexes;
    if (selected != null && selected.isNotEmpty) {
      return List.unmodifiable(selected);
    }
    return List.unmodifiable(torrentFiles.map((file) => file.index));
  }

  List<TorrentFileEntry> get selectedTorrentFiles {
    if (torrentFiles.isEmpty) return const [];
    final selected = effectiveSelectedTorrentFileIndexes.toSet();
    return torrentFiles
        .where((file) => selected.contains(file.index))
        .toList(growable: false);
  }

  int? get selectedTorrentTotalBytes {
    final files = selectedTorrentFiles;
    if (files.isEmpty) return null;
    return files.fold<int>(0, (total, file) => total + file.size);
  }

  bool get isBuiltInMobile =>
      protocol == 'http' ||
      protocol == 'https' ||
      protocol == 'webdav' ||
      protocol == 'webdavs' ||
      protocol == 'ftp' ||
      protocol == 'ftps' ||
      protocol == 'sftp' ||
      protocol == 'ipfs' ||
      protocol == 'torrent' ||
      protocol == 'magnet' ||
      protocol == 'smb' ||
      protocol == 'ed2k' ||
      protocol == 'm3u8';

  DownloadTask copyWith({
    String? source,
    String? outputFolder,
    String? fileName,
    String? protocol,
    DownloadState? state,
    int? downloadedBytes,
    int? totalBytes,
    bool clearTotalBytes = false,
    String? error,
    bool clearError = false,
    DateTime? updatedAt,
    DateTime? startedAt,
    bool clearStartedAt = false,
    DateTime? pausedAt,
    bool clearPausedAt = false,
    DateTime? finishedAt,
    bool clearFinishedAt = false,
    int? currentSpeedBytesPerSecond,
    String? torrentName,
    List<TorrentFileEntry>? torrentFiles,
    List<int>? selectedTorrentFileIndexes,
    bool clearSelectedTorrentFileIndexes = false,
    bool clearTorrentMetadata = false,
  }) {
    return DownloadTask(
      id: id,
      source: source ?? this.source,
      outputFolder: outputFolder ?? this.outputFolder,
      fileName: fileName ?? this.fileName,
      protocol: protocol ?? this.protocol,
      state: state ?? this.state,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: clearTotalBytes ? null : totalBytes ?? this.totalBytes,
      error: clearError ? null : error ?? this.error,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now().toUtc(),
      startedAt: clearStartedAt ? null : startedAt ?? this.startedAt,
      pausedAt: clearPausedAt ? null : pausedAt ?? this.pausedAt,
      finishedAt: clearFinishedAt ? null : finishedAt ?? this.finishedAt,
      currentSpeedBytesPerSecond:
          currentSpeedBytesPerSecond ?? this.currentSpeedBytesPerSecond,
      torrentName: clearTorrentMetadata
          ? null
          : torrentName ?? this.torrentName,
      torrentFiles: clearTorrentMetadata
          ? const []
          : List.unmodifiable(torrentFiles ?? this.torrentFiles),
      selectedTorrentFileIndexes:
          clearTorrentMetadata || clearSelectedTorrentFileIndexes
          ? null
          : selectedTorrentFileIndexes ?? this.selectedTorrentFileIndexes,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'source': source,
      'outputFolder': outputFolder,
      'fileName': fileName,
      'protocol': protocol,
      'state': state.name,
      'downloadedBytes': downloadedBytes,
      'totalBytes': totalBytes,
      'error': error,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'startedAt': startedAt?.toIso8601String(),
      'pausedAt': pausedAt?.toIso8601String(),
      'finishedAt': finishedAt?.toIso8601String(),
      'currentSpeedBytesPerSecond': currentSpeedBytesPerSecond,
      'torrentName': torrentName,
      'torrentFiles': torrentFiles.map((file) => file.toJson()).toList(),
      'selectedTorrentFileIndexes': selectedTorrentFileIndexes,
    };
  }
}

int? _intFromJson(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  return DateTime.parse(value);
}

String suggestedFileName(String source) {
  final protocol = detectProtocol(source);
  final uri = Uri.tryParse(source.trim());
  final segment = uri?.pathSegments
      .where((part) => part.trim().isNotEmpty)
      .lastOrNull;

  if (protocol == 'm3u8') {
    final baseName = segment == null || segment.trim().isEmpty
        ? 'playlist'
        : p.basenameWithoutExtension(Uri.decodeComponent(segment));
    return '$baseName.mp4';
  }

  if (segment != null && segment.trim().isNotEmpty) {
    return Uri.decodeComponent(segment);
  }

  return switch (protocol) {
    'm3u8' => 'playlist.mp4',
    'torrent' => 'download.torrent',
    'magnet' => 'magnet-download',
    'ed2k' => 'ed2k-download',
    _ => 'download.bin',
  };
}

String normalizeFileName(String value) {
  final normalized = value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  return normalized.isEmpty ? 'download.bin' : normalized;
}

String formatBytes(int? value) {
  if (value == null) return '--';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = value.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit += 1;
  }
  final precision = unit == 0 ? 0 : 1;
  return '${size.toStringAsFixed(precision)} ${units[unit]}';
}
