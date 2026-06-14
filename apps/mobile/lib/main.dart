import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/download_controller.dart';
import 'src/download_task.dart';
import 'src/mobile_torrent.dart';
import 'src/protocol.dart';

void main() {
  runApp(const FluxDownMobileApp());
}

const _outputFolderPreferenceKey = 'fluxdown.outputFolder';
const _queueConcurrencyPreferenceKey = 'fluxdown.queueConcurrency';
const _downloadThreadCountPreferenceKey = 'fluxdown.downloadThreadCount';
const _retryAttemptsPreferenceKey = 'fluxdown.retryAttempts';
const _speedLimitKbpsPreferenceKey = 'fluxdown.speedLimitKbps';
const _defaultQueueConcurrency = 1;
const _maxQueueConcurrency = 30;
const _defaultDownloadThreadCount = 8;
const _maxDownloadThreadCount = 32;
const _defaultRetryAttempts = 1;
const _maxRetryAttempts = 10;
const _storageChannel = MethodChannel('dev.fluxdown.mobile/storage');

enum AppLanguage { zh, en }

enum QueueFilter { all, queued, running, finished, failed }

class StorageStats {
  const StorageStats({required this.totalBytes, required this.freeBytes});

  final int totalBytes;
  final int freeBytes;

  int get usedBytes => (totalBytes - freeBytes).clamp(0, totalBytes).toInt();
}

Future<StorageStats?> loadStorageStats(String path) async {
  try {
    final result = await _storageChannel.invokeMapMethod<String, dynamic>(
      'getStorageStats',
      {'path': path},
    );
    if (result == null) return null;
    final totalBytes = _readInt(result['totalBytes']);
    final freeBytes = _readInt(result['freeBytes']);
    if (totalBytes == null || freeBytes == null || totalBytes <= 0) {
      return null;
    }
    return StorageStats(
      totalBytes: totalBytes,
      freeBytes: freeBytes.clamp(0, totalBytes).toInt(),
    );
  } catch (_) {
    return null;
  }
}

int? _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

class AppStrings {
  const AppStrings._(this.language);

  final AppLanguage language;

  static const zh = AppStrings._(AppLanguage.zh);
  static const en = AppStrings._(AppLanguage.en);

  String get languageLabel => language == AppLanguage.zh ? '语言' : 'Language';
  String get chinese => '中文';
  String get english => 'English';
  String get planned => language == AppLanguage.zh ? '规划中' : 'Planned';
  String get tabNew => language == AppLanguage.zh ? '新建' : 'New';
  String get tabQueue => language == AppLanguage.zh ? '队列' : 'Queue';
  String get tabProtocols => language == AppLanguage.zh ? '协议' : 'Protocols';
  String get tabSettings => language == AppLanguage.zh ? '设置' : 'Settings';
  String get overview => language == AppLanguage.zh ? '概览' : 'Overview';
  String get newDownload =>
      language == AppLanguage.zh ? '新建下载' : 'New download';
  String get newTask => language == AppLanguage.zh ? '新建任务' : 'New task';
  String get createTask => language == AppLanguage.zh ? '创建任务' : 'Create task';
  String get createFromClipboard =>
      language == AppLanguage.zh ? '从剪切板新建' : 'Create from clipboard';
  String get clipboardEmpty => language == AppLanguage.zh
      ? '剪切板没有可用下载链接。'
      : 'No usable link in clipboard.';
  String get scanQr => language == AppLanguage.zh ? '扫码' : 'Scan';
  String get scanQrTitle =>
      language == AppLanguage.zh ? '扫描下载码' : 'Scan download QR';
  String get scanQrPrompt =>
      language == AppLanguage.zh ? '将二维码放入取景框' : 'Place the QR code in frame';
  String get close => language == AppLanguage.zh ? '关闭' : 'Close';
  String get source => language == AppLanguage.zh ? '下载源' : 'Source';
  String get outputFolder =>
      language == AppLanguage.zh ? '下载保存位置' : 'Download location';
  String get fileName => language == AppLanguage.zh ? '文件名' : 'File name';
  String get fileNameOptional =>
      language == AppLanguage.zh ? '文件名（可选）' : 'File name (optional)';
  String get fileNameAutoHint => language == AppLanguage.zh
      ? '留空则按下载资源自动命名'
      : 'Leave empty to name it from the download resource';
  String get saveAsFileName =>
      language == AppLanguage.zh ? '另存为文件名' : 'Save as file name';
  String get savePath => language == AppLanguage.zh ? '保存路径' : 'Save path';
  String get selectTorrentFiles =>
      language == AppLanguage.zh ? '选择种子内容' : 'Select torrent files';
  String get selectTorrentFilesHint => language == AppLanguage.zh
      ? '这个种子包含多个文件，勾选本次要下载的内容。'
      : 'This torrent contains multiple files. Choose what to download.';
  String get selectAll => language == AppLanguage.zh ? '全选' : 'Select all';
  String get selectNone => language == AppLanguage.zh ? '全不选' : 'Select none';
  String get confirmSelection =>
      language == AppLanguage.zh ? '确认选择' : 'Confirm';
  String torrentSelectedCount(int count) =>
      language == AppLanguage.zh ? '已选择 $count 项' : '$count selected';
  String get torrentSelectionRequired =>
      language == AppLanguage.zh ? '请至少选择一个文件。' : 'Select at least one file.';
  String get torrentMetadataLoading => language == AppLanguage.zh
      ? '正在读取种子文件列表...'
      : 'Reading torrent file list...';
  String get torrentMetadataFailed => language == AppLanguage.zh
      ? '无法读取这个种子的文件列表。'
      : 'Could not read this torrent file list.';
  String get storageTotal =>
      language == AppLanguage.zh ? '总磁盘容量' : 'Total storage';
  String get storageUsed =>
      language == AppLanguage.zh ? '已用磁盘容量' : 'Used storage';
  String get storageFree =>
      language == AppLanguage.zh ? '剩余磁盘容量' : 'Free storage';
  String get storageLoading =>
      language == AppLanguage.zh ? '正在读取存储容量...' : 'Reading storage...';
  String get storageUnavailable => language == AppLanguage.zh
      ? '无法读取这个路径的存储容量。'
      : 'Storage size is unavailable for this path.';
  String get detected => language == AppLanguage.zh ? '识别结果' : 'Detected';
  String get protocolSupport =>
      language == AppLanguage.zh ? '协议能力' : 'Protocols';
  String get backend => language == AppLanguage.zh ? '后端' : 'Backend';
  String get add => language == AppLanguage.zh ? '添加' : 'Add';
  String get queue => language == AppLanguage.zh ? '队列' : 'Queue';
  String get allProtocols =>
      language == AppLanguage.zh ? '全部协议' : 'All protocols';
  String get currentSource =>
      language == AppLanguage.zh ? '当前下载源' : 'Current source';
  String get currentDetection =>
      language == AppLanguage.zh ? '当前检测' : 'Current detection';
  String get protocolList =>
      language == AppLanguage.zh ? '支持列表' : 'Supported list';
  String get protocolListHint => language == AppLanguage.zh
      ? '移动端后端与能力'
      : 'Mobile backends and capabilities';
  String get concurrency => language == AppLanguage.zh ? '并发' : 'Parallel';
  String get settings => language == AppLanguage.zh ? '设置' : 'Settings';
  String get downloadSettings =>
      language == AppLanguage.zh ? '下载设置' : 'Download settings';
  String get newTaskSettings =>
      language == AppLanguage.zh ? '新建任务' : 'New tasks';
  String get chooseFolder =>
      language == AppLanguage.zh ? '选择目录' : 'Choose folder';
  String get folderSelectionCancelled =>
      language == AppLanguage.zh ? '未选择目录。' : 'No folder selected.';
  String get folderSelected =>
      language == AppLanguage.zh ? '已更新下载目录。' : 'Download folder updated.';
  String get folderSelectionFailed => language == AppLanguage.zh
      ? '无法选择这个目录。'
      : 'Could not select that folder.';
  String get concurrencySetting =>
      language == AppLanguage.zh ? '并发下载数' : 'Concurrent downloads';
  String get concurrencySettingHint => language == AppLanguage.zh
      ? '同时下载 1-30，默认 1，超出排队'
      : '1-30 active tasks, default 1; extras wait';
  String get downloadThreadsSetting =>
      language == AppLanguage.zh ? '下载线程数' : 'Download threads';
  String get downloadThreadsHint => language == AppLanguage.zh
      ? '单任务线程 1-32，默认 8'
      : '1-32 threads per task, default 8';
  String get retryAttemptsSetting =>
      language == AppLanguage.zh ? '自动重试数' : 'Automatic retries';
  String get retryAttemptsHint => language == AppLanguage.zh
      ? '失败重试 0-10，默认 1，0 不重试'
      : '0-10 retries, default 1; 0 disables';
  String get speedLimitSetting =>
      language == AppLanguage.zh ? '最大下载网速' : 'Max download speed';
  String get speedLimitHint =>
      language == AppLanguage.zh ? 'MB/s，留空不限速' : 'MB/s, blank means unlimited';
  String retryAttemptsValue(int count) {
    if (count == 0) {
      return language == AppLanguage.zh ? '关闭' : 'Off';
    }
    return language == AppLanguage.zh ? '$count 次' : '$count times';
  }

  String speedLimitValue(int kbps) {
    if (kbps <= 0) {
      return language == AppLanguage.zh ? '不限速' : 'Unlimited';
    }
    if (kbps < 1024) {
      return '$kbps KB/s';
    }
    final mbps = kbps / 1024;
    final value = mbps == mbps.roundToDouble()
        ? mbps.toStringAsFixed(0)
        : mbps.toStringAsFixed(1);
    return '$value MB/s';
  }

