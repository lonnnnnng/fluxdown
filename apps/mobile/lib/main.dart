import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'src/download_controller.dart';
import 'src/download_task.dart';
import 'src/protocol.dart';

void main() {
  runApp(const FluxDownMobileApp());
}

enum AppLanguage { zh, en }

class AppStrings {
  const AppStrings._(this.language);

  final AppLanguage language;

  static const zh = AppStrings._(AppLanguage.zh);
  static const en = AppStrings._(AppLanguage.en);

  String get languageLabel => language == AppLanguage.zh ? '语言' : 'Language';
  String get chinese => '中文';
  String get english => 'English';
  String get planned => language == AppLanguage.zh ? '规划中' : 'Planned';
  String get source => language == AppLanguage.zh ? '下载源' : 'Source';
  String get outputFolder =>
      language == AppLanguage.zh ? '设备上的输出目录' : 'Output folder on device';
  String get outputHint => language == AppLanguage.zh
      ? '/storage/emulated/0/Download 或 App 沙盒路径'
      : '/storage/emulated/0/Download or app sandbox path';
  String get fileName => language == AppLanguage.zh ? '文件名' : 'File name';
  String get detected => language == AppLanguage.zh ? '识别结果' : 'Detected';
  String get add => language == AppLanguage.zh ? '添加' : 'Add';
  String get queue => language == AppLanguage.zh ? '队列' : 'Queue';
  String taskCount(int count) =>
      language == AppLanguage.zh ? '$count 个任务' : '$count tasks';
  String get noQueuedTasks =>
      language == AppLanguage.zh ? '还没有排队任务。' : 'No queued tasks yet.';
  String get running => language == AppLanguage.zh ? '运行中' : 'Running';
  String get runQueue => language == AppLanguage.zh ? '运行队列' : 'Run queue';
  String get remove => language == AppLanguage.zh ? '删除' : 'Remove';
  String get pause => language == AppLanguage.zh ? '暂停' : 'Pause';
  String get resume => language == AppLanguage.zh ? '继续' : 'Resume';
  String get start => language == AppLanguage.zh ? '开始' : 'Start';
  String get sourceAndOutputRequired => language == AppLanguage.zh
      ? '下载源和输出目录不能为空。'
      : 'Source and output folder are required.';
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
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff38d996)),
        useMaterial3: true,
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
  final sourceController = TextEditingController(
    text: 'https://speed.hetzner.de/100MB.bin',
  );
  final outputController = TextEditingController();
  final fileNameController = TextEditingController();
  late final DownloadController controller;
  var loading = true;
  var runningQueue = false;
  var queueConcurrency = 2;

  AppStrings get strings => widget.strings;

  @override
  void initState() {
    super.initState();
    controller = DownloadController(onChanged: _refresh);
    _load();
  }

  @override
  void dispose() {
    sourceController.dispose();
    outputController.dispose();
    fileNameController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final documents = await getApplicationDocumentsDirectory();
    outputController.text = '${documents.path}/downloads';
    await controller.load();
    if (!mounted) return;
    setState(() {
      loading = false;
    });
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> addTask() async {
    final source = sourceController.text.trim();
    final output = outputController.text.trim();
    if (source.isEmpty || output.isEmpty) {
      _showSnack(strings.sourceAndOutputRequired);
      return;
    }

    await controller.add(
      source: source,
      outputFolder: output,
      fileName: fileNameController.text,
    );
    fileNameController.clear();
  }

  Future<void> startTask(String id) async {
    await controller.start(id);
  }

  Future<void> pauseTask(String id) async {
    await controller.pause(id);
  }

  Future<void> removeTask(String id) async {
    await controller.remove(id);
  }

  Future<void> runQueue() async {
    if (runningQueue) return;
    setState(() {
      runningQueue = true;
    });
    try {
      final report = await controller.runQueued(concurrency: queueConcurrency);
      _showSnack(strings.queueComplete(report.finished, report.failed));
    } finally {
      if (mounted) {
        setState(() {
          runningQueue = false;
        });
      }
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final protocol = detectProtocol(sourceController.text);
    final support = supportStatus(protocol);
    final colorScheme = Theme.of(context).colorScheme;
    final backend = support.executable
        ? strings.backendLabel(protocol)
        : strings.planned;

    return Scaffold(
      appBar: AppBar(
        title: const Text('FluxDown'),
        actions: [
          PopupMenuButton<AppLanguage>(
            tooltip: strings.languageLabel,
            initialValue: widget.language,
            onSelected: widget.onLanguageChanged,
            itemBuilder: (context) => [
              PopupMenuItem(
                value: AppLanguage.zh,
                child: Text(strings.chinese),
              ),
              PopupMenuItem(
                value: AppLanguage.en,
                child: Text(strings.english),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  const Icon(Icons.language),
                  const SizedBox(width: 4),
                  Text(
                    widget.language == AppLanguage.zh
                        ? strings.chinese
                        : strings.english,
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Chip(
              avatar: Icon(
                support.executable ? Icons.check_circle : Icons.pending,
                size: 18,
              ),
              label: Text(backend),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TextField(
                    controller: sourceController,
                    decoration: InputDecoration(
                      labelText: strings.source,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: outputController,
                    decoration: InputDecoration(
                      labelText: strings.outputFolder,
                      border: const OutlineInputBorder(),
                      hintText: strings.outputHint,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: fileNameController,
                    decoration: InputDecoration(
                      labelText: strings.fileName,
                      border: const OutlineInputBorder(),
                      hintText: suggestedFileName(sourceController.text),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                strings.detectedLine(protocol, backend),
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            FilledButton.icon(
                              onPressed: addTask,
                              icon: const Icon(Icons.add),
                              label: Text(strings.add),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(strings.supportNote(protocol)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: const [
                      ProtocolChip(label: 'HTTP'),
                      ProtocolChip(label: 'HTTPS'),
                      ProtocolChip(label: 'WebDAV'),
                      ProtocolChip(label: 'FTP'),
                      ProtocolChip(label: 'Torrent'),
                      ProtocolChip(label: 'Magnet'),
                      ProtocolChip(label: 'ed2k'),
                      ProtocolChip(label: 'm3u8'),
                      ProtocolChip(label: 'SFTP'),
                      ProtocolChip(label: 'SMB'),
                      ProtocolChip(label: 'IPFS'),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          strings.queue,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      Text(strings.taskCount(controller.tasks.length)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  QueueRunnerBar(
                    strings: strings,
                    running: runningQueue,
                    concurrency: queueConcurrency,
                    enabled: controller.hasRunnableTasks,
                    onConcurrencyChanged: (value) {
                      setState(() {
                        queueConcurrency = value;
                      });
                    },
                    onRun: runQueue,
                  ),
                  const SizedBox(height: 8),
                  if (controller.tasks.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(child: Text(strings.noQueuedTasks)),
                      ),
                    )
                  else
                    ...controller.tasks.map(
                      (task) => DownloadTaskCard(
                        strings: strings,
                        task: task,
                        onStart: () => startTask(task.id),
                        onPause: () => pauseTask(task.id),
                        onRemove: () => removeTask(task.id),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class QueueRunnerBar extends StatelessWidget {
  const QueueRunnerBar({
    required this.strings,
    required this.running,
    required this.concurrency,
    required this.enabled,
    required this.onConcurrencyChanged,
    required this.onRun,
    super.key,
  });

  final AppStrings strings;
  final bool running;
  final int concurrency;
  final bool enabled;
  final ValueChanged<int> onConcurrencyChanged;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final segmented = SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('1')),
                ButtonSegment(value: 2, label: Text('2')),
                ButtonSegment(value: 3, label: Text('3')),
              ],
              selected: {concurrency},
              onSelectionChanged: running
                  ? null
                  : (values) => onConcurrencyChanged(values.single),
            );
            final runButton = FilledButton.icon(
              onPressed: enabled && !running ? onRun : null,
              icon: running
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.playlist_play),
              label: Text(running ? strings.running : strings.runQueue),
            );

            if (constraints.maxWidth < 300) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [segmented, const SizedBox(height: 10), runButton],
              );
            }

            return Row(
              children: [
                Expanded(child: segmented),
                const SizedBox(width: 12),
                runButton,
              ],
            );
          },
        ),
      ),
    );
  }
}

class ProtocolChip extends StatelessWidget {
  const ProtocolChip({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(label: Text(label));
  }
}

class DownloadTaskCard extends StatelessWidget {
  const DownloadTaskCard({
    required this.strings,
    required this.task,
    required this.onStart,
    required this.onPause,
    required this.onRemove,
    super.key,
  });

  final AppStrings strings;
  final DownloadTask task;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final progress = task.progress;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(task.fileName, style: textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        task.source,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Chip(label: Text(protocolLabel(task.protocol))),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${strings.stateLabel(task.state)} · ${formatBytes(task.downloadedBytes)} / ${formatBytes(task.totalBytes)} · ${strings.backendLabel(task.protocol)}',
                  ),
                ),
              ],
            ),
            if (task.error != null) ...[
              const SizedBox(height: 8),
              Text(
                task.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: strings.remove,
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline),
                ),
                const SizedBox(width: 6),
                if (task.canPause)
                  FilledButton.tonalIcon(
                    onPressed: onPause,
                    icon: const Icon(Icons.pause),
                    label: Text(strings.pause),
                  )
                else
                  FilledButton.icon(
                    onPressed: task.canRun ? onStart : null,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(
                      task.state == DownloadState.paused
                          ? strings.resume
                          : strings.start,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
