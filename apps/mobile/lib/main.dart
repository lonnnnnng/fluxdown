import 'dart:async';
import 'dart:convert';
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
import 'package:url_launcher/url_launcher.dart';

import 'src/download_controller.dart';
import 'src/download_defaults.dart';
import 'src/download_task.dart';
import 'src/mobile_torrent.dart';
import 'src/mobile_update.dart';
import 'src/protocol_e2e_runner.dart';
import 'src/protocol.dart';

const _protocolE2eAutoRun = bool.fromEnvironment('FLUXDOWN_E2E_AUTO_RUN');

void main() {
  // 作者: long
  // simulator 下载自检只在构建时显式打开，普通用户启动仍进入完整移动端界面。
  if (_protocolE2eAutoRun) {
    WidgetsFlutterBinding.ensureInitialized();
    runApp(const SizedBox.shrink());
    unawaited(_runProtocolE2eAndExit());
    return;
  }

  runApp(const FluxDownMobileApp());
}

Future<void> _runProtocolE2eAndExit() async {
  var exitStatus = 0;
  IOSink? outputSink;
  void emitLine(String line) {
    stdout.writeln(line);
    outputSink?.writeln(line);
  }

  try {
    final outputPath = Platform.environment['FLUXDOWN_E2E_OUTPUT_PATH']?.trim();
    if (outputPath != null && outputPath.isNotEmpty) {
      final outputFile = File(outputPath);
      await outputFile.parent.create(recursive: true);
      outputSink = outputFile.openWrite(mode: FileMode.write);
    }

    final result = await runProtocolE2e(emitLine: emitLine);
    if (result.failures.isNotEmpty) {
      exitStatus = 1;
    }
    emitLine(
      'FLUXDOWN_E2E_STATUS ${jsonEncode({'exitStatus': exitStatus, 'failures': result.failures})}',
    );
  } catch (error, stackTrace) {
    exitStatus = 1;
    emitLine(
      'FLUXDOWN_E2E_FATAL ${jsonEncode({'error': error.toString(), 'stack': stackTrace.toString()})}',
    );
  } finally {
    await outputSink?.flush();
    await outputSink?.close();
    await stdout.flush();
    await stderr.flush();
    exit(exitStatus);
  }
}

const _outputFolderPreferenceKey = 'fluxdown.outputFolder';
const _queueConcurrencyPreferenceKey = 'fluxdown.queueConcurrency';
const _downloadThreadCountPreferenceKey = 'fluxdown.downloadThreadCount';
const _retryAttemptsPreferenceKey = 'fluxdown.retryAttempts';
const _speedLimitKbpsPreferenceKey = 'fluxdown.speedLimitKbps';
const _storageChannel = MethodChannel('dev.fluxdown.mobile/storage');

enum AppLanguage { zh, en }

enum QueueFilter { all, unfinished, ended, failed }

enum MobileHomeTab { tasks, settings }

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
  String get tabQueue => language == AppLanguage.zh ? '任务' : 'Tasks';
  String get tabProtocols => language == AppLanguage.zh ? '协议' : 'Protocols';
  String get tabSettings => language == AppLanguage.zh ? '设置' : 'Settings';
  String get overview => language == AppLanguage.zh ? '概览' : 'Overview';
  String get newDownload =>
      language == AppLanguage.zh ? '新建下载' : 'New download';
  String get newTask => language == AppLanguage.zh ? '新建任务' : 'New task';
  String get createTask =>
      language == AppLanguage.zh ? '开始下载' : 'Start download';
  String get startDownload =>
      language == AppLanguage.zh ? '开始下载' : 'Start download';
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
      language == AppLanguage.zh ? '保存位置' : 'Save location';
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
  String get torrentFolder =>
      language == AppLanguage.zh ? '任务文件夹' : 'Task folder';
  String get torrentFolderHint => language == AppLanguage.zh
      ? '种子和磁力链接按文件夹组织，勾选的文件会参与下载。'
      : 'Torrent and magnet tasks are organized as folders. Checked files are downloaded.';
  String get torrentFileList =>
      language == AppLanguage.zh ? '文件列表' : 'File list';
  String get selectedFile => language == AppLanguage.zh ? '已选择' : 'Selected';
  String get notSelectedFile =>
      language == AppLanguage.zh ? '未选择' : 'Not selected';
  String get selectAll => language == AppLanguage.zh ? '全选' : 'Select all';
  String get selectNone => language == AppLanguage.zh ? '全不选' : 'Select none';
  String get confirmSelection =>
      language == AppLanguage.zh ? '确认选择' : 'Confirm';
  String get confirm => language == AppLanguage.zh ? '确定' : 'OK';
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
  String get torrentFileMetricsUnavailable => language == AppLanguage.zh
      ? '下载中数据由 libtorrent 管理'
      : 'Managed by libtorrent while downloading';
  String get downloadedSize =>
      language == AppLanguage.zh ? '已下载' : 'Downloaded';
  String get metadataDirectory =>
      language == AppLanguage.zh ? '资源目录' : 'Resource folder';
  String get resourceDetails =>
      language == AppLanguage.zh ? '资源详情' : 'Resource details';
  String get add => language == AppLanguage.zh ? '添加' : 'Add';
  String get queue => language == AppLanguage.zh ? '队列' : 'Queue';
  String get currentSource =>
      language == AppLanguage.zh ? '当前下载源' : 'Current source';
  String get concurrency => language == AppLanguage.zh ? '并发' : 'Parallel';
  String get settings => language == AppLanguage.zh ? '设置' : 'Settings';
  String get exitAppTitle => language == AppLanguage.zh ? '退出应用' : 'Exit app';
  String get exitAppMessage => language == AppLanguage.zh
      ? '确定要退出 FluxDown 吗？未完成的任务会保留在队列中。'
      : 'Exit FluxDown? Unfinished tasks will remain in the queue.';
  String get stayInApp => language == AppLanguage.zh ? '留在应用' : 'Stay';
  String get exitApp => language == AppLanguage.zh ? '退出' : 'Exit';
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
      language == AppLanguage.zh ? '最大并发' : 'Max concurrency';
  String get concurrencySettingHint =>
      language == AppLanguage.zh ? '同时运行任务数' : 'Active tasks at the same time';
  String get downloadThreadsSetting =>
      language == AppLanguage.zh ? '最大下载线程' : 'Max download threads';
  String get downloadThreadsHint =>
      language == AppLanguage.zh ? '单任务线程数' : 'Threads per task';
  String get retryAttemptsSetting =>
      language == AppLanguage.zh ? '自动重试数' : 'Automatic retries';
  String get retryAttemptsHint => language == AppLanguage.zh
      ? '失败重试 0-10，默认 3，0 不重试'
      : '0-10 retries, default 3; 0 disables';
  String get speedLimitSetting =>
      language == AppLanguage.zh ? '最大下载网速' : 'Max download speed';
  String get speedLimitHint =>
      language == AppLanguage.zh ? 'MB/s，留空不限速' : 'MB/s, blank means unlimited';
  String get currentVersion =>
      language == AppLanguage.zh ? '当前版本' : 'Current version';
  String get checkForUpdates =>
      language == AppLanguage.zh ? '检查更新' : 'Check for updates';
  String get checkingForUpdates =>
      language == AppLanguage.zh ? '正在检查更新...' : 'Checking for updates...';
  String get alreadyLatestVersion =>
      language == AppLanguage.zh ? '已是最新版本' : 'You are up to date';
  String latestVersionFound(String version) => language == AppLanguage.zh
      ? '找到最新版本 $version'
      : 'Latest version $version is available';
  String get downloadUpdate =>
      language == AppLanguage.zh ? '下载更新' : 'Download update';
  String get openDownloadPage =>
      language == AppLanguage.zh ? '打开下载页' : 'Open download page';
  String get updateCheckFailed => language == AppLanguage.zh
      ? '检查更新失败，请稍后重试。'
      : 'Could not check for updates. Please try again later.';
  String get updateApkUnavailable => language == AppLanguage.zh
      ? '暂未找到 Android 安装包，请打开下载页查看可用资源。'
      : 'No Android package was found. Open the download page to see available assets.';
  String get updateNotes =>
      language == AppLanguage.zh ? '更新说明' : 'Release notes';
  String get openDownloadPageFailed => language == AppLanguage.zh
      ? '无法打开下载页，请稍后重试。'
      : 'Could not open the download page. Please try again later.';
  String get hlsVariantSetting =>
      language == AppLanguage.zh ? 'HLS 清晰度编号' : 'HLS variant index';
  String get hlsVariantHint => language == AppLanguage.zh
      ? '主播放列表从 0 开始；留空使用第一个'
      : 'Zero-based master playlist index; blank uses the first';
  String get hlsKeepTsSetting =>
      language == AppLanguage.zh ? '保留 HLS 原始 TS' : 'Keep HLS transport stream';
  String get hlsVariantInvalid => language == AppLanguage.zh
      ? 'HLS 清晰度编号必须是大于等于 0 的整数。'
      : 'HLS variant index must be a non-negative integer.';
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
  String get queueUnfinished =>
      language == AppLanguage.zh ? '未完成' : 'Unfinished';
  String get queueEnded => language == AppLanguage.zh ? '已结束' : 'Ended';
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
  String get waitingStart =>
      language == AppLanguage.zh ? '等待启动' : 'Waiting to start';
  String get queuedAt => language == AppLanguage.zh ? '加入队列' : 'Queued';
  String get handedOffAt => language == AppLanguage.zh ? '移交时间' : 'Handed off';
  String get failedAt => language == AppLanguage.zh ? '失败时间' : 'Failed';
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
  String get openFile => language == AppLanguage.zh ? '显示文件' : 'Show file';
  String get shareFile => language == AppLanguage.zh ? '分享' : 'Share';
  String get retry => language == AppLanguage.zh ? '重试' : 'Retry';
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
  String get fileFormat => language == AppLanguage.zh ? '文件格式' : 'File format';
  String get unknownFileFormat => language == AppLanguage.zh ? '未知' : 'Unknown';
  String get protocol => language == AppLanguage.zh ? '协议' : 'Protocol';
  String get sourceRequired =>
      language == AppLanguage.zh ? '下载源不能为空。' : 'Source is required.';
  String get sha256Invalid => language == AppLanguage.zh
      ? 'SHA-256 需要是 64 位十六进制。'
      : 'SHA-256 must be 64 hex characters.';
  String get outputFolderSettingRequired => language == AppLanguage.zh
      ? '请先在设置页选择下载目录。'
      : 'Choose a download folder in Settings first.';
  String queueComplete(int finished, int failed) => language == AppLanguage.zh
      ? '队列完成：$finished 个完成，$failed 个失败。'
      : 'Queue complete: $finished finished, $failed failed.';

  String backendLabel(String protocol) {
    if (protocol == 'unknown') return planned;
    if (protocol == 'ed2k') {
      return language == AppLanguage.zh ? '移动端移交' : 'Mobile handoff';
    }
    return language == AppLanguage.zh ? '移动端内建' : 'Built-in mobile';
  }

  String stateLabel(DownloadState state) {
    return switch (state) {
      DownloadState.queued => language == AppLanguage.zh ? '排队中' : 'queued',
      DownloadState.running => language == AppLanguage.zh ? '下载中' : 'running',
      DownloadState.paused => language == AppLanguage.zh ? '已暂停' : 'paused',
      DownloadState.handedOff =>
        language == AppLanguage.zh ? '已移交' : 'handed off',
      DownloadState.finished => language == AppLanguage.zh ? '已完成' : 'finished',
      DownloadState.failed => language == AppLanguage.zh ? '失败' : 'failed',
    };
  }
}