  String get autoStartAddedTasks =>
      language == AppLanguage.zh ? '添加后自动开始' : 'Auto-start after adding';
  String get autoStartAddedTasksHint => language == AppLanguage.zh
      ? '新任务入队后立即启动，适合单个链接快速下载。'
      : 'Starts a new task immediately after it is added.';
  String taskCount(int count) =>
      language == AppLanguage.zh ? '$count 个任务' : '$count tasks';
  String get queueAll => language == AppLanguage.zh ? '全部' : 'All';
  String get queueQueued => language == AppLanguage.zh ? '排队中' : 'Queued';
  String get queueCompleted => language == AppLanguage.zh ? '已完成' : 'Done';
  String get queueDownloading =>
      language == AppLanguage.zh ? '下载中' : 'Downloading';
  String get queueFailed => language == AppLanguage.zh ? '失败' : 'Failed';
  String get noQueuedTasks =>
      language == AppLanguage.zh ? '等待添加任务' : 'Waiting for tasks';
  String get noQueuedTasksHint => language == AppLanguage.zh
      ? '添加下载源后会出现在这里。'
      : 'Added downloads will appear here.';
  String get running => language == AppLanguage.zh ? '运行中' : 'Running';
  String get runQueue => language == AppLanguage.zh ? '运行队列' : 'Run queue';
  String get remove => language == AppLanguage.zh ? '删除' : 'Remove';
  String get pause => language == AppLanguage.zh ? '暂停' : 'Pause';
  String get resume => language == AppLanguage.zh ? '继续' : 'Resume';
  String get start => language == AppLanguage.zh ? '开始' : 'Start';
  String get realTimeProgress =>
      language == AppLanguage.zh ? '实时进度' : 'Live progress';
  String get realTimeSpeed =>
      language == AppLanguage.zh ? '实时速度' : 'Live speed';
  String get startTime => language == AppLanguage.zh ? '开始时间' : 'Start time';
  String get endTime => language == AppLanguage.zh ? '结束时间' : 'End time';
  String get averageSpeed =>
      language == AppLanguage.zh ? '平均速度' : 'Average speed';
  String get errorMessage =>
      language == AppLanguage.zh ? '错误信息' : 'Error message';
  String get totalElapsed => language == AppLanguage.zh ? '共计耗时' : 'Elapsed';
  String get taskActions =>
      language == AppLanguage.zh ? '任务操作' : 'Task actions';
  String get copyDownloadLink =>
      language == AppLanguage.zh ? '复制下载链接' : 'Copy download link';
  String get copiedDownloadLink =>
      language == AppLanguage.zh ? '已复制下载链接。' : 'Download link copied.';
  String get properties => language == AppLanguage.zh ? '属性' : 'Properties';
  String get openFile => language == AppLanguage.zh ? '打开' : 'Open';
  String get shareFile => language == AppLanguage.zh ? '分享' : 'Share';
  String get redownload => language == AppLanguage.zh ? '重新下载' : 'Redownload';
  String get fileNotFound =>
      language == AppLanguage.zh ? '未找到下载文件。' : 'Downloaded file not found.';
  String get openFileFailed =>
      language == AppLanguage.zh ? '无法打开文件。' : 'Could not open file.';
  String get shareFileFailed =>
      language == AppLanguage.zh ? '无法分享文件。' : 'Could not share file.';
  String get sourceLink => language == AppLanguage.zh ? '下载链接' : 'Source';
  String get outputPath => language == AppLanguage.zh ? '文件路径' : 'File path';
  String get fileSize => language == AppLanguage.zh ? '文件大小' : 'File size';
  String get protocol => language == AppLanguage.zh ? '协议' : 'Protocol';
  String get sourceRequired =>
      language == AppLanguage.zh ? '下载源不能为空。' : 'Source is required.';
  String get outputFolderSettingRequired => language == AppLanguage.zh
      ? '请先在设置页选择下载目录。'
      : 'Choose a download folder in Settings first.';
  String queueComplete(int finished, int failed) => language == AppLanguage.zh
      ? '队列完成：$finished 个完成，$failed 个失败。'
      : 'Queue complete: $finished finished, $failed failed.';

  String detectedLine(String protocol, String backend) =>
      language == AppLanguage.zh
      ? '$detected：${protocolLabel(protocol)} · $backend'
      : '$detected: ${protocolLabel(protocol)} · $backend';

  String backendLabel(String protocol) {
    if (protocol == 'unknown') return planned;
    if (protocol == 'ed2k') {
      return language == AppLanguage.zh ? '移动端移交' : 'Mobile handoff';
    }
    return language == AppLanguage.zh ? '移动端内建' : 'Built-in mobile';
  }

  String supportNote(String protocol) {
    if (protocol == 'http' || protocol == 'https') {
      return language == AppLanguage.zh
          ? '原生 HTTP 下载器，支持进度、暂停和 Range 续传。'
          : 'Native HTTP downloader with progress, pause, and Range resume.';
    }

    if (protocol == 'webdav' || protocol == 'webdavs') {
      return language == AppLanguage.zh
          ? '通过 HTTP/WebDAVS 执行原生 WebDAV 下载，支持进度、暂停和 Range 续传。'
          : 'Native WebDAV downloader over HTTP/WebDAVS with progress, pause, and Range resume.';
    }

    if (protocol == 'ipfs') {
      return language == AppLanguage.zh
          ? '通过 IPFS 网关下载，复用 HTTP 进度和续传能力。'
          : 'Native IPFS gateway downloader with HTTP progress and resume.';
    }

    if (protocol == 'm3u8') {
      return language == AppLanguage.zh
          ? '原生 VOD HLS 下载器，支持主播放列表选择和 AES-128 分片解密。'
          : 'Native VOD HLS downloader with master playlist selection and AES-128 segment decryption.';
    }

    if (protocol == 'ftp' || protocol == 'ftps') {
      return language == AppLanguage.zh
          ? '原生 FTP/FTPS 下载器，支持被动模式、进度、暂停和 REST 续传。'
          : 'Native FTP/FTPS downloader with passive mode, progress, pause, and REST resume.';
    }

    if (protocol == 'sftp') {
      return language == AppLanguage.zh
          ? '原生 SFTP 下载器，支持密码认证、进度、暂停和偏移续传。'
          : 'Native SFTP downloader with password authentication, progress, pause, and offset resume.';
    }

    if (protocol == 'torrent' || protocol == 'magnet') {
      return language == AppLanguage.zh
          ? '通过原生 libtorrent 下载 .torrent 文件和磁力链接。'
          : 'Native libtorrent downloader for .torrent files and magnet links.';
    }

    if (protocol == 'ed2k') {
      return language == AppLanguage.zh
          ? '将 ed2k 链接移交给已安装的 eMule/aMule 兼容 App。'
          : 'Hands ed2k links to an installed eMule/aMule-compatible app.';
    }

    if (protocol == 'smb') {
      return language == AppLanguage.zh
          ? '原生 SMB2/3 文件下载后端，支持进度和取消。'
          : 'Native SMB2/3 file download backend with progress and cancellation.';
    }

    return language == AppLanguage.zh
        ? '当前下载源还没有可用后端。'
        : 'No backend has been configured for this source yet.';
  }

  String stateLabel(DownloadState state) {
    return switch (state) {
      DownloadState.queued => language == AppLanguage.zh ? '排队中' : 'queued',
      DownloadState.running => language == AppLanguage.zh ? '运行中' : 'running',
      DownloadState.paused => language == AppLanguage.zh ? '已暂停' : 'paused',
      DownloadState.finished => language == AppLanguage.zh ? '已完成' : 'finished',
      DownloadState.failed => language == AppLanguage.zh ? '失败' : 'failed',
    };
  }
}

IconData _protocolIcon(String protocol) {
  return switch (protocol.toLowerCase()) {
    'http' || 'https' => Icons.public,
    'webdav' || 'webdavs' => Icons.cloud_queue,
    'ftp' || 'ftps' || 'sftp' => Icons.dns_outlined,
    'torrent' || 'magnet' => Icons.hub_outlined,
    'ed2k' => Icons.swap_horiz,
    'm3u8' => Icons.movie_filter_outlined,
    'smb' => Icons.storage_outlined,
    'ipfs' => Icons.hexagon_outlined,
    _ => Icons.file_download_outlined,
  };
}

int clampQueueConcurrency(int value) =>
    value.clamp(1, _maxQueueConcurrency).toInt();

int clampDownloadThreadCount(int value) =>
    value.clamp(1, _maxDownloadThreadCount).toInt();

int clampRetryAttempts(int value) => value.clamp(0, _maxRetryAttempts).toInt();

int? parseBoundedInteger(String value, {required int min, required int max}) {
  final parsed = int.tryParse(value.trim());
  if (parsed == null) return null;
  return parsed.clamp(min, max).toInt();
}

int? parseSpeedLimitInputKbps(String value) {
  final normalized = value.trim().replaceAll(',', '.');
  if (normalized.isEmpty) return 0;
  final mbps = double.tryParse(normalized);
  if (mbps == null || mbps < 0) return null;
  if (mbps == 0) return 0;
  return (mbps * 1024).round().clamp(1, 1 << 53).toInt();
}

String speedLimitInputValue(int kbps) {
  if (kbps <= 0) return '';
  final mbps = kbps / 1024;
  return mbps == mbps.roundToDouble()
      ? mbps.toStringAsFixed(0)
      : mbps.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
}

String _formatDateTime(DateTime? value) {
  if (value == null) return '--';
  final local = value.toLocal();
  final now = DateTime.now();
  final time =
      '${_twoDigits(local.hour)}:${_twoDigits(local.minute)}:${_twoDigits(local.second)}';
  if (local.year == now.year &&
      local.month == now.month &&
      local.day == now.day) {
    return time;
  }
  if (local.year == now.year) {
    return '${_twoDigits(local.month)}-${_twoDigits(local.day)} $time';
  }
  return '${local.year}-${_twoDigits(local.month)}-${_twoDigits(local.day)} $time';
}

