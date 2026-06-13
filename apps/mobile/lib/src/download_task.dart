import 'package:uuid/uuid.dart';

import 'protocol.dart';

enum DownloadState { queued, running, paused, finished, failed }

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
  });

  factory DownloadTask.create({
    required String source,
    required String outputFolder,
    String? fileName,
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
    };
  }
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  return DateTime.parse(value);
}

String suggestedFileName(String source) {
  final uri = Uri.tryParse(source.trim());
  final segment = uri?.pathSegments
      .where((part) => part.trim().isNotEmpty)
      .lastOrNull;
  if (segment != null && segment.trim().isNotEmpty) {
    return Uri.decodeComponent(segment);
  }

  final protocol = detectProtocol(source);
  return switch (protocol) {
    'm3u8' => 'playlist.ts',
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