int clampQueueConcurrency(int value) =>
    value.clamp(minQueueConcurrency, maxQueueConcurrency).toInt();

int clampDownloadThreadCount(int value) =>
    value.clamp(minDownloadThreadCount, maxDownloadThreadCount).toInt();

int clampRetryAttempts(int value) =>
    value.clamp(minRetryAttempts, maxRetryAttempts).toInt();

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
          seedColor: const Color(0xff2f9ee6),
          primary: const Color(0xff168bd1),
          secondary: const Color(0xff0f6fa8),
          tertiary: const Color(0xff52b6e8),
          surface: const Color(0xfff5faff),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xfff5faff),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xfff5faff),
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0x2a168bd1)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xffcfe5f3)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xffcfe5f3)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xff168bd1), width: 1.6),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xff168bd1),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle: const TextStyle(fontWeight: FontWeight.w400),
          ),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: Color(0xff168bd1),
          foregroundColor: Colors.white,
          shape: CircleBorder(),
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
  var queueConcurrency = defaultQueueConcurrency;
  var downloadThreadCount = defaultDownloadThreadCount;
  var retryAttempts = defaultRetryAttempts;
  var speedLimitKbps = 0;
  StorageStats? settingsStorageStats;
  var settingsStorageLoading = false;
  var settingsStorageUnavailable = false;
  var settingsStorageRequestId = 0;
  var queueFilter = QueueFilter.all;
  var currentTab = MobileHomeTab.tasks;
  var updateChecking = false;
  var _exitDialogShowing = false;

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
    unawaited(refreshSettingsStorageStats());
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
          ? defaultQueueConcurrency
          : clampQueueConcurrency(savedConcurrency);
      downloadThreadCount = savedThreadCount == null
          ? defaultDownloadThreadCount
          : clampDownloadThreadCount(savedThreadCount);
      retryAttempts = savedRetryAttempts == null
          ? defaultRetryAttempts
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
    String? expectedSha256,
    int? hlsVariantIndex,
    bool hlsKeepTransportStream = false,
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
      expectedSha256: expectedSha256,
      hlsVariantIndex: hlsVariantIndex,
      hlsKeepTransportStream: hlsKeepTransportStream,
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
        onReadClipboard: readClipboardSource,
        onScanQr: scanQrSource,
        onLoadStorageStats: loadStorageStats,
        onInspectTorrentMetadata: inspectTorrentMetadataFromSource,
        onCreate: createTask,
      ),
    );
  }

  Future<void> checkForUpdates() async {
    if (updateChecking || !mounted) return;
    setState(() {
      updateChecking = true;
    });
    try {
      final report = await MobileUpdateChecker().check();
      if (!mounted) return;
      setState(() {
        updateChecking = false;
      });
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => MobileUpdateResultDialog(
          strings: strings,
          report: report,
          onDownloadUpdate: report.downloadUrl == null
              ? null
              : () {
                  Navigator.of(dialogContext).pop();
                  unawaited(_openUpdateUrl(report.downloadUrl!));
                },
          onOpenDownloadPage: () {
            Navigator.of(dialogContext).pop();
            unawaited(_openUpdateUrl(report.releaseUrl));
          },
        ),
      );
    } on MobileUpdateException catch (error) {
      if (!mounted) return;
      setState(() {
        updateChecking = false;
      });
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            strings.checkForUpdates,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w400),
          ),
          content: Text(
            error.message,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w400),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(strings.confirm),
            ),
          ],
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        updateChecking = false;
      });
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            strings.checkForUpdates,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w400),
          ),
          content: Text(
            strings.updateCheckFailed,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w400),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(strings.confirm),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          updateChecking = false;
        });
      }
    }
  }

  Future<void> _openUpdateUrl(String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) _showSnack(strings.openDownloadPageFailed);
    }
  }

  Future<String?> readClipboardSource() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final value = data?.text?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  Future<String?> scanQrSource() {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => QrScannerPage(strings: strings)),
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
      await refreshSettingsStorageStats();
      _showSnack(strings.folderSelected);
    } catch (_) {
      if (mounted) {
        _showSnack(strings.folderSelectionFailed);
      }
    }
  }

  Future<void> refreshSettingsStorageStats() async {
    final requestId = ++settingsStorageRequestId;
    final path = outputController.text.trim();
    if (mounted) {
      setState(() {
        settingsStorageLoading = true;
        settingsStorageUnavailable = false;
      });
    }
    final stats = path.isEmpty ? null : await loadStorageStats(path);
    if (!mounted || requestId != settingsStorageRequestId) return;
    setState(() {
      settingsStorageStats = stats;
      settingsStorageLoading = false;
      settingsStorageUnavailable = stats == null;
    });
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

  void showTorrentFolder(DownloadTask task) {
    if (!task.hasTorrentFolder) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TorrentFolderPage(
          strings: strings,
          controller: controller,
          task: task,
        ),
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

  Future<void> _confirmExit() async {
    if (_exitDialogShowing || !mounted) return;
    _exitDialogShowing = true;
    try {
      final shouldExit = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            strings.exitAppTitle,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w400),
          ),
          content: Text(
            strings.exitAppMessage,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w400),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(strings.stayInApp),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(strings.exitApp),
            ),
          ],
        ),
      );
      if (shouldExit == true && mounted) {
        // 作者: long
        // 根页面确认退出后交给系统关闭应用，未完成任务由控制器的持久化状态负责恢复。
        await SystemNavigator.pop();
      }
    } finally {
      _exitDialogShowing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = controller.tasks;
    final settingsView = SettingsView(
      strings: strings,
      language: widget.language,
      queueConcurrency: queueConcurrency,
      downloadThreadCount: downloadThreadCount,
      retryAttempts: retryAttempts,
      speedLimitKbps: speedLimitKbps,
      outputFolderListenable: outputController,
      currentVersion: mobileAppVersion,
      updateChecking: updateChecking,
      onLanguageChanged: widget.onLanguageChanged,
      onConcurrencyChanged: setQueueConcurrency,
      onDownloadThreadCountChanged: setDownloadThreadCount,
      onRetryAttemptsChanged: setRetryAttempts,
      onSpeedLimitChanged: setSpeedLimitKbps,
      onCheckForUpdates: checkForUpdates,
      onPickOutputFolder: pickOutputFolder,
      storageStats: settingsStorageStats,
      storageLoading: settingsStorageLoading,
      storageUnavailable: settingsStorageUnavailable,
    );

    // 作者: long
    // 一级页面没有可返回的上级路由，系统返回和边缘返回都先确认，避免误触退出应用。
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_confirmExit());
      },
      child: Scaffold(
        body: SafeArea(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : IndexedStack(
                  index: currentTab.index,
                  children: [
                    QueueView(
                      strings: strings,
                      tasks: tasks,
                      filter: queueFilter,
                      onFilterChanged: (value) => setState(() {
                        queueFilter = value;
                      }),
                      onStartTask: startTask,
                      onPauseTask: pauseTask,
                      onRemoveTask: removeTask,
                      onCopySource: copyTaskSource,
                      onShowProperties: showTaskProperties,
                      onOpenTaskDetails: showTorrentFolder,
                      onOpenFile: openTaskFile,
                      onShareFile: shareTaskFile,
                      onRedownloadTask: redownloadTask,
                    ),
                    settingsView,
                  ],
                ),
        ),
        floatingActionButton: loading || currentTab != MobileHomeTab.tasks
            ? null
            : FloatingActionButton(
                onPressed: showNewTaskDialog,
                tooltip: strings.newTask,
                child: const Icon(Icons.add),
              ),
        bottomNavigationBar: loading
            ? null
            : CompactHomeNavigationBar(
                selectedIndex: currentTab.index,
                onDestinationSelected: (index) {
                  setState(() {
                    currentTab = MobileHomeTab.values[index];
                  });
                },
                destinations: [
                  CompactHomeNavigationDestination(
                    icon: Icons.download_outlined,
                    selectedIcon: Icons.download,
                    label: strings.tabQueue,
                  ),
                  CompactHomeNavigationDestination(
                    icon: Icons.settings_outlined,
                    selectedIcon: Icons.settings,
                    label: strings.tabSettings,
                  ),
                ],
              ),
      ),
    );
  }
}