String _formatDuration(Duration? value) {
  if (value == null) return '--';
  final duration = value.isNegative ? Duration.zero : value;
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  if (hours > 0) {
    return '${_twoDigits(hours)}:${_twoDigits(minutes)}:${_twoDigits(seconds)}';
  }
  return '${_twoDigits(minutes)}:${_twoDigits(seconds)}';
}

String _formatSpeed(int bytesPerSecond) {
  if (bytesPerSecond <= 0) return '--';
  return '${formatBytes(bytesPerSecond)}/s';
}

int _visibleSpeedBytesPerSecond(DownloadTask task) {
  if (task.state == DownloadState.running) {
    return task.currentSpeedBytesPerSecond;
  }
  return task.averageSpeedBytesPerSecond;
}

String _speedTooltip(AppStrings strings, DownloadTask task) {
  return task.state == DownloadState.running
      ? strings.realTimeSpeed
      : strings.averageSpeed;
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

String protocolLabel(String protocol) {
  if (protocol == 'unknown') return 'Unknown';
  return protocol.toUpperCase();
}

class FluxDownMobileApp extends StatefulWidget {
  const FluxDownMobileApp({super.key});

  @override
  State<FluxDownMobileApp> createState() => _FluxDownMobileAppState();
}

class _FluxDownMobileAppState extends State<FluxDownMobileApp> {
  var language = AppLanguage.zh;

  @override
  Widget build(BuildContext context) {
    final strings = language == AppLanguage.zh ? AppStrings.zh : AppStrings.en;

    return MaterialApp(
      title: 'FluxDown',
      locale: language == AppLanguage.zh
          ? const Locale('zh', 'CN')
          : const Locale('en'),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff147c7f),
          primary: const Color(0xff147c7f),
          secondary: const Color(0xffc46332),
          tertiary: const Color(0xff4068a7),
          surface: const Color(0xfff7f5ef),
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xfff7f5ef),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: const Color(0xfffffcf7),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0x1f1c2b2a)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xffd7d0c2)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xffd7d0c2)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xff147c7f), width: 1.6),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: const Color(0xfffffcf7),
          elevation: 0,
          indicatorShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w900
                  : FontWeight.w700,
            ),
          ),
        ),
      ),
      home: DownloadHome(
        strings: strings,
        language: language,
        onLanguageChanged: (value) {
          setState(() {
            language = value;
          });
        },
      ),
    );
  }
}

class DownloadHome extends StatefulWidget {
  const DownloadHome({
    required this.strings,
    required this.language,
    required this.onLanguageChanged,
    super.key,
  });

  final AppStrings strings;
  final AppLanguage language;
  final ValueChanged<AppLanguage> onLanguageChanged;

  @override
  State<DownloadHome> createState() => _DownloadHomeState();
}

class _DownloadHomeState extends State<DownloadHome> {
  final outputController = TextEditingController();
  late final DownloadController controller;
  var loading = true;
  var queueConcurrency = _defaultQueueConcurrency;
  var downloadThreadCount = _defaultDownloadThreadCount;
  var retryAttempts = _defaultRetryAttempts;
  var speedLimitKbps = 0;
  var queueFilter = QueueFilter.all;

  AppStrings get strings => widget.strings;

  @override
  void initState() {
    super.initState();
    controller = DownloadController(onChanged: _refresh);
    _load();
  }

  @override
  void dispose() {
    outputController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final documents = await getApplicationDocumentsDirectory();
    final preferences = await SharedPreferences.getInstance();
    outputController.text =
        preferences.getString(_outputFolderPreferenceKey) ??
        '${documents.path}/downloads';
    final savedConcurrency = preferences.getInt(_queueConcurrencyPreferenceKey);
    final savedThreadCount = preferences.getInt(
      _downloadThreadCountPreferenceKey,
    );
    final savedRetryAttempts = preferences.getInt(_retryAttemptsPreferenceKey);
    final savedSpeedLimit = preferences.getInt(_speedLimitKbpsPreferenceKey);
    await controller.load();
    if (!mounted) return;
    setState(() {
      queueConcurrency = savedConcurrency == null
          ? _defaultQueueConcurrency
          : clampQueueConcurrency(savedConcurrency);
      downloadThreadCount = savedThreadCount == null
          ? _defaultDownloadThreadCount
          : clampDownloadThreadCount(savedThreadCount);
      retryAttempts = savedRetryAttempts == null
          ? _defaultRetryAttempts
          : clampRetryAttempts(savedRetryAttempts);
      speedLimitKbps = savedSpeedLimit == null
          ? 0
          : savedSpeedLimit.clamp(0, 1 << 53).toInt();
      loading = false;
    });
    _scheduleQueue();
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<bool> createTask({
    required String source,
    required String outputFolder,
    String? fileName,
    String? torrentName,
    List<TorrentFileEntry> torrentFiles = const [],
    List<int>? selectedTorrentFileIndexes,
  }) async {
    final normalizedSource = source.trim();
    final output = outputFolder.trim();
    if (normalizedSource.isEmpty) {
      _showSnack(strings.sourceRequired);
      return false;
    }
    if (output.isEmpty) {
      _showSnack(strings.outputFolderSettingRequired);
      return false;
    }

    await controller.add(
      source: normalizedSource,
      outputFolder: output,
      fileName: fileName,
      torrentName: torrentName,
      torrentFiles: torrentFiles,
      selectedTorrentFileIndexes: selectedTorrentFileIndexes,
    );
    setState(() {
      queueFilter = QueueFilter.all;
    });
    _scheduleQueue();
    return true;
  }

  void _scheduleQueue() {
    unawaited(
      controller.runQueued(
        concurrency: queueConcurrency,
        maxRetries: retryAttempts,
        speedLimitKbps: speedLimitKbps,
        threadCount: downloadThreadCount,
        onTorrentMetadata: selectTorrentFiles,
      ),
    );
  }

  void showNewTaskDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => NewTaskDialog(
        strings: strings,
        defaultOutputFolder: outputController.text,
        onPickOutputFolder: pickOutputFolderForNewTask,
        onCreate: createTask,
      ),
    );
  }

  Future<String?> pickOutputFolderForNewTask() async {
    try {
      return await FilePicker.getDirectoryPath(
        dialogTitle: strings.chooseFolder,
      );
    } catch (_) {
      if (mounted) {
        _showSnack(strings.folderSelectionFailed);
      }
      return null;
    }
  }

  Future<void> pickOutputFolder() async {
    try {
      final selected = await FilePicker.getDirectoryPath(
        dialogTitle: strings.chooseFolder,
      );
      if (!mounted) return;
      if (selected == null || selected.trim().isEmpty) {
        _showSnack(strings.folderSelectionCancelled);
        return;
      }
      final normalized = selected.trim();
      outputController.text = normalized;
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_outputFolderPreferenceKey, normalized);
      _showSnack(strings.folderSelected);
    } catch (_) {
      if (mounted) {
        _showSnack(strings.folderSelectionFailed);
      }
    }
  }

  Future<void> setQueueConcurrency(int value) async {
    final normalized = clampQueueConcurrency(value);
    setState(() {
      queueConcurrency = normalized;
    });
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(_queueConcurrencyPreferenceKey, normalized);
    _scheduleQueue();
  }

  Future<void> setDownloadThreadCount(int value) async {
    final normalized = clampDownloadThreadCount(value);
    setState(() {
      downloadThreadCount = normalized;
    });
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(_downloadThreadCountPreferenceKey, normalized);
  }

  Future<void> setRetryAttempts(int value) async {
    final normalized = clampRetryAttempts(value);
    setState(() {
      retryAttempts = normalized;
    });
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(_retryAttemptsPreferenceKey, normalized);
  }

  Future<void> setSpeedLimitKbps(int value) async {
    final normalized = value.clamp(0, 1 << 53).toInt();
    setState(() {
      speedLimitKbps = normalized;
    });
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(_speedLimitKbpsPreferenceKey, normalized);
  }

  Future<void> startTask(String id) async {
    await controller.start(
      id,
      maxRetries: retryAttempts,
      speedLimitKbps: speedLimitKbps,
      threadCount: downloadThreadCount,
      onTorrentMetadata: selectTorrentFiles,
    );
    _scheduleQueue();
  }

  Future<TorrentFileSelection?> selectTorrentFiles(
    DownloadTask task,
    TorrentMetadata metadata,
  ) async {
    if (!metadata.hasMultipleFiles) {
      return TorrentFileSelection(
        selectedIndexes: metadata.files.map((file) => file.index).toList(),
      );
    }
    if (!mounted) return null;
    return showTorrentFileSelectionDialog(
      context,
      strings: strings,
      metadata: metadata,
    );
  }

  Future<void> pauseTask(String id) async {
    await controller.pause(id);
  }

  Future<void> removeTask(String id) async {
    await controller.remove(id);
  }

  Future<void> copyTaskSource(DownloadTask task) async {
    await Clipboard.setData(ClipboardData(text: task.source));
    if (!mounted) return;
    _showSnack(strings.copiedDownloadLink);
  }

  Future<void> openTaskFile(DownloadTask task) async {
    final file = await _existingOutputFile(task);
    if (!mounted) return;
    if (file == null) {
      _showSnack(strings.fileNotFound);
      return;
    }
    final result = await OpenFilex.open(file.path);
    if (!mounted) return;
    if (result.type != ResultType.done) {
      _showSnack(
        result.message.isEmpty ? strings.openFileFailed : result.message,
      );
    }
  }

  Future<void> shareTaskFile(DownloadTask task) async {
    final file = await _existingOutputFile(task);
    if (!mounted) return;
    if (file == null) {
      _showSnack(strings.fileNotFound);
      return;
    }
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: task.fileName),
      );
    } catch (_) {
      if (!mounted) return;
      _showSnack(strings.shareFileFailed);
    }
  }

  void showTaskProperties(DownloadTask task) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => TaskPropertiesSheet(
        strings: strings,
        task: task,
        filePath: _preferredOutputPath(task),
      ),
    );
  }

  Future<void> redownloadTask(String id) async {
    final task = controller.tasks.firstWhere((task) => task.id == id);
    await controller.resetForRedownload(id);
    final file = await _existingOutputFile(task);
    if (file != null) {
      await file.delete();
    }
    _scheduleQueue();
  }

  Future<File?> _existingOutputFile(DownloadTask task) async {
    for (final fileName in _possibleOutputFileNames(task)) {
      final file = File(p.join(task.outputFolder, fileName));
      if (await file.exists()) {
        return file;
      }
    }
    return null;
  }

  String _preferredOutputPath(DownloadTask task) {
    if (task.isTorrentLike && task.selectedTorrentFiles.length > 1) {
      return p.join(task.outputFolder, task.torrentName ?? task.fileName);
    }
    return p.join(task.outputFolder, _possibleOutputFileNames(task).last);
  }

  List<String> _possibleOutputFileNames(DownloadTask task) {
    if (task.isTorrentLike && task.selectedTorrentFiles.isNotEmpty) {
      return task.selectedTorrentFiles
          .expand((file) => [file.path, file.name])
          .where((name) => name.trim().isNotEmpty)
          .toSet()
          .toList(growable: false);
    }
    final names = <String>[task.fileName];
    final outputName = _taskOutputFileName(task);
    if (outputName != task.fileName) {
      names.add(outputName);
    }
    return names.toList(growable: false);
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          strings: strings,
          settings: SettingsView(
            strings: strings,
            language: widget.language,
            queueConcurrency: queueConcurrency,
            downloadThreadCount: downloadThreadCount,
            retryAttempts: retryAttempts,
            speedLimitKbps: speedLimitKbps,
            outputFolderListenable: outputController,
            onLanguageChanged: widget.onLanguageChanged,
            onConcurrencyChanged: setQueueConcurrency,
            onDownloadThreadCountChanged: setDownloadThreadCount,
            onRetryAttemptsChanged: setRetryAttempts,
            onSpeedLimitChanged: setSpeedLimitKbps,
            onPickOutputFolder: pickOutputFolder,
            onOpenProtocols: openProtocols,
          ),
        ),
      ),
    );
  }

  void openProtocols() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProtocolsPage(
          strings: strings,
          activeProtocol: 'https',
          backend: strings.backendLabel('https'),
          executable: supportStatus('https').executable,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tasks = controller.tasks;

    return Scaffold(
      body: SafeArea(
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : QueueView(
                strings: strings,
                tasks: tasks,
                filter: queueFilter,
                onFilterChanged: (value) => setState(() {
                  queueFilter = value;
                }),
                onOpenSettings: openSettings,
                onStartTask: startTask,
                onPauseTask: pauseTask,
                onRemoveTask: removeTask,
                onCopySource: copyTaskSource,
                onShowProperties: showTaskProperties,
                onOpenFile: openTaskFile,
                onShareFile: shareTaskFile,
                onRedownloadTask: redownloadTask,
              ),
      ),
      floatingActionButton: loading
          ? null
          : FloatingActionButton(
              onPressed: showNewTaskDialog,
              tooltip: strings.newTask,
              child: const Icon(Icons.add_link),
            ),
    );
  }
}

