import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'src/download_controller.dart';
import 'src/download_task.dart';
import 'src/protocol.dart';

void main() {
  runApp(const FluxDownMobileApp());
}

class FluxDownMobileApp extends StatelessWidget {
  const FluxDownMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FluxDown',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff38d996)),
        useMaterial3: true,
      ),
      home: const DownloadHome(),
    );
  }
}

class DownloadHome extends StatefulWidget {
  const DownloadHome({super.key});

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
      _showSnack('Source and output folder are required.');
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
      _showSnack(
        'Queue complete: ${report.finished} finished, ${report.failed} failed.',
      );
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('FluxDown'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Chip(
              avatar: Icon(
                support.executable ? Icons.check_circle : Icons.pending,
                size: 18,
              ),
              label: Text(
                support.executable ? support.backendLabel : 'Planned',
              ),
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
                    decoration: const InputDecoration(
                      labelText: 'Source',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: outputController,
                    decoration: const InputDecoration(
                      labelText: 'Output folder on device',
                      border: OutlineInputBorder(),
                      hintText:
                          '/storage/emulated/0/Download or app sandbox path',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: fileNameController,
                    decoration: InputDecoration(
                      labelText: 'File name',
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
                                'Detected: $protocol · ${support.backendLabel}',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            FilledButton.icon(
                              onPressed: addTask,
                              icon: const Icon(Icons.add),
                              label: const Text('Add'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(support.note),
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
                          'Queue',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      Text('${controller.tasks.length} tasks'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  QueueRunnerBar(
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
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: Text('No queued tasks yet.')),
                      ),
                    )
                  else
                    ...controller.tasks.map(
                      (task) => DownloadTaskCard(
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
    required this.running,
    required this.concurrency,
    required this.enabled,
    required this.onConcurrencyChanged,
    required this.onRun,
    super.key,
  });

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
              label: Text(running ? 'Running' : 'Run queue'),
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
    required this.task,
    required this.onStart,
    required this.onPause,
    required this.onRemove,
    super.key,
  });

  final DownloadTask task;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final support = supportStatus(task.protocol);
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
                Chip(label: Text(task.protocol)),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${task.state.name} · ${formatBytes(task.downloadedBytes)} / ${formatBytes(task.totalBytes)} · ${support.backendLabel}',
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
                  tooltip: 'Remove',
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline),
                ),
                const SizedBox(width: 6),
                if (task.canPause)
                  FilledButton.tonalIcon(
                    onPressed: onPause,
                    icon: const Icon(Icons.pause),
                    label: const Text('Pause'),
                  )
                else
                  FilledButton.icon(
                    onPressed: task.canRun ? onStart : null,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(
                      task.state == DownloadState.paused ? 'Resume' : 'Start',
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