class CompactHomeNavigationDestination {
  const CompactHomeNavigationDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

class CompactHomeNavigationBar extends StatelessWidget {
  const CompactHomeNavigationBar({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    super.key,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<CompactHomeNavigationDestination> destinations;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Material(
      color: Colors.white,
      child: SizedBox(
        height: 26 + bottomInset,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 26,
              child: SizedBox(key: ValueKey('compact-home-navigation-bar')),
            ),
            Positioned.fill(
              child: Row(
                children: [
                  for (var index = 0; index < destinations.length; index++)
                    Expanded(
                      child: _CompactHomeNavigationItem(
                        destination: destinations[index],
                        selected: selectedIndex == index,
                        colorScheme: colorScheme,
                        onTap: () => onDestinationSelected(index),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactHomeNavigationItem extends StatelessWidget {
  const _CompactHomeNavigationItem({
    required this.destination,
    required this.selected,
    required this.colorScheme,
    required this.onTap,
  });

  final CompactHomeNavigationDestination destination;
  final bool selected;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? colorScheme.primary : Colors.black;

    return Semantics(
      button: true,
      selected: selected,
      label: destination.label,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('compact-home-navigation-item-${destination.label}'),
        onTap: onTap,
        splashFactory: NoSplash.splashFactory,
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: 26,
            child: Transform.translate(
              offset: const Offset(0, 10),
              child: Center(
                child: OverflowBox(
                  minHeight: 0,
                  maxHeight: double.infinity,
                  alignment: Alignment.center,
                  // 作者: long
                  // 图标和文字共用同一个选中容器与前景色，让菜单状态作为整体变化而不是只突出图标。
                  child: SizedBox(
                    key: ValueKey(
                      'compact-home-navigation-indicator-${destination.label}',
                    ),
                    width: 64,
                    height: 33,
                    child: Center(
                      child: Column(
                        key: ValueKey(
                          'compact-home-navigation-content-${destination.label}',
                        ),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            selected
                                ? destination.selectedIcon
                                : destination.icon,
                            size: 18,
                            color: foreground,
                          ),
                          Text(
                            destination.label,
                            key: ValueKey(
                              'compact-home-navigation-label-${destination.label}',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: foreground,
                              fontSize: 10.5,
                              height: 1,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
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

class QueueView extends StatelessWidget {
  const QueueView({
    required this.strings,
    required this.tasks,
    required this.filter,
    required this.onFilterChanged,
    required this.onStartTask,
    required this.onPauseTask,
    required this.onRemoveTask,
    required this.onCopySource,
    required this.onShowProperties,
    required this.onOpenTaskDetails,
    required this.onOpenFile,
    required this.onShareFile,
    required this.onRedownloadTask,
    super.key,
  });

  final AppStrings strings;
  final List<DownloadTask> tasks;
  final QueueFilter filter;
  final ValueChanged<QueueFilter> onFilterChanged;
  final ValueChanged<String> onStartTask;
  final ValueChanged<String> onPauseTask;
  final ValueChanged<String> onRemoveTask;
  final ValueChanged<DownloadTask> onCopySource;
  final ValueChanged<DownloadTask> onShowProperties;
  final ValueChanged<DownloadTask> onOpenTaskDetails;
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
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  strings.tabQueue,
                  key: const ValueKey('queue-page-title'),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontSize: 18,
                    height: 1,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
              const SizedBox(height: 6),
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
                      onOpenDetails: () => onOpenTaskDetails(task),
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
      QueueFilter.unfinished =>
        task.state == DownloadState.running ||
            task.state == DownloadState.queued ||
            task.state == DownloadState.paused,
      QueueFilter.ended =>
        task.state == DownloadState.finished ||
            task.state == DownloadState.handedOff,
      QueueFilter.failed => task.state == DownloadState.failed,
    };
  }
}

class NewTaskDialog extends StatefulWidget {
  const NewTaskDialog({
    required this.strings,
    required this.defaultOutputFolder,
    required this.onPickOutputFolder,
    required this.onReadClipboard,
    required this.onScanQr,
    required this.onLoadStorageStats,
    required this.onInspectTorrentMetadata,
    required this.onCreate,
    super.key,
  });

  final AppStrings strings;
  final String defaultOutputFolder;
  final Future<String?> Function() onPickOutputFolder;
  final Future<String?> Function() onReadClipboard;
  final Future<String?> Function() onScanQr;
  final Future<StorageStats?> Function(String path) onLoadStorageStats;
  final Future<TorrentMetadata?> Function(String source)
  onInspectTorrentMetadata;
  final Future<bool> Function({
    required String source,
    required String outputFolder,
    String? fileName,
    String? torrentName,
    List<TorrentFileEntry> torrentFiles,
    List<int>? selectedTorrentFileIndexes,
    String? expectedSha256,
    int? hlsVariantIndex,
    bool hlsKeepTransportStream,
  })
  onCreate;

  @override
  State<NewTaskDialog> createState() => _NewTaskDialogState();
}

class _NewTaskDialogState extends State<NewTaskDialog> {
  final sourceController = TextEditingController();
  final fileNameController = TextEditingController();
  final outputFolderController = TextEditingController();
  final sha256Controller = TextEditingController();
  final hlsVariantController = TextEditingController();
  var busy = false;
  String? errorText;
  var fileNameEdited = false;
  var hlsKeepTransportStream = false;
  StorageStats? storageStats;
  var storageLoading = false;
  var storageUnavailable = false;
  var storageRequestId = 0;

  AppStrings get strings => widget.strings;

  @override
  void initState() {
    super.initState();
    outputFolderController.text = widget.defaultOutputFolder;
    unawaited(refreshStorageStats());
  }

  @override
  void dispose() {
    sourceController.dispose();
    fileNameController.dispose();
    outputFolderController.dispose();
    sha256Controller.dispose();
    hlsVariantController.dispose();
    super.dispose();
  }

  Future<void> createFromInput() async {
    await createFromSource(sourceController.text);
  }

  Future<void> pickOutputFolder() async {
    final selected = await widget.onPickOutputFolder();
    if (!mounted || selected == null || selected.trim().isEmpty) return;
    setState(() {
      outputFolderController.text = selected.trim();
    });
    await refreshStorageStats();
  }

  Future<void> pasteSource() async {
    final source = await widget.onReadClipboard();
    if (!mounted) return;
    if (source == null || source.trim().isEmpty) {
      setState(() => errorText = strings.clipboardEmpty);
      return;
    }
    setSource(source);
  }

  Future<void> scanSource() async {
    final source = await widget.onScanQr();
    if (!mounted || source == null || source.trim().isEmpty) return;
    setSource(source);
  }

  void setSource(String source) {
    final normalized = source.trim();
    sourceController.value = TextEditingValue(
      text: normalized,
      selection: TextSelection.collapsed(offset: normalized.length),
    );
    syncSuggestedFileName(normalized);
    setState(() => errorText = null);
  }

  Future<void> refreshStorageStats() async {
    final requestId = ++storageRequestId;
    final path = outputFolderController.text.trim();
    if (mounted) {
      setState(() {
        storageLoading = true;
        storageUnavailable = false;
      });
    }
    final stats = path.isEmpty ? null : await widget.onLoadStorageStats(path);
    if (!mounted || requestId != storageRequestId) return;
    setState(() {
      storageStats = stats;
      storageLoading = false;
      storageUnavailable = stats == null;
    });
  }

  Future<void> createFromSource(String source) async {
    final normalized = source.trim();
    if (normalized.isEmpty) {
      setState(() {
        errorText = strings.sourceRequired;
      });
      return;
    }
    final expectedSha256 = normalizeSha256Text(sha256Controller.text);
    if (expectedSha256 != null && !isValidSha256(expectedSha256)) {
      setState(() {
        errorText = strings.sha256Invalid;
      });
      return;
    }
    final protocol = detectProtocol(normalized);
    int? hlsVariantIndex;
    if (protocol == 'm3u8' && hlsVariantController.text.trim().isNotEmpty) {
      hlsVariantIndex = int.tryParse(hlsVariantController.text.trim());
      if (hlsVariantIndex == null || hlsVariantIndex < 0) {
        setState(() {
          errorText = strings.hlsVariantInvalid;
        });
        return;
      }
    }
    setState(() {
      busy = true;
      errorText = null;
    });
    var effectiveFileName = fileNameController.text;
    String? torrentName;
    var torrentFiles = const <TorrentFileEntry>[];
    List<int>? selectedTorrentFileIndexes;
    if (protocol == 'torrent' || protocol == 'magnet') {
      try {
        // 作者: long
        // Torrent/Magnet 的文件选择是新建参数，必须在写入队列前完成，取消时不会留下暂停的半成品任务。
        final metadata = await widget.onInspectTorrentMetadata(normalized);
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
        if (selection == null) {
          setState(() {
            busy = false;
          });
          return;
        }
        if (selection.selectedIndexes.isEmpty) {
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
      expectedSha256: expectedSha256,
      hlsVariantIndex: hlsVariantIndex,
      hlsKeepTransportStream: hlsKeepTransportStream,
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          // 作者: long
          // HLS 选项会按链接类型动态增加表单内容；限制弹框高度并允许滚动，避免小屏上保存按钮被挤出可视区域。
          constraints: BoxConstraints(
            maxWidth: 348,
            maxHeight: MediaQuery.sizeOf(context).height * 0.86,
          ),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              strings.newDownload,
                              style: textTheme.titleMedium?.copyWith(
                                fontSize: 17,
                                height: 1.1,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              strings.language == AppLanguage.zh
                                  ? '粘贴链接后自动识别类型，确认保存位置即可开始。'
                                  : 'Paste a link, confirm the folder, and start.',
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontSize: 11,
                                height: 1.25,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('new-task-paste'),
                        tooltip: strings.createFromClipboard,
                        onPressed: busy ? null : pasteSource,
                        icon: const Icon(
                          Icons.content_paste_outlined,
                          size: 17,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 32,
                          height: 34,
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('new-task-scan'),
                        tooltip: strings.scanQr,
                        onPressed: busy ? null : scanSource,
                        icon: const Icon(Icons.qr_code_scanner, size: 17),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 32,
                          height: 34,
                        ),
                      ),
                      IconButton(
                        tooltip: strings.close,
                        onPressed: busy
                            ? null
                            : () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close, size: 18),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 34,
                          height: 34,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const ValueKey('new-task-source'),
                    controller: sourceController,
                    minLines: 3,
                    maxLines: 5,
                    enabled: !busy,
                    textInputAction: TextInputAction.done,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.16,
                      fontWeight: FontWeight.w400,
                    ),
                    decoration: InputDecoration(
                      labelText: strings.sourceLink,
                      alignLabelWithHint: true,
                      labelStyle: const TextStyle(fontSize: 12),
                      errorText: errorText,
                      errorStyle: const TextStyle(fontSize: 11.5),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
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
                  const SizedBox(height: 6),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: sourceController,
                    builder: (context, value, _) {
                      final protocol = detectProtocol(value.text.trim());
                      final detectedText = protocol == 'unknown'
                          ? (strings.language == AppLanguage.zh
                                ? '等待识别链接类型'
                                : 'Waiting for a supported link')
                          : '${protocolLabel(protocol)} · ${strings.backendLabel(protocol)}';

                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xffeaf6fd),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: colorScheme.primary.withValues(alpha: 0.16),
                          ),
                        ),
                        child: Row(
                          children: [
                            Text(
                              strings.language == AppLanguage.zh
                                  ? '自动识别'
                                  : 'Auto',
                              style: textTheme.labelSmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                detectedText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.labelMedium?.copyWith(
                                  color: colorScheme.primary,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                            ),
                            Icon(
                              Icons.check,
                              size: 15,
                              color: colorScheme.primary,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const ValueKey('new-task-file-name'),
                    controller: fileNameController,
                    enabled: !busy,
                    textInputAction: TextInputAction.next,
                    style: const TextStyle(fontSize: 12, height: 1.12),
                    decoration: InputDecoration(
                      labelText: strings.fileName,
                      labelStyle: const TextStyle(fontSize: 12),
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
                    key: const ValueKey('new-task-output-folder'),
                    controller: outputFolderController,
                    enabled: !busy,
                    textInputAction: TextInputAction.done,
                    style: const TextStyle(fontSize: 12, height: 1.12),
                    decoration: InputDecoration(
                      labelText: strings.outputFolder,
                      labelStyle: const TextStyle(fontSize: 12),
                      suffixIcon: IconButton(
                        key: const ValueKey('new-task-pick-folder'),
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
                    onChanged: (_) => unawaited(refreshStorageStats()),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const ValueKey('new-task-sha256'),
                    controller: sha256Controller,
                    enabled: !busy,
                    textInputAction: TextInputAction.next,
                    style: const TextStyle(fontSize: 12, height: 1.12),
                    decoration: InputDecoration(
                      labelText: strings.language == AppLanguage.zh
                          ? 'SHA-256 校验（可选，64 位十六进制）'
                          : 'SHA-256 (optional, 64 hex chars)',
                      labelStyle: const TextStyle(fontSize: 12),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                    ),
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: sourceController,
                    builder: (context, value, _) {
                      if (detectProtocol(value.text.trim()) != 'm3u8') {
                        return const SizedBox.shrink();
                      }
                      return Column(
                        children: [
                          const SizedBox(height: 8),
                          TextField(
                            key: const ValueKey('new-task-hls-variant'),
                            controller: hlsVariantController,
                            enabled: !busy,
                            keyboardType: TextInputType.number,
                            textInputAction: TextInputAction.next,
                            style: const TextStyle(fontSize: 12, height: 1.12),
                            decoration: InputDecoration(
                              labelText: strings.hlsVariantSetting,
                              helperText: strings.hlsVariantHint,
                              helperStyle: const TextStyle(fontSize: 10),
                              labelStyle: const TextStyle(fontSize: 12),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                            ),
                          ),
                          SwitchListTile.adaptive(
                            key: const ValueKey('new-task-hls-keep-ts'),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              strings.hlsKeepTsSetting,
                              style: const TextStyle(fontSize: 12),
                            ),
                            value: hlsKeepTransportStream,
                            onChanged: busy
                                ? null
                                : (value) => setState(
                                    () => hlsKeepTransportStream = value,
                                  ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  StorageStatsPanel(
                    key: const ValueKey('new-task-storage-stats'),
                    strings: strings,
                    stats: storageStats,
                    loading: storageLoading,
                    unavailable: storageUnavailable,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const ValueKey('new-task-submit'),
                    onPressed: busy ? null : createFromInput,
                    icon: busy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_outlined, size: 17),
                    label: Text(
                      strings.startDownload,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: FilledButton.styleFrom(
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                      ),
                      minimumSize: const Size.fromHeight(44),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ],
              ),
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
        key: const ValueKey('torrent-file-selection-dialog'),
        insetPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 作者: long
            // 种子和磁力链接的内容确认需要对比大量文件，弹框占满安全区内的可用空间，仅保留必要边距。
            return SizedBox(
              width: constraints.maxWidth,
              height: constraints.maxHeight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(
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
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ),
                        Text(
                          strings.torrentSelectedCount(selectedIndexes.length),
                          style: textTheme.labelSmall?.copyWith(
                            color: colorScheme.primary,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      strings.selectTorrentFilesHint,
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 6),
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
                    Expanded(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: colorScheme.outlineVariant),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ListView.separated(
                          key: const ValueKey('torrent-file-list'),
                          itemCount: files.length,
                          separatorBuilder: (context, index) => Divider(
                            height: 1,
                            thickness: 1,
                            color: colorScheme.outlineVariant,
                          ),
                          itemBuilder: (context, index) {
                            final file = files[index];
                            final selected = selectedIndexes.contains(
                              file.index,
                            );
                            final format = _torrentFileFormat(file.path);
                            return Material(
                              color: selected
                                  ? colorScheme.primaryContainer.withValues(
                                      alpha: 0.24,
                                    )
                                  : Colors.transparent,
                              child: InkWell(
                                key: ValueKey('torrent-file-${file.index}'),
                                onTap: () =>
                                    _setFileSelected(file.index, !selected),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    4,
                                    8,
                                    10,
                                    8,
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Checkbox(
                                        value: selected,
                                        onChanged: (value) => _setFileSelected(
                                          file.index,
                                          value == true,
                                        ),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      const SizedBox(width: 2),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              file.name,
                                              key: ValueKey(
                                                'torrent-file-name-${file.index}',
                                              ),
                                              softWrap: true,
                                              overflow: TextOverflow.visible,
                                              style: const TextStyle(
                                                fontSize: 12.5,
                                                height: 1.28,
                                                fontWeight: FontWeight.w400,
                                              ),
                                            ),
                                            if (file.path != file.name) ...[
                                              const SizedBox(height: 3),
                                              Text(
                                                file.path,
                                                key: ValueKey(
                                                  'torrent-file-path-${file.index}',
                                                ),
                                                softWrap: true,
                                                overflow: TextOverflow.visible,
                                                style: TextStyle(
                                                  fontSize: 10.5,
                                                  height: 1.25,
                                                  color: colorScheme
                                                      .onSurfaceVariant,
                                                  fontWeight: FontWeight.w400,
                                                ),
                                              ),
                                            ],
                                            const SizedBox(height: 5),
                                            Wrap(
                                              spacing: 12,
                                              runSpacing: 3,
                                              children: [
                                                Text(
                                                  '${strings.fileFormat}: ${format ?? strings.unknownFileFormat}',
                                                  key: ValueKey(
                                                    'torrent-file-format-${file.index}',
                                                  ),
                                                  style: TextStyle(
                                                    fontSize: 10.5,
                                                    color: colorScheme
                                                        .onSurfaceVariant,
                                                    fontWeight: FontWeight.w400,
                                                  ),
                                                ),
                                                Text(
                                                  '${strings.fileSize}: ${formatBytes(file.size)}',
                                                  key: ValueKey(
                                                    'torrent-file-size-${file.index}',
                                                  ),
                                                  style: TextStyle(
                                                    fontSize: 10.5,
                                                    color: colorScheme
                                                        .onSurfaceVariant,
                                                    fontWeight: FontWeight.w400,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
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
                            key: const ValueKey(
                              'torrent-file-selection-confirm',
                            ),
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
                                fontWeight: FontWeight.w400,
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
            );
          },
        ),
      ),
    );
  }

  void _setFileSelected(int index, bool selected) {
    setState(() {
      if (selected) {
        selectedIndexes.add(index);
      } else {
        selectedIndexes.remove(index);
      }
    });
  }
}

String? _torrentFileFormat(String filePath) {
  final extension = p.extension(filePath).replaceFirst('.', '').trim();
  if (extension.isEmpty) return null;
  return extension.toUpperCase();
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
              fontWeight: FontWeight.w400,
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
              fontWeight: FontWeight.w400,
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
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ],
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
                  fontWeight: FontWeight.w400,
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
      QueueFilter.unfinished: _countAny(const {
        DownloadState.running,
        DownloadState.queued,
        DownloadState.paused,
      }),
      QueueFilter.ended: _countAny(const {
        DownloadState.finished,
        DownloadState.handedOff,
      }),
      QueueFilter.failed: _count(DownloadState.failed),
    };

    return Container(
      height: 34,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: const Color(0xffe8f5fc),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          for (final filter in QueueFilter.values)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(left: filter.index == 0 ? 0 : 2),
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

  int _countAny(Set<DownloadState> states) {
    return tasks.where((task) => states.contains(task.state)).length;
  }

  String _label(QueueFilter filter) {
    return switch (filter) {
      QueueFilter.all => strings.queueAll,
      QueueFilter.unfinished => strings.queueUnfinished,
      QueueFilter.ended => strings.queueEnded,
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
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(6),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '$label($count)',
                  maxLines: 1,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 10.5,
                    fontWeight: selected ? FontWeight.w400 : FontWeight.w400,
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
          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w400),
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
    this.currentVersion = mobileAppVersion,
    this.updateChecking = false,
    required this.onLanguageChanged,
    required this.onConcurrencyChanged,
    required this.onDownloadThreadCountChanged,
    required this.onRetryAttemptsChanged,
    required this.onSpeedLimitChanged,
    this.onCheckForUpdates,
    required this.onPickOutputFolder,
    required this.storageStats,
    required this.storageLoading,
    required this.storageUnavailable,
    super.key,
  });

  final AppStrings strings;
  final AppLanguage language;
  final int queueConcurrency;
  final int downloadThreadCount;
  final int retryAttempts;
  final int speedLimitKbps;
  final ValueListenable<TextEditingValue> outputFolderListenable;
  final String currentVersion;
  final bool updateChecking;
  final ValueChanged<AppLanguage> onLanguageChanged;
  final ValueChanged<int> onConcurrencyChanged;
  final ValueChanged<int> onDownloadThreadCountChanged;
  final ValueChanged<int> onRetryAttemptsChanged;
  final ValueChanged<int> onSpeedLimitChanged;
  final VoidCallback? onCheckForUpdates;
  final VoidCallback onPickOutputFolder;
  final StorageStats? storageStats;
  final bool storageLoading;
  final bool storageUnavailable;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 88),
      children: [
        Text(
          strings.settings,
          key: const ValueKey('settings-page-title'),
          style: textTheme.titleLarge?.copyWith(
            fontSize: 18,
            height: 1,
            fontWeight: FontWeight.w400,
          ),
        ),
        const SizedBox(height: 6),
        SettingsGroupCard(
          children: [
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
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: outputFolderListenable,
              builder: (context, value, _) => StorageStatsPanel(
                key: const ValueKey('settings-storage-stats'),
                strings: strings,
                stats: storageStats,
                loading: storageLoading,
                unavailable: storageUnavailable,
              ),
            ),
            SettingsNumberInput(
              icon: Icons.download_outlined,
              title: strings.concurrencySetting,
              subtitle: strings.concurrencySettingHint,
              valueText: '$queueConcurrency',
              hintText: '$defaultQueueConcurrency',
              suffixText: language == AppLanguage.zh ? '个' : '',
              onSubmitted: (value) {
                final parsed = parseBoundedInteger(
                  value,
                  min: 1,
                  max: maxQueueConcurrency,
                );
                if (parsed != null) onConcurrencyChanged(parsed);
              },
            ),
            SettingsNumberInput(
              icon: Icons.settings_outlined,
              title: strings.downloadThreadsSetting,
              subtitle: strings.downloadThreadsHint,
              valueText: '$downloadThreadCount',
              hintText: '$defaultDownloadThreadCount',
              suffixText: language == AppLanguage.zh ? '线程' : '',
              onSubmitted: (value) {
                final parsed = parseBoundedInteger(
                  value,
                  min: 1,
                  max: maxDownloadThreadCount,
                );
                if (parsed != null) onDownloadThreadCountChanged(parsed);
              },
            ),
            SettingsNumberInput(
              icon: Icons.restart_alt,
              title: strings.retryAttemptsSetting,
              subtitle: strings.retryAttemptsHint,
              valueText: '$retryAttempts',
              hintText: '$defaultRetryAttempts',
              suffixText: language == AppLanguage.zh ? '次' : '',
              onSubmitted: (value) {
                final parsed = parseBoundedInteger(
                  value,
                  min: 0,
                  max: maxRetryAttempts,
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
              icon: Icons.info_outline,
              title: strings.currentVersion,
              subtitle: 'v$currentVersion',
              trailing: updateChecking
                  ? const SizedBox(
                      width: 38,
                      height: 38,
                      child: Center(
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  : IconButton(
                      key: const ValueKey('settings-check-updates'),
                      tooltip: strings.checkForUpdates,
                      onPressed: onCheckForUpdates,
                      icon: const Icon(Icons.system_update_alt, size: 16),
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

class MobileUpdateResultDialog extends StatelessWidget {
  const MobileUpdateResultDialog({
    required this.strings,
    required this.report,
    required this.onOpenDownloadPage,
    this.onDownloadUpdate,
    super.key,
  });

  final AppStrings strings;
  final MobileUpdateReport report;
  final VoidCallback onOpenDownloadPage;
  final VoidCallback? onDownloadUpdate;

  @override
  Widget build(BuildContext context) {
    final releaseNotes = report.releaseNotes?.trim();
    final message = report.hasUpdate
        ? strings.latestVersionFound('v${report.latestVersion}')
        : strings.alreadyLatestVersion;

    return AlertDialog(
      key: const ValueKey('mobile-update-dialog'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      title: Text(
        strings.currentVersion,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w400),
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
      content: SizedBox(
        width: double.infinity,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: (MediaQuery.sizeOf(context).height * 0.48)
                .clamp(260, 380)
                .toDouble(),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                if (report.hasUpdate && report.downloadFileName != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    report.downloadFileName!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
                if (report.hasUpdate && report.downloadUrl == null) ...[
                  const SizedBox(height: 8),
                  Text(
                    strings.updateApkUnavailable,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
                if (report.hasUpdate && releaseNotes != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    strings.updateNotes,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    releaseNotes,
                    key: const ValueKey('mobile-update-notes'),
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.35,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.end,
      actionsOverflowAlignment: OverflowBarAlignment.end,
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 8, 4),
      buttonPadding: const EdgeInsets.symmetric(horizontal: 6),
      actions: [
        if (report.hasUpdate)
          TextButton(
            key: const ValueKey('mobile-update-download'),
            onPressed: onDownloadUpdate,
            child: Text(strings.downloadUpdate),
          ),
        TextButton(
          key: const ValueKey('mobile-update-open-page'),
          onPressed: onOpenDownloadPage,
          child: Text(strings.openDownloadPage),
        ),
        TextButton(
          key: const ValueKey('mobile-update-confirm'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.confirm),
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
                    fontWeight: FontWeight.w400,
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.16)),
        boxShadow: [
          BoxShadow(
            color: colorScheme.primary.withValues(alpha: 0.045),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
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

  void commit({bool unfocus = true}) {
    final value = controller.text.trim();
    if (value.isNotEmpty || widget.allowEmpty) {
      widget.onSubmitted(value);
    }
    if (unfocus) {
      focusNode.unfocus();
    }
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
                fontWeight: FontWeight.w400,
              ),
              decoration: InputDecoration(
                hintText: widget.hintText,
                suffixText: widget.suffixText,
                suffixStyle: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w400,
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
              ),
              onChanged: (_) => commit(unfocus: false),
              onSubmitted: (_) => commit(),
              onEditingComplete: () => commit(),
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
                      fontWeight: FontWeight.w400,
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
                fontWeight: FontWeight.w400,
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
                    fontWeight: FontWeight.w400,
                    height: 1.08,
                  )
                : textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w400),
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
                  fontWeight: FontWeight.w400,
                ),
          ),
      ],
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.16)),
        boxShadow: [
          BoxShadow(
            color: colorScheme.primary.withValues(alpha: 0.045),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
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
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w400),
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

enum _TaskMenuAction { primary, openFile, copySource, redownload, remove }

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
    required this.onOpenDetails,
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
  final VoidCallback onOpenDetails;
  final VoidCallback onOpenFile;
  final VoidCallback onShareFile;
  final VoidCallback onRedownload;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final progress = _taskProgressValue(task);
    final visualState = _taskVisualState(task);
    final accentColor = _taskStateAccent(visualState, colorScheme);
    final backgroundColor = _taskStateBackground(visualState, colorScheme);

    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Card(
        clipBehavior: Clip.antiAlias,
        color: backgroundColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: _taskStateBorder(visualState, colorScheme)),
        ),
        child: InkWell(
          onTap: task.hasTorrentFolder
              ? onOpenDetails
              : task.canPause || task.canRun
              ? onToggle
              : null,
          onLongPress: () => _showActions(context),
          child: Stack(
            children: [
              if (visualState == DownloadState.running && progress > 0)
                Positioned.fill(
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: progress,
                    // 作者: long
                    // 下载中的任务以整行背景承载实时进度，列表快速扫视时不需要先找细小进度条。
                    child: ColoredBox(color: _taskProgressFill(colorScheme)),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 25,
                      height: 25,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Icon(
                        task.hasTorrentFolder
                            ? Icons.folder_outlined
                            : _taskStateIcon(visualState),
                        size: 14,
                        color: accentColor,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _taskOutputFileName(task),
                                  key: ValueKey('task-name-${task.id}'),
                                  softWrap: true,
                                  overflow: TextOverflow.visible,
                                  style: textTheme.titleSmall?.copyWith(
                                    fontSize: 12,
                                    height: 1.2,
                                    color: colorScheme.onSurface,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 5),
                              _TaskStatePill(
                                label:
                                    '${strings.stateLabel(task.state)} ${(progress * 100).round()}%',
                                color: accentColor,
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          _TaskCardStatusRow(strings: strings, task: task),
                          const SizedBox(height: 2),
                          _TaskCardMetricsRow(strings: strings, task: task),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showActions(BuildContext context) async {
    final overlay = Navigator.of(context).overlay?.context.findRenderObject();
    final cardBox = context.findRenderObject();
    if (overlay is! RenderBox || cardBox is! RenderBox) {
      return;
    }

    final cardOffset = cardBox.localToGlobal(Offset.zero, ancestor: overlay);
    final cardSize = cardBox.size;
    // 作者: long
    // 任务快捷菜单跟随被长按的任务卡片，下边缘作为锚点，避免打断用户对当前任务的上下文判断。
    final position = RelativeRect.fromLTRB(
      cardOffset.dx + cardSize.width - 220,
      cardOffset.dy + cardSize.height + 4,
      overlay.size.width - cardOffset.dx - cardSize.width + 8,
      overlay.size.height - cardOffset.dy,
    );

    PopupMenuItem<_TaskMenuAction> item({
      required _TaskMenuAction value,
      required IconData icon,
      required String label,
      bool destructive = false,
    }) {
      final foreground = destructive
          ? Theme.of(context).colorScheme.error
          : Theme.of(context).colorScheme.onSurface;

      return PopupMenuItem<_TaskMenuAction>(
        value: value,
        height: 34,
        child: Row(
          children: [
            Icon(icon, size: 15, color: foreground),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: foreground,
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final primaryLabel = task.canPause
        ? strings.pause
        : task.state == DownloadState.paused
        ? strings.resume
        : task.state == DownloadState.failed
        ? strings.retry
        : task.state == DownloadState.handedOff
        ? strings.redownload
        : strings.start;
    final primaryIcon = task.canPause
        ? Icons.pause
        : task.state == DownloadState.failed ||
              task.state == DownloadState.handedOff
        ? Icons.refresh
        : Icons.play_arrow;

    final action = await showMenu<_TaskMenuAction>(
      context: context,
      position: position,
      color: Colors.white,
      constraints: const BoxConstraints(minWidth: 196, maxWidth: 220),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        item(
          value: _TaskMenuAction.primary,
          icon: primaryIcon,
          label: primaryLabel,
        ),
        item(
          value: _TaskMenuAction.openFile,
          icon: Icons.folder_outlined,
          label: strings.openFile,
        ),
        item(
          value: _TaskMenuAction.copySource,
          icon: Icons.copy,
          label: strings.copyDownloadLink,
        ),
        item(
          value: _TaskMenuAction.redownload,
          icon: Icons.restart_alt,
          label: strings.redownload,
        ),
        item(
          value: _TaskMenuAction.remove,
          icon: Icons.delete_outline,
          label: strings.remove,
          destructive: true,
        ),
      ],
    );

    switch (action) {
      case _TaskMenuAction.primary:
        if (task.canPause) {
          onPause();
        } else if (task.canRun) {
          onStart();
        } else {
          onRedownload();
        }
        break;
      case _TaskMenuAction.openFile:
        onOpenFile();
        break;
      case _TaskMenuAction.copySource:
        onCopySource();
        break;
      case _TaskMenuAction.redownload:
        onRedownload();
        break;
      case _TaskMenuAction.remove:
        onRemove();
        break;
      case null:
        break;
    }
  }
}

class _TaskCardStatusRow extends StatelessWidget {
  const _TaskCardStatusRow({required this.strings, required this.task});

  final AppStrings strings;
  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isRunning = task.state == DownloadState.running;
    final trailing = _taskCardTrailingValue(strings, task);
    final trailingStyle = textTheme.labelSmall?.copyWith(
      color: isRunning ? colorScheme.primary : colorScheme.onSurfaceVariant,
      fontSize: 9,
      height: 1,
      fontWeight: FontWeight.w400,
    );

    return Row(
      children: [
        Expanded(
          child: Text(
            _taskSubtitle(strings, task),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontSize: 8.5,
              height: 1,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          trailing,
          key: ValueKey(
            isRunning
                ? 'task-live-speed-${task.id}'
                : 'task-state-indicator-${task.id}',
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: trailingStyle,
        ),
      ],
    );
  }
}

class _TaskCardMetricsRow extends StatelessWidget {
  const _TaskCardMetricsRow({required this.strings, required this.task});

  final AppStrings strings;
  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final values = _taskCardMetricValues(strings, task);
    final style = textTheme.labelSmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
      fontSize: 8.5,
      height: 1,
      fontWeight: FontWeight.w400,
    );

    return Row(
      children: [
        for (var index = 0; index < values.length; index++) ...[
          if (index > 0) const SizedBox(width: 6),
          Expanded(
            flex: values.length == 3
                ? (index == 0
                      ? 7
                      : index == 1
                      ? 5
                      : 6)
                : index == values.length - 1
                ? 5
                : 7,
            child: Text(
              values[index],
              key: index == values.length - 1
                  ? ValueKey('task-size-${task.id}')
                  : null,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: index == values.length - 1
                  ? TextAlign.end
                  : TextAlign.start,
              style: index == values.length - 1
                  ? style?.copyWith(color: colorScheme.onSurface)
                  : style,
            ),
          ),
        ],
      ],
    );
  }
}

String _taskCardTrailingValue(AppStrings strings, DownloadTask task) {
  return switch (task.state) {
    DownloadState.running => _formatSpeed(task.currentSpeedBytesPerSecond),
    DownloadState.queued => strings.waitingStart,
    DownloadState.paused => strings.stateLabel(task.state),
    DownloadState.finished =>
      '${strings.endTime} ${_formatDateTime(task.finishedAt)}',
    DownloadState.handedOff =>
      '${strings.handedOffAt} ${_formatDateTime(task.updatedAt)}',
    DownloadState.failed =>
      '${strings.failedAt} ${_formatDateTime(task.updatedAt)}',
  };
}

List<String> _taskCardMetricValues(AppStrings strings, DownloadTask task) {
  return switch (task.state) {
    DownloadState.running => [
      '${strings.start} ${_formatDateTime(task.startedAt)}',
      '${strings.totalElapsed} ${_formatDuration(task.elapsed)}',
      _formatBytePair(task),
    ],
    DownloadState.queued => [
      '${strings.queuedAt} ${_formatDateTime(task.createdAt)}',
      _formatBytePair(task),
    ],
    DownloadState.paused => [
      '${strings.start} ${_formatDateTime(task.startedAt)}',
      '${strings.totalElapsed} ${_formatDuration(task.elapsed)}',
      _formatBytePair(task),
    ],
    DownloadState.finished => [
      '${strings.start} ${_formatDateTime(task.startedAt)}',
      '${strings.totalElapsed} ${_formatDuration(task.elapsed)}',
      _formatBytePair(task),
    ],
    DownloadState.handedOff => [
      '${strings.handedOffAt} ${_formatDateTime(task.updatedAt)}',
      _formatBytePair(task),
    ],
    DownloadState.failed => [
      '${strings.failedAt} ${_formatDateTime(task.updatedAt)}',
      '${strings.totalElapsed} ${_formatDuration(_taskCardElapsed(task))}',
      _formatBytePair(task),
    ],
  };
}

Duration? _taskCardElapsed(DownloadTask task) {
  // 作者: long
  // 失败任务的 updatedAt 是最后一次失败落点，列表耗时必须冻结在该时刻，不能继续按当前时间增长。
  if (task.state != DownloadState.failed || task.startedAt == null) {
    return task.elapsed;
  }
  final elapsed = task.updatedAt.difference(task.startedAt!);
  return elapsed.isNegative ? Duration.zero : elapsed;
}

class _TaskStatePill extends StatelessWidget {
  const _TaskStatePill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 9,
          height: 1,
          fontWeight: FontWeight.w400,
        ),
      ),
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
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _taskOutputFileName(task),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w400,
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
                      fontWeight: FontWeight.w400,
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

typedef TorrentFileProgressLoader =
    Future<List<int?>> Function(
      DownloadTask task,
      List<TorrentFileEntry> files,
    );

Future<List<int?>> _loadTorrentFileProgress(
  DownloadTask task,
  List<TorrentFileEntry> files,
) async {
  if (task.state == DownloadState.finished) {
    return files.map<int?>((file) => file.size).toList(growable: false);
  }
  if (task.state == DownloadState.queued) {
    return List<int?>.filled(files.length, 0, growable: false);
  }

  try {
    final values = await _storageChannel
        .invokeListMethod<Object?>('getAllocatedFileBytes', {
          'paths': files
              .map((file) => _torrentFileOutputPath(task, file))
              .toList(growable: false),
        });
    if (values == null || values.length != files.length) {
      return List<int?>.filled(files.length, null, growable: false);
    }
    return List<int?>.generate(files.length, (index) {
      final value = values[index];
      if (value is! num || value < 0) return null;
      return value.toInt().clamp(0, files[index].size).toInt();
    }, growable: false);
  } on PlatformException {
    return List<int?>.filled(files.length, null, growable: false);
  } on MissingPluginException {
    return List<int?>.filled(files.length, null, growable: false);
  }
}

class TorrentFolderPage extends StatefulWidget {
  const TorrentFolderPage({
    required this.strings,
    required this.controller,
    required this.task,
    this.loadFileProgress = _loadTorrentFileProgress,
    super.key,
  });

  final AppStrings strings;
  final DownloadController controller;
  final DownloadTask task;
  final TorrentFileProgressLoader loadFileProgress;

  @override
  State<TorrentFolderPage> createState() => _TorrentFolderPageState();
}

class _TorrentFolderPageState extends State<TorrentFolderPage> {
  late DownloadTask task = widget.task;
  Timer? _refreshTimer;
  var _fileDownloadedBytes = <int, int?>{};
  var _fileSpeeds = <int, int>{};
  DateTime? _lastFileProgressAt;
  bool _loadingFileProgress = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshFileProgress(task));
    _refreshTimer = Timer.periodic(
      const Duration(milliseconds: 750),
      (_) => _refreshTask(),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _refreshTask() {
    DownloadTask? latest;
    for (final candidate in widget.controller.tasks) {
      if (candidate.id == task.id) {
        latest = candidate;
        break;
      }
    }
    if (latest == null || !mounted) return;
    setState(() {
      task = latest!;
    });
    unawaited(_refreshFileProgress(latest));
  }

  Future<void> _refreshFileProgress(DownloadTask snapshot) async {
    if (_loadingFileProgress) return;
    _loadingFileProgress = true;
    try {
      final files = snapshot.selectedTorrentFiles;
      final values = await widget.loadFileProgress(snapshot, files);
      if (!mounted || task.id != snapshot.id) return;

      final now = DateTime.now();
      final previousAt = _lastFileProgressAt;
      final elapsedSeconds = previousAt == null
          ? 0.0
          : now.difference(previousAt).inMicroseconds / 1000000;
      final downloaded = <int, int?>{};
      final speeds = <int, int>{};
      for (var index = 0; index < files.length; index += 1) {
        final file = files[index];
        final current = index < values.length ? values[index] : null;
        downloaded[file.index] = current;
        final previous = _fileDownloadedBytes[file.index];
        speeds[file.index] =
            snapshot.state == DownloadState.running &&
                current != null &&
                previous != null &&
                current >= previous &&
                elapsedSeconds > 0
            ? ((current - previous) / elapsedSeconds).round()
            : 0;
      }

      setState(() {
        _fileDownloadedBytes = downloaded;
        _fileSpeeds = speeds;
        _lastFileProgressAt = now;
      });
    } finally {
      _loadingFileProgress = false;
    }
  }

  Future<void> _openTorrentFile(TorrentFileEntry file) async {
    final path = _torrentFileOutputPath(task, file);
    final diskFile = File(path);
    if (!await diskFile.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(widget.strings.fileNotFound)));
      return;
    }

    final result = await OpenFilex.open(path);
    if (!mounted || result.type == ResultType.done) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.message.isEmpty
              ? widget.strings.openFileFailed
              : result.message,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final files = task.selectedTorrentFiles;
    final visualState = _taskVisualState(task);
    final progress = _taskProgressValue(task);
    final accentColor = _taskStateAccent(visualState, colorScheme);
    final backgroundColor = _taskStateBackground(visualState, colorScheme);

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 64,
        title: Text(widget.strings.resourceDetails),
      ),
      body: SafeArea(
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 24),
          itemCount: files.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Material(
                  clipBehavior: Clip.antiAlias,
                  color: backgroundColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                      color: _taskStateBorder(visualState, colorScheme),
                    ),
                  ),
                  child: Stack(
                    children: [
                      if (visualState == DownloadState.running && progress > 0)
                        Positioned.fill(
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: progress,
                            // 作者: long
                            // 文件夹页沿用队列页的整行进度背景，用户进入详情后仍能立刻判断总任务推进情况。
                            child: ColoredBox(
                              color: _taskProgressFill(colorScheme),
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 7,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.72),
                                borderRadius: BorderRadius.circular(7),
                              ),
                              child: Icon(
                                Icons.folder_outlined,
                                size: 16,
                                color: accentColor,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.strings.metadataDirectory,
                                    style: textTheme.labelSmall?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                      fontSize: 8.5,
                                      height: 1,
                                      fontWeight: FontWeight.w400,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Text(
                                          task.torrentFolderName,
                                          key: const ValueKey(
                                            'torrent-folder-name',
                                          ),
                                          softWrap: true,
                                          overflow: TextOverflow.visible,
                                          style: textTheme.titleSmall?.copyWith(
                                            fontSize: 12,
                                            height: 1.2,
                                            color: colorScheme.onSurface,
                                            fontWeight: FontWeight.w400,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 5),
                                      _TaskStatePill(
                                        label:
                                            '${widget.strings.stateLabel(task.state)} ${(progress * 100).round()}%',
                                        color: accentColor,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '${protocolLabel(task.protocol)} · ${widget.strings.torrentSelectedCount(files.length)}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: textTheme.labelSmall?.copyWith(
                                            color: colorScheme.onSurfaceVariant,
                                            fontSize: 8.5,
                                            height: 1,
                                            fontWeight: FontWeight.w400,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        _taskCardTrailingValue(
                                          widget.strings,
                                          task,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: textTheme.labelSmall?.copyWith(
                                          color:
                                              visualState ==
                                                  DownloadState.running
                                              ? colorScheme.primary
                                              : colorScheme.onSurfaceVariant,
                                          fontSize: 9,
                                          fontWeight: FontWeight.w400,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          _formatBytePair(task),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: textTheme.labelSmall?.copyWith(
                                            color: colorScheme.onSurface,
                                            fontSize: 8.8,
                                            height: 1,
                                            fontWeight: FontWeight.w400,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        _formatDuration(task.elapsed),
                                        maxLines: 1,
                                        style: textTheme.labelSmall?.copyWith(
                                          color: colorScheme.onSurfaceVariant,
                                          fontSize: 8.5,
                                          height: 1,
                                          fontWeight: FontWeight.w400,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }

            final file = files[index - 1];
            final metrics = _torrentFileMetrics(
              task,
              file,
              _fileDownloadedBytes[file.index],
              _fileSpeeds[file.index],
            );
            return _TorrentFileRow(
              strings: widget.strings,
              task: task,
              file: file,
              metrics: metrics,
              onTap: () => _openTorrentFile(file),
            );
          },
        ),
      ),
    );
  }
}

class _TorrentFileRow extends StatelessWidget {
  const _TorrentFileRow({
    required this.strings,
    required this.task,
    required this.file,
    required this.metrics,
    required this.onTap,
  });

  final AppStrings strings;
  final DownloadTask task;
  final TorrentFileEntry file;
  final _TorrentFileMetrics metrics;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final visualState = _taskVisualState(task);
    final accentColor = _taskStateAccent(visualState, colorScheme);
    final foreground = colorScheme.onSurface;
    final backgroundColor = _taskStateBackground(visualState, colorScheme);
    final format = _torrentFileFormat(file.path) ?? strings.unknownFileFormat;

    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Material(
        clipBehavior: Clip.antiAlias,
        color: backgroundColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: _taskStateBorder(visualState, colorScheme)),
        ),
        child: InkWell(
          onTap: onTap,
          child: Stack(
            children: [
              if (visualState == DownloadState.running &&
                  (metrics.progress ?? 0) > 0)
                Positioned.fill(
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: metrics.progress,
                    child: ColoredBox(color: _taskProgressFill(colorScheme)),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    Container(
                      width: 25,
                      height: 25,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Icon(
                        Icons.insert_drive_file_outlined,
                        size: 14,
                        color: accentColor,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  file.name,
                                  key: ValueKey(
                                    'torrent-detail-file-name-${file.index}',
                                  ),
                                  softWrap: true,
                                  overflow: TextOverflow.visible,
                                  style: textTheme.titleSmall?.copyWith(
                                    color: foreground,
                                    fontSize: 11.5,
                                    height: 1.2,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    metrics.progress == null
                                        ? '--'
                                        : '${(metrics.progress! * 100).round()}%',
                                    maxLines: 1,
                                    style: textTheme.labelSmall?.copyWith(
                                      color: foreground,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w400,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _formatSpeed(metrics.speedBytesPerSecond),
                                    maxLines: 1,
                                    style: textTheme.labelSmall?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                      fontSize: 8.5,
                                      fontWeight: FontWeight.w400,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          if (file.path != file.name) ...[
                            const SizedBox(height: 3),
                            Text(
                              file.path,
                              key: ValueKey(
                                'torrent-detail-file-path-${file.index}',
                              ),
                              softWrap: true,
                              overflow: TextOverflow.visible,
                              style: textTheme.labelSmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontSize: 8.5,
                                height: 1.15,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ],
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 10,
                            runSpacing: 3,
                            children: [
                              Text(
                                '${strings.fileFormat}: $format',
                                style: textTheme.labelSmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  fontSize: 8.8,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                              Text(
                                '${strings.fileSize}: ${formatBytes(file.size)}',
                                style: textTheme.labelSmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  fontSize: 8.8,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                              Text(
                                '${strings.downloadedSize}: ${metrics.downloadedBytes == null ? '--' : formatBytes(metrics.downloadedBytes)} / ${formatBytes(file.size)}',
                                key: ValueKey(
                                  'torrent-detail-file-downloaded-${file.index}',
                                ),
                                style: textTheme.labelSmall?.copyWith(
                                  color: foreground,
                                  fontSize: 8.8,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 5),
                    Icon(
                      Icons.visibility_outlined,
                      size: 14,
                      color: accentColor,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TorrentFileMetrics {
  const _TorrentFileMetrics({
    required this.downloadedBytes,
    required this.progress,
    required this.speedBytesPerSecond,
  });

  final int? downloadedBytes;
  final double? progress;
  final int speedBytesPerSecond;
}

_TorrentFileMetrics _torrentFileMetrics(
  DownloadTask task,
  TorrentFileEntry file,
  int? downloadedBytes,
  int? speedBytesPerSecond,
) {
  if (file.size <= 0) {
    return _TorrentFileMetrics(
      downloadedBytes: 0,
      progress: 0,
      speedBytesPerSecond: speedBytesPerSecond ?? 0,
    );
  }
  if (task.state == DownloadState.finished) {
    return _TorrentFileMetrics(
      downloadedBytes: file.size,
      progress: 1,
      speedBytesPerSecond: 0,
    );
  }

  // 作者: long
  // libtorrent 使用稀疏文件随机落盘，逻辑文件长度不能代表已下载量；这里只使用平台层统计的实际已写入稀疏数据区间。
  final current = downloadedBytes?.clamp(0, file.size).toInt();
  return _TorrentFileMetrics(
    downloadedBytes: current,
    progress: current == null ? null : current / file.size,
    speedBytesPerSecond: speedBytesPerSecond ?? 0,
  );
}

String _torrentFileOutputPath(DownloadTask task, TorrentFileEntry file) {
  return p.joinAll([
    task.outputFolder,
    ...file.path
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.trim().isNotEmpty),
  ]);
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
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w400),
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
              fontWeight: FontWeight.w400,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w400,
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

double _taskProgressValue(DownloadTask task) {
  if (task.state == DownloadState.finished) {
    return 1;
  }
  final explicitProgress = task.progress;
  if (explicitProgress != null) {
    return explicitProgress.clamp(0.0, 1.0).toDouble();
  }
  final total = task.totalBytes;
  if (total == null || total <= 0) {
    return 0;
  }
  return (task.downloadedBytes / total).clamp(0.0, 1.0).toDouble();
}

IconData _taskStateIcon(DownloadState state) {
  return switch (state) {
    DownloadState.running => Icons.download_outlined,
    DownloadState.handedOff => Icons.open_in_new,
    DownloadState.finished => Icons.check,
    DownloadState.failed => Icons.warning_amber_rounded,
    DownloadState.paused => Icons.pause,
    DownloadState.queued => Icons.schedule,
  };
}

String _compactTaskSource(String source) {
  final normalized = source.trim();
  if (normalized.isEmpty) {
    return '--';
  }
  final uri = Uri.tryParse(normalized);
  if (uri != null && uri.host.isNotEmpty) {
    final path = uri.path.isEmpty ? '' : uri.path;
    return '${uri.host}$path';
  }
  return normalized;
}

Color _taskStateBackground(DownloadState state, ColorScheme colorScheme) {
  return switch (state) {
    DownloadState.running => const Color(0xffe4f4fd),
    DownloadState.handedOff => const Color(0xffeef2f6),
    DownloadState.finished => const Color(0xffe8f4ec),
    DownloadState.failed => const Color(0xffffece7),
    DownloadState.paused => const Color(0xfffff3d8),
    DownloadState.queued => const Color(0xfff4f9fd),
  };
}

Color _taskProgressFill(ColorScheme colorScheme) {
  return const Color(0xff9dd8f5).withValues(alpha: 0.72);
}

Color _taskStateBorder(DownloadState state, ColorScheme colorScheme) {
  return switch (state) {
    DownloadState.running => colorScheme.primary.withValues(alpha: 0.45),
    DownloadState.handedOff => colorScheme.outline.withValues(alpha: 0.5),
    DownloadState.finished => const Color(0xff80b991),
    DownloadState.failed => colorScheme.error.withValues(alpha: 0.42),
    DownloadState.paused => const Color(0xffd8a634),
    DownloadState.queued => colorScheme.outlineVariant.withValues(alpha: 0.72),
  };
}

Color _taskStateAccent(DownloadState state, ColorScheme colorScheme) {
  return switch (state) {
    DownloadState.running => colorScheme.primary,
    DownloadState.handedOff => colorScheme.onSurfaceVariant,
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
  if (task.hasTorrentFolder) {
    return task.torrentFolderName;
  }
  if (task.protocol != 'm3u8') {
    return task.fileName;
  }
  final extension = p.extension(task.fileName).toLowerCase();
  if (extension == '.mp4') {
    return task.fileName;
  }
  return '${p.basenameWithoutExtension(task.fileName)}.mp4';
}

String _taskSubtitle(AppStrings strings, DownloadTask task) {
  final error = task.error?.trim();
  if (error != null && error.isNotEmpty) {
    // 作者: long
    // 失败原因直接放在任务卡片第二行，用户无需先打开属性页；提示已经在控制器层脱敏并给出下一步动作。
    return error;
  }
  if (task.hasTorrentFolder) {
    return '${protocolLabel(task.protocol)} · ${strings.torrentSelectedCount(task.selectedTorrentFiles.length)} / ${task.torrentFiles.length} · ${_compactTaskSource(task.source)}';
  }
  return '${protocolLabel(task.protocol)} · ${_compactTaskSource(task.source)}';
}