class QueueView extends StatelessWidget {
  const QueueView({
    required this.strings,
    required this.tasks,
    required this.filter,
    required this.onFilterChanged,
    required this.onOpenSettings,
    required this.onStartTask,
    required this.onPauseTask,
    required this.onRemoveTask,
    required this.onCopySource,
    required this.onShowProperties,
    required this.onOpenFile,
    required this.onShareFile,
    required this.onRedownloadTask,
    super.key,
  });

  final AppStrings strings;
  final List<DownloadTask> tasks;
  final QueueFilter filter;
  final ValueChanged<QueueFilter> onFilterChanged;
  final VoidCallback onOpenSettings;
  final ValueChanged<String> onStartTask;
  final ValueChanged<String> onPauseTask;
  final ValueChanged<String> onRemoveTask;
  final ValueChanged<DownloadTask> onCopySource;
  final ValueChanged<DownloadTask> onShowProperties;
  final ValueChanged<DownloadTask> onOpenFile;
  final ValueChanged<DownloadTask> onShareFile;
  final ValueChanged<String> onRedownloadTask;

  @override
  Widget build(BuildContext context) {
    final visibleTasks = tasks
        .where((task) => _matchesFilter(task, filter))
        .toList(growable: false);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(
            children: [
              SectionHeader(
                icon: Icons.format_list_bulleted,
                title: strings.queue,
                trailingWidget: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(strings.taskCount(tasks.length)),
                    const SizedBox(width: 6),
                    IconButton(
                      tooltip: strings.settings,
                      onPressed: onOpenSettings,
                      icon: const Icon(Icons.tune, size: 20),
                      constraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 40,
                      ),
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              QueueFilterTabs(
                strings: strings,
                tasks: tasks,
                selected: filter,
                onSelected: onFilterChanged,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: visibleTasks.isEmpty
              ? ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  children: [EmptyQueueCard(strings: strings)],
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
                  itemCount: visibleTasks.length,
                  itemBuilder: (context, index) {
                    final task = visibleTasks[index];
                    return DownloadTaskCard(
                      strings: strings,
                      task: task,
                      onToggle: () {
                        if (task.canPause) {
                          onPauseTask(task.id);
                        } else if (task.canRun) {
                          onStartTask(task.id);
                        }
                      },
                      onStart: () => onStartTask(task.id),
                      onPause: () => onPauseTask(task.id),
                      onRemove: () => onRemoveTask(task.id),
                      onCopySource: () => onCopySource(task),
                      onShowProperties: () => onShowProperties(task),
                      onOpenFile: () => onOpenFile(task),
                      onShareFile: () => onShareFile(task),
                      onRedownload: () => onRedownloadTask(task.id),
                    );
                  },
                ),
        ),
      ],
    );
  }

  bool _matchesFilter(DownloadTask task, QueueFilter filter) {
    return switch (filter) {
      QueueFilter.all => true,
      QueueFilter.queued => task.state == DownloadState.queued,
      QueueFilter.running => task.state == DownloadState.running,
      QueueFilter.finished => task.state == DownloadState.finished,
      QueueFilter.failed => task.state == DownloadState.failed,
    };
  }
}

class NewTaskDialog extends StatefulWidget {
  const NewTaskDialog({
    required this.strings,
    required this.defaultOutputFolder,
    required this.onPickOutputFolder,
    required this.onCreate,
    super.key,
  });

  final AppStrings strings;
  final String defaultOutputFolder;
  final Future<String?> Function() onPickOutputFolder;
  final Future<bool> Function({
    required String source,
    required String outputFolder,
    String? fileName,
    String? torrentName,
    List<TorrentFileEntry> torrentFiles,
    List<int>? selectedTorrentFileIndexes,
  })
  onCreate;

  @override
  State<NewTaskDialog> createState() => _NewTaskDialogState();
}

class _NewTaskDialogState extends State<NewTaskDialog> {
  final sourceController = TextEditingController();
  final fileNameController = TextEditingController();
  final outputFolderController = TextEditingController();
  var busy = false;
  String? errorText;
  var fileNameEdited = false;
  StorageStats? storageStats;
  var loadingStorageStats = false;
  var storageStatsUnavailable = false;
  Timer? storageStatsDebounce;
  var storageStatsToken = 0;

  AppStrings get strings => widget.strings;

  @override
  void initState() {
    super.initState();
    outputFolderController.text = widget.defaultOutputFolder;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(refreshStorageStats());
      }
    });
  }

  @override
  void dispose() {
    storageStatsDebounce?.cancel();
    sourceController.dispose();
    fileNameController.dispose();
    outputFolderController.dispose();
    super.dispose();
  }

  Future<void> createFromInput() async {
    await createFromSource(sourceController.text);
  }

  Future<void> pasteSourceFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      setState(() {
        errorText = strings.clipboardEmpty;
      });
      return;
    }
    sourceController.text = text;
    syncSuggestedFileName(text);
    setState(() {
      errorText = null;
    });
  }

  Future<void> scanSourceFromQr() async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => QrScannerPage(strings: strings)),
    );
    if (!mounted || scanned == null) return;
    final text = scanned.trim();
    if (text.isEmpty) return;
    sourceController.text = text;
    syncSuggestedFileName(text);
    setState(() {
      errorText = null;
    });
  }

  Future<void> pickOutputFolder() async {
    final selected = await widget.onPickOutputFolder();
    if (!mounted || selected == null || selected.trim().isEmpty) return;
    setState(() {
      outputFolderController.text = selected.trim();
    });
    unawaited(refreshStorageStats());
  }

  Future<void> createFromSource(String source) async {
    final normalized = source.trim();
    if (normalized.isEmpty) {
      setState(() {
        errorText = strings.sourceRequired;
      });
      return;
    }
    setState(() {
      busy = true;
      errorText = null;
    });
    var effectiveFileName = fileNameController.text;
    String? torrentName;
    var torrentFiles = const <TorrentFileEntry>[];
    List<int>? selectedTorrentFileIndexes;
    if (detectProtocol(normalized) == 'torrent') {
      try {
        final metadata = await inspectTorrentMetadataFromSource(normalized);
        if (!mounted) return;
        if (metadata == null) {
          setState(() {
            busy = false;
            errorText = strings.torrentMetadataFailed;
          });
          return;
        }

        final selection = await selectTorrentFilesForMetadata(metadata);
        if (!mounted) return;
        if (selection == null || selection.selectedIndexes.isEmpty) {
          setState(() {
            busy = false;
            errorText = strings.torrentSelectionRequired;
          });
          return;
        }

        torrentName = metadata.name;
        torrentFiles = metadata.files;
        selectedTorrentFileIndexes = selection.selectedIndexes;
        effectiveFileName = torrentDisplayName(
          metadata,
          selectedIndexes: selectedTorrentFileIndexes,
        );
      } catch (_) {
        if (!mounted) return;
        setState(() {
          busy = false;
          errorText = strings.torrentMetadataFailed;
        });
        return;
      }
    }
    final created = await widget.onCreate(
      source: normalized,
      outputFolder: outputFolderController.text,
      fileName: effectiveFileName,
      torrentName: torrentName,
      torrentFiles: torrentFiles,
      selectedTorrentFileIndexes: selectedTorrentFileIndexes,
    );
    if (!mounted) return;
    if (created) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      busy = false;
    });
  }

  Future<TorrentFileSelection?> selectTorrentFilesForMetadata(
    TorrentMetadata metadata,
  ) {
    if (!metadata.hasMultipleFiles) {
      return Future.value(
        TorrentFileSelection(
          selectedIndexes: metadata.files.map((file) => file.index).toList(),
        ),
      );
    }
    return showTorrentFileSelectionDialog(
      context,
      strings: strings,
      metadata: metadata,
    );
  }

  void syncSuggestedFileName(String source) {
    if (fileNameEdited) return;
    final normalized = source.trim();
    fileNameController.text = normalized.isEmpty
        ? ''
        : suggestedFileName(normalized);
  }

  void scheduleStorageStatsRefresh() {
    storageStatsDebounce?.cancel();
    storageStatsDebounce = Timer(const Duration(milliseconds: 420), () {
      unawaited(refreshStorageStats());
    });
  }

  Future<void> refreshStorageStats() async {
    final path = outputFolderController.text.trim();
    final token = ++storageStatsToken;
    if (path.isEmpty) {
      if (!mounted) return;
      setState(() {
        storageStats = null;
        loadingStorageStats = false;
        storageStatsUnavailable = true;
      });
      return;
    }

    setState(() {
      loadingStorageStats = true;
      storageStatsUnavailable = false;
    });
    final stats = await loadStorageStats(path);
    if (!mounted || token != storageStatsToken) return;
    setState(() {
      storageStats = stats;
      loadingStorageStats = false;
      storageStatsUnavailable = stats == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: const TextScaler.linear(0.86)),
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, minHeight: 390),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer.withValues(
                          alpha: 0.72,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.add_link,
                        size: 15,
                        color: colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        strings.newTask,
                        style: textTheme.titleMedium?.copyWith(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: strings.createFromClipboard,
                      onPressed: busy ? null : pasteSourceFromClipboard,
                      icon: const Icon(Icons.content_paste_go, size: 17),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                    ),
                    IconButton(
                      tooltip: strings.scanQr,
                      onPressed: busy ? null : scanSourceFromQr,
                      icon: const Icon(Icons.qr_code_scanner, size: 17),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                    ),
                    const SizedBox(width: 2),
                    IconButton(
                      tooltip: strings.close,
                      onPressed: busy
                          ? null
                          : () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, size: 18),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: sourceController,
                  minLines: 4,
                  maxLines: 6,
                  enabled: !busy,
                  textInputAction: TextInputAction.done,
                  style: const TextStyle(fontSize: 12, height: 1.12),
                  decoration: InputDecoration(
                    labelText: strings.source,
                    alignLabelWithHint: true,
                    labelStyle: const TextStyle(fontSize: 12),
                    errorText: errorText,
                    errorStyle: const TextStyle(fontSize: 11.5),
                    prefixIcon: const Icon(Icons.link, size: 18),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                  ),
                  onChanged: (value) {
                    syncSuggestedFileName(value);
                    if (errorText != null) {
                      setState(() {
                        errorText = null;
                      });
                    }
                  },
                  onSubmitted: (_) => busy ? null : createFromInput(),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: fileNameController,
                  enabled: !busy,
                  textInputAction: TextInputAction.next,
                  style: const TextStyle(fontSize: 12, height: 1.12),
                  decoration: InputDecoration(
                    labelText: strings.saveAsFileName,
                    labelStyle: const TextStyle(fontSize: 12),
                    prefixIcon: const Icon(
                      Icons.description_outlined,
                      size: 18,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                  ),
                  onChanged: (_) {
                    fileNameEdited = true;
                  },
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: outputFolderController,
                  enabled: !busy,
                  textInputAction: TextInputAction.done,
                  style: const TextStyle(fontSize: 12, height: 1.12),
                  decoration: InputDecoration(
                    labelText: strings.savePath,
                    labelStyle: const TextStyle(fontSize: 12),
                    prefixIcon: const Icon(Icons.folder_outlined, size: 18),
                    suffixIcon: IconButton(
                      tooltip: strings.chooseFolder,
                      onPressed: busy ? null : pickOutputFolder,
                      icon: const Icon(
                        Icons.drive_folder_upload_outlined,
                        size: 18,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                  ),
                  onChanged: (_) => scheduleStorageStatsRefresh(),
                ),
                const SizedBox(height: 8),
                StorageStatsPanel(
                  strings: strings,
                  stats: storageStats,
                  loading: loadingStorageStats,
                  unavailable: storageStatsUnavailable,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: busy
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: Text(strings.close),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: busy ? null : createFromInput,
                        icon: busy
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.add, size: 17),
                        label: Text(
                          strings.createTask,
                          overflow: TextOverflow.ellipsis,
                        ),
                        style: FilledButton.styleFrom(
                          textStyle: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                          ),
                          minimumSize: const Size.fromHeight(44),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<TorrentFileSelection?> showTorrentFileSelectionDialog(
  BuildContext context, {
  required AppStrings strings,
  required TorrentMetadata metadata,
}) {
  return showDialog<TorrentFileSelection>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        TorrentFileSelectionDialog(strings: strings, metadata: metadata),
  );
}

class TorrentFileSelectionDialog extends StatefulWidget {
  const TorrentFileSelectionDialog({
    required this.strings,
    required this.metadata,
    super.key,
  });

  final AppStrings strings;
  final TorrentMetadata metadata;

  @override
  State<TorrentFileSelectionDialog> createState() =>
      _TorrentFileSelectionDialogState();
}

class _TorrentFileSelectionDialogState
    extends State<TorrentFileSelectionDialog> {
  late final Set<int> selectedIndexes;

  AppStrings get strings => widget.strings;

  @override
  void initState() {
    super.initState();
    selectedIndexes = widget.metadata.files.map((file) => file.index).toSet();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final files = widget.metadata.files;

    return MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: const TextScaler.linear(0.86)),
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        strings.selectTorrentFiles,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleMedium?.copyWith(
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    Text(
                      strings.torrentSelectedCount(selectedIndexes.length),
                      style: textTheme.labelSmall?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  strings.selectTorrentFilesHint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: () {
                        setState(() {
                          selectedIndexes
                            ..clear()
                            ..addAll(files.map((file) => file.index));
                        });
                      },
                      icon: const Icon(Icons.done_all, size: 16),
                      label: Text(strings.selectAll),
                    ),
                    const SizedBox(width: 4),
                    TextButton.icon(
                      onPressed: () {
                        setState(selectedIndexes.clear);
                      },
                      icon: const Icon(Icons.remove_done, size: 16),
                      label: Text(strings.selectNone),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Flexible(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: colorScheme.outlineVariant),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: files.length,
                      separatorBuilder: (context, index) => Divider(
                        height: 1,
                        thickness: 1,
                        color: colorScheme.outlineVariant,
                      ),
                      itemBuilder: (context, index) {
                        final file = files[index];
                        final selected = selectedIndexes.contains(file.index);
                        return CheckboxListTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          value: selected,
                          onChanged: (value) {
                            setState(() {
                              if (value == true) {
                                selectedIndexes.add(file.index);
                              } else {
                                selectedIndexes.remove(file.index);
                              }
                            });
                          },
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(
                            file.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          subtitle: Text(
                            '${file.path}  ·  ${formatBytes(file.size)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(strings.close),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: selectedIndexes.isEmpty
                            ? null
                            : () => Navigator.of(context).pop(
                                TorrentFileSelection(
                                  selectedIndexes: selectedIndexes.toList(
                                    growable: false,
                                  )..sort(),
                                ),
                              ),
                        icon: const Icon(Icons.check, size: 17),
                        label: Text(strings.confirmSelection),
                        style: FilledButton.styleFrom(
                          textStyle: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                          ),
                          minimumSize: const Size.fromHeight(42),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class StorageStatsPanel extends StatelessWidget {
  const StorageStatsPanel({
    required this.strings,
    required this.stats,
    required this.loading,
    required this.unavailable,
    super.key,
  });

  final AppStrings strings;
  final StorageStats? stats;
  final bool loading;
  final bool unavailable;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.65),
        ),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: loading && stats == null
            ? _StorageMessage(
                key: const ValueKey('loading-storage'),
                icon: Icons.storage_outlined,
                label: strings.storageLoading,
              )
            : stats == null || unavailable
            ? _StorageMessage(
                key: const ValueKey('storage-unavailable'),
                icon: Icons.error_outline,
                label: strings.storageUnavailable,
              )
            : Row(
                key: const ValueKey('storage-stats'),
                children: [
                  Expanded(
                    child: StorageStatItem(
                      label: strings.storageTotal,
                      value: formatBytes(stats!.totalBytes),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: StorageStatItem(
                      label: strings.storageUsed,
                      value: formatBytes(stats!.usedBytes),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: StorageStatItem(
                      label: strings.storageFree,
                      value: formatBytes(stats!.freeBytes),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _StorageMessage extends StatelessWidget {
  const _StorageMessage({required this.icon, required this.label, super.key});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Row(
      children: [
        Icon(icon, size: 16, color: colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class StorageStatItem extends StatelessWidget {
  const StorageStatItem({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      constraints: const BoxConstraints(minHeight: 46),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ProtocolsView extends StatelessWidget {
  const ProtocolsView({
    required this.strings,
    required this.activeProtocol,
    required this.backend,
    required this.executable,
    super.key,
  });

  final AppStrings strings;
  final String activeProtocol;
  final String backend;
  final bool executable;

  static const protocolLabels = [
    'HTTP',
    'HTTPS',
    'WebDAV',
    'FTP',
    'Torrent',
    'Magnet',
    'ed2k',
    'm3u8',
    'SFTP',
    'SMB',
    'IPFS',
  ];

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 14),
      children: [
        SettingsGroupCard(
          children: [
            SettingsCompactRow(
              icon: Icons.trip_origin,
              title: strings.currentDetection,
              subtitle: strings.supportNote(activeProtocol),
              trailing: StatusPill(
                icon: executable ? Icons.check_circle : Icons.pending_outlined,
                label: protocolLabel(activeProtocol),
                foreground: executable
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
                background: executable
                    ? colorScheme.primaryContainer.withValues(alpha: 0.55)
                    : colorScheme.surfaceContainerHighest,
                dense: true,
              ),
            ),
            SettingsCompactRow(
              icon: Icons.memory_outlined,
              title: strings.backend,
              subtitle: strings.detectedLine(activeProtocol, backend),
              trailing: StatusPill(
                icon: executable ? Icons.done : Icons.schedule,
                label: backend,
                foreground: colorScheme.onSurfaceVariant,
                background: colorScheme.surfaceContainerHighest,
                dense: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SettingsGroupCard(
          children: [
            SettingsCompactRow(
              icon: Icons.hub_outlined,
              title: strings.protocolList,
              subtitle: strings.protocolListHint,
              trailing: Text(
                strings.allProtocols,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            ...protocolLabels.map(
              (label) => ProtocolDetailCard(
                strings: strings,
                label: label,
                active: label.toLowerCase() == activeProtocol.toLowerCase(),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class ProtocolsPage extends StatelessWidget {
  const ProtocolsPage({
    required this.strings,
    required this.activeProtocol,
    required this.backend,
    required this.executable,
    super.key,
  });

  final AppStrings strings;
  final String activeProtocol;
  final String backend;
  final bool executable;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        title: Text(
          strings.protocolSupport,
          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w900),
        ),
      ),
      body: SafeArea(
        child: MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(0.82)),
          child: ProtocolsView(
            strings: strings,
            activeProtocol: activeProtocol,
            backend: backend,
            executable: executable,
          ),
        ),
      ),
    );
  }
}

class QrScannerPage extends StatefulWidget {
  const QrScannerPage({required this.strings, super.key});

  final AppStrings strings;

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  final controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
  );
  var handled = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void handleBarcode(BarcodeCapture capture) {
    if (handled) return;
    final value = capture.barcodes
        .map((barcode) => barcode.rawValue ?? barcode.displayValue)
        .whereType<String>()
        .map((text) => text.trim())
        .where((text) => text.isNotEmpty)
        .firstOrNull;
    if (value == null) return;
    handled = true;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.strings.scanQrTitle),
        foregroundColor: Colors.white,
        backgroundColor: Colors.black,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(widget.strings.close),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(controller: controller, onDetect: handleBarcode),
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
              color: Colors.black.withValues(alpha: 0.58),
              child: Text(
                widget.strings.scanQrPrompt,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class QueueFilterTabs extends StatelessWidget {
  const QueueFilterTabs({
    required this.strings,
    required this.tasks,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final AppStrings strings;
  final List<DownloadTask> tasks;
  final QueueFilter selected;
  final ValueChanged<QueueFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final counts = <QueueFilter, int>{
      QueueFilter.all: tasks.length,
      QueueFilter.queued: _count(DownloadState.queued),
      QueueFilter.running: _count(DownloadState.running),
      QueueFilter.finished: _count(DownloadState.finished),
      QueueFilter.failed: _count(DownloadState.failed),
    };

    return Container(
      height: 42,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          for (final filter in QueueFilter.values)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(left: filter.index == 0 ? 0 : 3),
                child: QueueFilterTabButton(
                  label: _label(filter),
                  count: counts[filter] ?? 0,
                  selected: filter == selected,
                  onTap: () => onSelected(filter),
                ),
              ),
            ),
        ],
      ),
    );
  }

  int _count(DownloadState state) {
    return tasks.where((task) => task.state == state).length;
  }

  String _label(QueueFilter filter) {
    return switch (filter) {
      QueueFilter.all => strings.queueAll,
      QueueFilter.queued => strings.queueQueued,
      QueueFilter.running => strings.queueDownloading,
      QueueFilter.finished => strings.queueCompleted,
      QueueFilter.failed => strings.queueFailed,
    };
  }
}

class QueueFilterTabButton extends StatelessWidget {
  const QueueFilterTabButton({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foreground = selected
        ? colorScheme.onPrimary
        : colorScheme.onSurfaceVariant;

    return Semantics(
      button: true,
      selected: selected,
      label: '$label($count)',
      onTap: onTap,
      child: ExcludeSemantics(
        child: Material(
          color: selected ? colorScheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '$label($count)',
                  maxLines: 1,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 10.5,
                    fontWeight: selected ? FontWeight.w900 : FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    required this.strings,
    required this.settings,
    super.key,
  });

  final AppStrings strings;
  final SettingsView settings;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        title: Text(
          strings.settings,
          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w900),
        ),
      ),
      body: SafeArea(
        child: MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(0.82)),
          child: settings,
        ),
      ),
    );
  }
}

class SettingsView extends StatelessWidget {
  const SettingsView({
    required this.strings,
    required this.language,
    required this.queueConcurrency,
    required this.downloadThreadCount,
    required this.retryAttempts,
    required this.speedLimitKbps,
    required this.outputFolderListenable,
    required this.onLanguageChanged,
    required this.onConcurrencyChanged,
    required this.onDownloadThreadCountChanged,
    required this.onRetryAttemptsChanged,
    required this.onSpeedLimitChanged,
    required this.onPickOutputFolder,
    required this.onOpenProtocols,
    super.key,
  });

  final AppStrings strings;
  final AppLanguage language;
  final int queueConcurrency;
  final int downloadThreadCount;
  final int retryAttempts;
  final int speedLimitKbps;
  final ValueListenable<TextEditingValue> outputFolderListenable;
  final ValueChanged<AppLanguage> onLanguageChanged;
  final ValueChanged<int> onConcurrencyChanged;
  final ValueChanged<int> onDownloadThreadCountChanged;
  final ValueChanged<int> onRetryAttemptsChanged;
  final ValueChanged<int> onSpeedLimitChanged;
  final VoidCallback onPickOutputFolder;
  final VoidCallback onOpenProtocols;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 14),
      children: [
        SettingsGroupCard(
          children: [
            SettingsCompactRow(
              icon: Icons.language,
              title: strings.languageLabel,
              subtitle: language == AppLanguage.zh ? '应用界面' : 'App interface',
              trailing: LanguageMenu(
                strings: strings,
                language: language,
                onLanguageChanged: onLanguageChanged,
              ),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: outputFolderListenable,
              builder: (context, value, _) {
                return SettingsCompactRow(
                  icon: Icons.folder_outlined,
                  title: strings.outputFolder,
                  subtitle: value.text,
                  trailing: IconButton(
                    tooltip: strings.chooseFolder,
                    onPressed: onPickOutputFolder,
                    icon: const Icon(
                      Icons.drive_folder_upload_outlined,
                      size: 16,
                    ),
                    constraints: const BoxConstraints.tightFor(
                      width: 38,
                      height: 38,
                    ),
                    padding: EdgeInsets.zero,
                  ),
                );
              },
            ),
            SettingsNumberInput(
              icon: Icons.speed,
              title: strings.concurrencySetting,
              subtitle: strings.concurrencySettingHint,
              valueText: '$queueConcurrency',
              hintText: '$_defaultQueueConcurrency',
              suffixText: language == AppLanguage.zh ? '个' : '',
              onSubmitted: (value) {
                final parsed = parseBoundedInteger(
                  value,
                  min: 1,
                  max: _maxQueueConcurrency,
                );
                if (parsed != null) onConcurrencyChanged(parsed);
              },
            ),
            SettingsNumberInput(
              icon: Icons.account_tree_outlined,
              title: strings.downloadThreadsSetting,
              subtitle: strings.downloadThreadsHint,
              valueText: '$downloadThreadCount',
              hintText: '$_defaultDownloadThreadCount',
              suffixText: language == AppLanguage.zh ? '线程' : '',
              onSubmitted: (value) {
                final parsed = parseBoundedInteger(
                  value,
                  min: 1,
                  max: _maxDownloadThreadCount,
                );
                if (parsed != null) onDownloadThreadCountChanged(parsed);
              },
            ),
            SettingsNumberInput(
              icon: Icons.refresh,
              title: strings.retryAttemptsSetting,
              subtitle: strings.retryAttemptsHint,
              valueText: '$retryAttempts',
              hintText: '$_defaultRetryAttempts',
              suffixText: language == AppLanguage.zh ? '次' : '',
              onSubmitted: (value) {
                final parsed = parseBoundedInteger(
                  value,
                  min: 0,
                  max: _maxRetryAttempts,
                );
                if (parsed != null) onRetryAttemptsChanged(parsed);
              },
            ),
            SettingsNumberInput(
              icon: Icons.speed_outlined,
              title: strings.speedLimitSetting,
              subtitle: strings.speedLimitHint,
              valueText: speedLimitInputValue(speedLimitKbps),
              hintText: language == AppLanguage.zh ? '不限速' : 'Unlimited',
              suffixText: 'MB/s',
              allowDecimal: true,
              allowEmpty: true,
              onSubmitted: (value) {
                final parsed = parseSpeedLimitInputKbps(value);
                if (parsed != null) onSpeedLimitChanged(parsed);
              },
            ),
            SettingsCompactRow(
              icon: Icons.hub_outlined,
              title: strings.protocolSupport,
              subtitle: language == AppLanguage.zh
                  ? '查看支持协议'
                  : 'View supported protocols',
              trailing: IconButton(
                tooltip: strings.protocolSupport,
                onPressed: onOpenProtocols,
                icon: const Icon(Icons.chevron_right, size: 18),
                constraints: const BoxConstraints.tightFor(
                  width: 38,
                  height: 38,
                ),
                padding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class SettingsCompactRow extends StatelessWidget {
  const SettingsCompactRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 46),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionHeader(icon: icon, title: title, dense: true),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 10,
                    height: 1.05,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
  }
}

class SettingsGroupCard extends StatelessWidget {
  const SettingsGroupCard({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.72),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var index = 0; index < children.length; index += 1) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              child: children[index],
            ),
            if (index != children.length - 1)
              Divider(
                height: 1,
                thickness: 1,
                color: colorScheme.outlineVariant.withValues(alpha: 0.55),
              ),
          ],
        ],
      ),
    );
  }
}

class SettingsNumberInput extends StatefulWidget {
  const SettingsNumberInput({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.valueText,
    required this.hintText,
    required this.onSubmitted,
    this.suffixText,
    this.allowDecimal = false,
    this.allowEmpty = false,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String valueText;
  final String hintText;
  final String? suffixText;
  final bool allowDecimal;
  final bool allowEmpty;
  final ValueChanged<String> onSubmitted;

  @override
  State<SettingsNumberInput> createState() => _SettingsNumberInputState();
}

class _SettingsNumberInputState extends State<SettingsNumberInput> {
  late final TextEditingController controller;
  late final FocusNode focusNode;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.valueText);
    focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant SettingsNumberInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!focusNode.hasFocus && controller.text != widget.valueText) {
      controller.text = widget.valueText;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    focusNode.dispose();
    super.dispose();
  }

  void commit() {
    final value = controller.text.trim();
    if (value.isNotEmpty || widget.allowEmpty) {
      widget.onSubmitted(value);
    }
    focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 46),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionHeader(
                  icon: widget.icon,
                  title: widget.title,
                  dense: true,
                ),
                const SizedBox(height: 2),
                Text(
                  widget.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 10,
                    height: 1.05,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: widget.suffixText == null ? 76 : 98,
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              textAlign: TextAlign.right,
              keyboardType: TextInputType.numberWithOptions(
                decimal: widget.allowDecimal,
              ),
              inputFormatters: [
                if (widget.allowDecimal)
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
                else
                  FilteringTextInputFormatter.digitsOnly,
              ],
              style: const TextStyle(
                fontSize: 12,
                height: 1.1,
                fontWeight: FontWeight.w800,
              ),
              decoration: InputDecoration(
                hintText: widget.hintText,
                suffixText: widget.suffixText,
                suffixStyle: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
              ),
              onSubmitted: (_) => commit(),
              onEditingComplete: commit,
              onTapOutside: (_) => commit(),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsSwitchTile extends StatelessWidget {
  const SettingsSwitchTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 42),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.titleSmall?.copyWith(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w900,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 10.5,
                      height: 1.16,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Transform.scale(
            scale: 0.76,
            child: Switch.adaptive(value: value, onChanged: onChanged),
          ),
        ],
      ),
    );
  }
}

class ProtocolDetailCard extends StatelessWidget {
  const ProtocolDetailCard({
    required this.strings,
    required this.label,
    required this.active,
    super.key,
  });

  final AppStrings strings;
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final protocol = label.toLowerCase();
    final executable = supportStatus(protocol).executable;

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: active
              ? colorScheme.primaryContainer.withValues(alpha: 0.38)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: active
              ? const EdgeInsets.symmetric(horizontal: 7, vertical: 5)
              : EdgeInsets.zero,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: active
                      ? colorScheme.primary
                      : colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(
                  _protocolIcon(label),
                  color: active
                      ? colorScheme.onPrimary
                      : colorScheme.onSurfaceVariant,
                  size: 15,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontSize: 11.8,
                        fontWeight: FontWeight.w900,
                        height: 1.08,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      strings.supportNote(protocol),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 10,
                        height: 1.05,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StatusPill(
                icon: executable ? Icons.check_circle : Icons.pending_outlined,
                label: strings.backendLabel(protocol),
                foreground: active
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
                background: active
                    ? colorScheme.primaryContainer.withValues(alpha: 0.62)
                    : colorScheme.surfaceContainerHighest,
                dense: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class LanguageMenu extends StatelessWidget {
  const LanguageMenu({
    required this.strings,
    required this.language,
    required this.onLanguageChanged,
    super.key,
  });

  final AppStrings strings;
  final AppLanguage language;
  final ValueChanged<AppLanguage> onLanguageChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return PopupMenuButton<AppLanguage>(
      tooltip: strings.languageLabel,
      initialValue: language,
      onSelected: onLanguageChanged,
      itemBuilder: (context) => [
        PopupMenuItem(
          value: AppLanguage.zh,
          height: 36,
          child: Text(strings.chinese, style: const TextStyle(fontSize: 12)),
        ),
        PopupMenuItem(
          value: AppLanguage.en,
          height: 36,
          child: Text(strings.english, style: const TextStyle(fontSize: 12)),
        ),
      ],
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.language, color: colorScheme.onSurfaceVariant, size: 13),
            const SizedBox(width: 4),
            Text(
              language == AppLanguage.zh ? strings.chinese : strings.english,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    required this.icon,
    required this.title,
    this.trailing,
    this.trailingWidget,
    this.dense = false,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? trailing;
  final Widget? trailingWidget;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Row(
      children: [
        Container(
          width: dense ? 22 : 30,
          height: dense ? 22 : 30,
          decoration: BoxDecoration(
            color: colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: dense ? 13 : 18,
            color: colorScheme.onSecondaryContainer,
          ),
        ),
        SizedBox(width: dense ? 7 : 10),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: dense
                ? textTheme.titleSmall?.copyWith(
                    fontSize: 11.8,
                    fontWeight: FontWeight.w900,
                    height: 1.08,
                  )
                : textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        if (trailingWidget != null)
          trailingWidget!
        else if (trailing != null)
          Text(
            trailing!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: (dense ? textTheme.labelMedium : textTheme.labelLarge)
                ?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: dense ? 10.5 : null,
                  fontWeight: FontWeight.w800,
                ),
          ),
      ],
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({
    required this.icon,
    required this.label,
    required this.foreground,
    required this.background,
    this.dense = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final Color foreground;
  final Color background;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(minHeight: dense ? 28 : 34),
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 10,
        vertical: dense ? 5 : 7,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: dense ? 14 : 17, color: foreground),
          SizedBox(width: dense ? 4 : 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: foreground,
                fontWeight: FontWeight.w800,
                fontSize: dense ? 11 : 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CapabilityStrip extends StatelessWidget {
  const CapabilityStrip({required this.activeProtocol, super.key});

  final String activeProtocol;

  static const protocols = [
    'HTTP',
    'HTTPS',
    'WebDAV',
    'FTP',
    'Torrent',
    'Magnet',
    'ed2k',
    'm3u8',
    'SFTP',
    'SMB',
    'IPFS',
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 7,
      runSpacing: 7,
      children: protocols
          .map(
            (label) => ProtocolChip(
              label: label,
              active: label.toLowerCase() == activeProtocol.toLowerCase(),
            ),
          )
          .toList(growable: false),
    );
  }
}

class EmptyQueueCard extends StatelessWidget {
  const EmptyQueueCard({required this.strings, super.key});

  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.inbox_outlined,
              color: colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            strings.noQueuedTasks,
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            strings.noQueuedTasksHint,
            textAlign: TextAlign.center,
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class ProtocolChip extends StatelessWidget {
  const ProtocolChip({required this.label, this.active = false, super.key});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foreground = active
        ? colorScheme.onPrimary
        : colorScheme.onSurfaceVariant;
    final background = active
        ? colorScheme.primary
        : colorScheme.surfaceContainerLow;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active
              ? colorScheme.primary
              : colorScheme.outlineVariant.withValues(alpha: 0.85),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_protocolIcon(label), size: 16, color: foreground),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontWeight: active ? FontWeight.w800 : FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class DownloadTaskCard extends StatelessWidget {
  const DownloadTaskCard({
    required this.strings,
    required this.task,
    required this.onToggle,
    required this.onStart,
    required this.onPause,
    required this.onRemove,
    required this.onCopySource,
    required this.onShowProperties,
    required this.onOpenFile,
    required this.onShareFile,
    required this.onRedownload,
    super.key,
  });

  final AppStrings strings;
  final DownloadTask task;
  final VoidCallback onToggle;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onRemove;
  final VoidCallback onCopySource;
  final VoidCallback onShowProperties;
  final VoidCallback onOpenFile;
  final VoidCallback onShareFile;
  final VoidCallback onRedownload;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final progress = task.state == DownloadState.running
        ? (task.progress ?? 0).clamp(0.0, 1.0).toDouble()
        : 0.0;
    final visualState = _taskVisualState(task);
    final accentColor = _taskStateAccent(visualState, colorScheme);
    final detailStyle = textTheme.labelSmall?.copyWith(
      fontSize: 10.5,
      color: colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w700,
      height: 1.16,
    );

    return Card(
      clipBehavior: Clip.antiAlias,
      color: _taskStateBackground(visualState, colorScheme),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: _taskStateBorder(visualState, colorScheme)),
      ),
      child: InkWell(
        onTap: task.canPause || task.canRun ? onToggle : null,
        onLongPress: () => _showActions(context),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Stack(
              children: [
                if (progress > 0)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      width: constraints.maxWidth * progress,
                      color: _taskProgressFill(colorScheme),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 0, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _taskOutputFileName(task),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.titleSmall?.copyWith(
                                fontSize: 13,
                                color: colorScheme.onSurface,
                                fontWeight: FontWeight.w900,
                                height: 1.1,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 12,
                              runSpacing: 4,
                              children: [
                                TaskDetailChip(
                                  icon: Icons.play_circle_outline,
                                  iconColor: accentColor,
                                  text: _formatDateTime(task.startedAt),
                                  tooltip: strings.startTime,
                                  style: detailStyle,
                                ),
                                TaskDetailChip(
                                  icon: Icons.flag_outlined,
                                  iconColor: accentColor,
                                  text: _formatDateTime(task.finishedAt),
                                  tooltip: strings.endTime,
                                  style: detailStyle,
                                ),
                                TaskDetailChip(
                                  icon: Icons.timer_outlined,
                                  iconColor: accentColor,
                                  text: _formatDuration(task.elapsed),
                                  tooltip: strings.totalElapsed,
                                  style: detailStyle,
                                ),
                                TaskDetailChip(
                                  icon: Icons.data_usage,
                                  iconColor: accentColor,
                                  text: _formatBytePair(task),
                                  tooltip: strings.fileSize,
                                  style: detailStyle,
                                ),
                                TaskDetailChip(
                                  icon: Icons.speed,
                                  iconColor: accentColor,
                                  text: _formatSpeed(
                                    _visibleSpeedBytesPerSecond(task),
                                  ),
                                  tooltip: _speedTooltip(strings, task),
                                  style: detailStyle,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 2),
                      IconButton(
                        tooltip: strings.taskActions,
                        onPressed: () => _showActions(context),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 44,
                          height: 48,
                        ),
                        color: accentColor,
                        icon: const Icon(Icons.more_vert),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _showActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        void closeAndRun(VoidCallback action) {
          Navigator.of(sheetContext).pop();
          action();
        }

        return TaskActionsSheet(
          strings: strings,
          task: task,
          onCopySource: () => closeAndRun(onCopySource),
          onShowProperties: () => closeAndRun(onShowProperties),
          onOpenFile: () => closeAndRun(onOpenFile),
          onShareFile: () => closeAndRun(onShareFile),
          onRedownload: () => closeAndRun(onRedownload),
          onPause: () => closeAndRun(onPause),
          onStart: () => closeAndRun(onStart),
          onRemove: () => closeAndRun(onRemove),
        );
      },
    );
  }
}

class TaskDetailChip extends StatelessWidget {
  const TaskDetailChip({
    required this.icon,
    required this.iconColor,
    required this.text,
    required this.tooltip,
    required this.style,
    super.key,
  });

  final IconData icon;
  final Color iconColor;
  final String text;
  final String tooltip;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: '$tooltip $text',
        child: ExcludeSemantics(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: iconColor),
              const SizedBox(width: 3),
              Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TaskActionsSheet extends StatelessWidget {
  const TaskActionsSheet({
    required this.strings,
    required this.task,
    required this.onCopySource,
    required this.onShowProperties,
    required this.onOpenFile,
    required this.onShareFile,
    required this.onRedownload,
    required this.onPause,
    required this.onStart,
    required this.onRemove,
    super.key,
  });

  final AppStrings strings;
  final DownloadTask task;
  final VoidCallback onCopySource;
  final VoidCallback onShowProperties;
  final VoidCallback onOpenFile;
  final VoidCallback onShareFile;
  final VoidCallback onRedownload;
  final VoidCallback onPause;
  final VoidCallback onStart;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              strings.taskActions,
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _taskOutputFileName(task),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final itemWidth = (constraints.maxWidth - 8) / 2;

                Widget action({
                  required IconData icon,
                  required String label,
                  required VoidCallback onTap,
                  bool destructive = false,
                }) {
                  return SizedBox(
                    width: itemWidth,
                    child: TaskActionButton(
                      icon: icon,
                      label: label,
                      onTap: onTap,
                      destructive: destructive,
                    ),
                  );
                }

                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    action(
                      icon: Icons.link,
                      label: strings.copyDownloadLink,
                      onTap: onCopySource,
                    ),
                    action(
                      icon: Icons.info_outline,
                      label: strings.properties,
                      onTap: onShowProperties,
                    ),
                    action(
                      icon: Icons.open_in_new,
                      label: strings.openFile,
                      onTap: onOpenFile,
                    ),
                    action(
                      icon: Icons.ios_share,
                      label: strings.shareFile,
                      onTap: onShareFile,
                    ),
                    action(
                      icon: Icons.restart_alt,
                      label: strings.redownload,
                      onTap: onRedownload,
                    ),
                    if (task.canPause)
                      action(
                        icon: Icons.pause,
                        label: strings.pause,
                        onTap: onPause,
                      ),
                    if (task.canRun)
                      action(
                        icon: Icons.play_arrow,
                        label: task.state == DownloadState.paused
                            ? strings.resume
                            : strings.start,
                        onTap: onStart,
                      ),
                    action(
                      icon: Icons.delete_outline,
                      label: strings.remove,
                      onTap: onRemove,
                      destructive: true,
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class TaskActionButton extends StatelessWidget {
  const TaskActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foreground = destructive ? colorScheme.error : colorScheme.onSurface;

    return Material(
      color: destructive
          ? colorScheme.errorContainer.withValues(alpha: 0.22)
          : colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 18, color: foreground),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TaskPropertiesSheet extends StatelessWidget {
  const TaskPropertiesSheet({
    required this.strings,
    required this.task,
    required this.filePath,
    super.key,
  });

  final AppStrings strings;
  final DownloadTask task;
  final String filePath;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        children: [
          Text(
            strings.properties,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 12),
          PropertyRow(
            label: strings.fileName,
            value: _taskOutputFileName(task),
          ),
          PropertyRow(label: strings.sourceLink, value: task.source),
          PropertyRow(label: strings.outputPath, value: filePath),
          PropertyRow(
            label: strings.protocol,
            value: protocolLabel(task.protocol),
          ),
          PropertyRow(label: strings.fileSize, value: _formatBytePair(task)),
          PropertyRow(
            label: strings.startTime,
            value: _formatDateTime(task.startedAt),
          ),
          PropertyRow(
            label: strings.endTime,
            value: _formatDateTime(task.finishedAt),
          ),
          PropertyRow(
            label: strings.totalElapsed,
            value: _formatDuration(task.elapsed),
          ),
          PropertyRow(
            label: _speedTooltip(strings, task),
            value: _formatSpeed(_visibleSpeedBytesPerSecond(task)),
          ),
          if (task.error != null && task.error!.trim().isNotEmpty)
            PropertyRow(label: strings.errorMessage, value: task.error!),
        ],
      ),
    );
  }
}

class PropertyRow extends StatelessWidget {
  const PropertyRow({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: textTheme.labelMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

DownloadState _taskVisualState(DownloadTask task) {
  if (task.state == DownloadState.running) {
    return DownloadState.running;
  }
  return task.state;
}

Color _taskStateBackground(DownloadState state, ColorScheme colorScheme) {
  return switch (state) {
    DownloadState.running => const Color(0xffe3f3f1),
    DownloadState.finished => const Color(0xffe8f4ec),
    DownloadState.failed => const Color(0xffffece7),
    DownloadState.paused => const Color(0xfffff3d8),
    DownloadState.queued => colorScheme.surfaceContainerLow,
  };
}

Color _taskProgressFill(ColorScheme colorScheme) {
  return colorScheme.primaryContainer.withValues(alpha: 0.72);
}

Color _taskStateBorder(DownloadState state, ColorScheme colorScheme) {
  return switch (state) {
    DownloadState.running => colorScheme.primary.withValues(alpha: 0.45),
    DownloadState.finished => const Color(0xff80b991),
    DownloadState.failed => colorScheme.error.withValues(alpha: 0.42),
    DownloadState.paused => const Color(0xffd8a634),
    DownloadState.queued => colorScheme.outlineVariant.withValues(alpha: 0.72),
  };
}

Color _taskStateAccent(DownloadState state, ColorScheme colorScheme) {
  return switch (state) {
    DownloadState.running => colorScheme.primary,
    DownloadState.finished => const Color(0xff1d7a3d),
    DownloadState.failed => colorScheme.error,
    DownloadState.paused => const Color(0xff946400),
    DownloadState.queued => colorScheme.onSurfaceVariant,
  };
}

String _formatBytePair(DownloadTask task) {
  final total = task.totalBytes;
  if (total == null) {
    return '${formatBytes(task.downloadedBytes)} / --';
  }
  return '${formatBytes(task.downloadedBytes)} / ${formatBytes(total)}';
}

String _taskOutputFileName(DownloadTask task) {
  if (task.protocol != 'm3u8') {
    return task.fileName;
  }
  final extension = p.extension(task.fileName).toLowerCase();
  if (extension == '.mp4') {
    return task.fileName;
  }
  return '${p.basenameWithoutExtension(task.fileName)}.mp4';
}
