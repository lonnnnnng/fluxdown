import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdown_mobile/main.dart';
import 'package:fluxdown_mobile/src/download_controller.dart';
import 'package:fluxdown_mobile/src/download_task.dart';
import 'package:fluxdown_mobile/src/mobile_torrent.dart';
import 'package:fluxdown_mobile/src/transfer_metrics.dart';

void main() {
  testWidgets('new task dialog fills clipboard and QR sources', (tester) async {
    final storagePaths = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewTaskDialog(
            strings: AppStrings.zh,
            defaultOutputFolder: '/downloads',
            onPickOutputFolder: () async => '/picked',
            onReadClipboard: () async =>
                'https://example.com/files/archive.zip',
            onScanQr: () async => 'https://example.com/video/index.m3u8',
            onLoadStorageStats: (path) async {
              storagePaths.add(path);
              return const StorageStats(totalBytes: 1000, freeBytes: 400);
            },
            onInspectTorrentMetadata: (_) async => null,
            onCreate: _acceptTask,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('new-task-paste')), findsOneWidget);
    expect(find.byKey(const ValueKey('new-task-scan')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-stats')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('new-task-paste')));
    await tester.pumpAndSettle();
    expect(_text(tester, 'new-task-source'), contains('archive.zip'));
    expect(_text(tester, 'new-task-file-name'), 'archive.zip');

    await tester.tap(find.byKey(const ValueKey('new-task-scan')));
    await tester.pumpAndSettle();
    expect(_text(tester, 'new-task-source'), contains('index.m3u8'));
    expect(_text(tester, 'new-task-file-name'), 'index.mp4');
    expect(find.byKey(const ValueKey('new-task-hls-variant')), findsOneWidget);
    expect(find.byKey(const ValueKey('new-task-hls-keep-ts')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('new-task-hls-variant')),
      '1',
    );
    expect(_text(tester, 'new-task-hls-variant'), '1');

    await tester.tap(find.byKey(const ValueKey('new-task-pick-folder')));
    await tester.pumpAndSettle();
    expect(_text(tester, 'new-task-output-folder'), '/picked');
    expect(storagePaths, ['/downloads', '/picked']);
  });

  testWidgets('settings submits values and opens protocol details', (
    tester,
  ) async {
    var protocolsOpened = false;
    int? concurrency;
    int? threads;
    int? retries;
    int? speed;
    final output = TextEditingController(text: '/downloads');
    addTearDown(output.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsView(
            strings: AppStrings.zh,
            language: AppLanguage.zh,
            queueConcurrency: 1,
            downloadThreadCount: 8,
            retryAttempts: 1,
            speedLimitKbps: 0,
            outputFolderListenable: output,
            onLanguageChanged: (_) {},
            onConcurrencyChanged: (value) => concurrency = value,
            onDownloadThreadCountChanged: (value) => threads = value,
            onRetryAttemptsChanged: (value) => retries = value,
            onSpeedLimitChanged: (value) => speed = value,
            onPickOutputFolder: () {},
            onOpenProtocols: () => protocolsOpened = true,
            storageStats: const StorageStats(totalBytes: 1000, freeBytes: 400),
            storageLoading: false,
            storageUnavailable: false,
          ),
        ),
      ),
    );

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(4));
    await tester.enterText(fields.at(0), '3');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.enterText(fields.at(1), '12');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.enterText(fields.at(2), '2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.enterText(fields.at(3), '1.5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(concurrency, 3);
    expect(threads, 12);
    expect(retries, 2);
    expect(speed, 1536);

    await tester.ensureVisible(
      find.byKey(const ValueKey('settings-protocol-open')),
    );
    await tester.tap(find.byKey(const ValueKey('settings-protocol-open')));
    expect(protocolsOpened, isTrue);
  });

  testWidgets('task card toggles on tap and opens actions on long press', (
    tester,
  ) async {
    var toggles = 0;
    final task = DownloadTask.create(
      source: 'https://example.com/file.bin',
      outputFolder: '/downloads',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DownloadTaskCard(
            strings: AppStrings.zh,
            task: task,
            onToggle: () => toggles += 1,
            onStart: () {},
            onPause: () {},
            onRemove: () {},
            onCopySource: () {},
            onShowProperties: () {},
            onOpenDetails: () {},
            onOpenFile: () {},
            onShareFile: () {},
            onRedownload: () {},
          ),
        ),
      ),
    );

    await tester.tap(find.byType(DownloadTaskCard));
    expect(toggles, 1);
    await tester.longPress(find.byType(DownloadTaskCard));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.zh.copyDownloadLink), findsOneWidget);
  });

  testWidgets('queue tabs group unfinished and ended task states', (
    tester,
  ) async {
    final tasks = <DownloadTask>[
      DownloadTask.create(
        source: 'https://example.com/running.bin',
        outputFolder: '/downloads',
      ).copyWith(state: DownloadState.running),
      DownloadTask.create(
        source: 'https://example.com/queued.bin',
        outputFolder: '/downloads',
      ),
      DownloadTask.create(
        source: 'https://example.com/paused.bin',
        outputFolder: '/downloads',
      ).copyWith(state: DownloadState.paused),
      DownloadTask.create(
        source: 'https://example.com/finished.bin',
        outputFolder: '/downloads',
      ).copyWith(state: DownloadState.finished),
      DownloadTask.create(
        source: 'https://example.com/handed-off.bin',
        outputFolder: '/downloads',
      ).copyWith(state: DownloadState.handedOff),
      DownloadTask.create(
        source: 'https://example.com/failed.bin',
        outputFolder: '/downloads',
      ).copyWith(state: DownloadState.failed),
    ];
    QueueFilter? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QueueFilterTabs(
            strings: AppStrings.zh,
            tasks: tasks,
            selected: QueueFilter.all,
            onSelected: (value) => selected = value,
          ),
        ),
      ),
    );

    expect(find.text('全部(6)'), findsOneWidget);
    expect(find.text('未完成(3)'), findsOneWidget);
    expect(find.text('已结束(2)'), findsOneWidget);
    expect(find.text('失败(1)'), findsOneWidget);

    await tester.tap(find.text('未完成(3)'));
    expect(selected, QueueFilter.unfinished);
  });

  testWidgets('task card shows indicators that match task state', (
    tester,
  ) async {
    final startedAt = DateTime.utc(2026, 9, 11, 8, 0, 0);
    final finishedAt = DateTime.utc(2026, 9, 11, 8, 0, 5);
    final running =
        DownloadTask.create(
          source: 'https://example.com/running.bin',
          outputFolder: '/downloads',
        ).copyWith(
          state: DownloadState.running,
          startedAt: startedAt,
          downloadedBytes: 1024,
          totalBytes: 2048,
          currentSpeedBytesPerSecond: 512,
        );
    final finished =
        DownloadTask.create(
          source: 'https://example.com/finished.bin',
          outputFolder: '/downloads',
        ).copyWith(
          state: DownloadState.finished,
          startedAt: startedAt,
          finishedAt: finishedAt,
          downloadedBytes: 2048,
          totalBytes: 2048,
          currentSpeedBytesPerSecond: 512,
        );
    final queued = DownloadTask.create(
      source: 'https://example.com/queued.bin',
      outputFolder: '/downloads',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                DownloadTaskCard(
                  strings: AppStrings.zh,
                  task: running,
                  onToggle: () {},
                  onStart: () {},
                  onPause: () {},
                  onRemove: () {},
                  onCopySource: () {},
                  onShowProperties: () {},
                  onOpenDetails: () {},
                  onOpenFile: () {},
                  onShareFile: () {},
                  onRedownload: () {},
                ),
                DownloadTaskCard(
                  strings: AppStrings.zh,
                  task: finished,
                  onToggle: () {},
                  onStart: () {},
                  onPause: () {},
                  onRemove: () {},
                  onCopySource: () {},
                  onShowProperties: () {},
                  onOpenDetails: () {},
                  onOpenFile: () {},
                  onShareFile: () {},
                  onRedownload: () {},
                ),
                DownloadTaskCard(
                  strings: AppStrings.zh,
                  task: queued,
                  onToggle: () {},
                  onStart: () {},
                  onPause: () {},
                  onRemove: () {},
                  onCopySource: () {},
                  onShowProperties: () {},
                  onOpenDetails: () {},
                  onOpenFile: () {},
                  onShareFile: () {},
                  onRedownload: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(ValueKey('task-live-speed-${running.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('task-live-speed-${finished.id}')),
      findsNothing,
    );
    expect(
      find.byKey(ValueKey('task-state-indicator-${finished.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('task-state-indicator-${queued.id}')),
      findsOneWidget,
    );
    expect(find.text(AppStrings.zh.waitingStart), findsOneWidget);
  });

  testWidgets(
    'torrent selection nearly fills the screen and shows complete file details',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const longName = '这是一个需要完整显示而不能用省略号截断的超长测试视频文件名称.mp4';
      final files = <TorrentFileEntry>[
        const TorrentFileEntry(
          index: 0,
          path: '动画/第一季/$longName',
          name: longName,
          size: 1024 * 1024,
        ),
        ...List.generate(
          24,
          (index) => TorrentFileEntry(
            index: index + 1,
            path: '动画/第一季/第${index + 2}集.mkv',
            name: '第${index + 2}集.mkv',
            size: (index + 2) * 1024,
          ),
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showTorrentFileSelectionDialog(
                  context,
                  strings: AppStrings.zh,
                  metadata: TorrentMetadata(name: '动画', files: files),
                ),
                child: const Text('选择文件'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('选择文件'));
      await tester.pumpAndSettle();

      final dialogSize = tester.getSize(
        find.byKey(const ValueKey('torrent-file-selection-dialog')),
      );
      expect(dialogSize.width, greaterThan(390 * 0.9));
      expect(dialogSize.height, greaterThan(844 * 0.9));

      final fileName = tester.widget<Text>(
        find.byKey(const ValueKey('torrent-file-name-0')),
      );
      expect(fileName.data, longName);
      expect(fileName.maxLines, isNull);
      expect(fileName.overflow, TextOverflow.visible);
      expect(find.text('文件格式: MP4'), findsOneWidget);
      expect(find.text('文件大小: 1.0 MB'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('torrent-file-selection-confirm')),
        findsOneWidget,
      );

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('torrent-file-24')),
        500,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('torrent-file-list')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text('第25集.mkv'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('torrent-file-selection-confirm')),
        findsOneWidget,
      );
    },
  );

  testWidgets('magnet task is created only after file selection is confirmed', (
    tester,
  ) async {
    var createCount = 0;
    List<int>? createdSelection;
    const metadata = TorrentMetadata(
      name: '完整的动画资源目录',
      files: [
        TorrentFileEntry(
          index: 0,
          path: '完整的动画资源目录/第一集.mp4',
          name: '第一集.mp4',
          size: 1024,
        ),
        TorrentFileEntry(
          index: 1,
          path: '完整的动画资源目录/第二集.mkv',
          name: '第二集.mkv',
          size: 2048,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewTaskDialog(
            strings: AppStrings.zh,
            defaultOutputFolder: '/downloads',
            onPickOutputFolder: () async => null,
            onReadClipboard: () async => null,
            onScanQr: () async => null,
            onLoadStorageStats: (_) async =>
                const StorageStats(totalBytes: 1000, freeBytes: 400),
            onInspectTorrentMetadata: (_) async => metadata,
            onCreate:
                ({
                  required source,
                  required outputFolder,
                  fileName,
                  torrentName,
                  torrentFiles = const [],
                  selectedTorrentFileIndexes,
                  expectedSha256,
                  hlsVariantIndex,
                  hlsKeepTransportStream = false,
                }) async {
                  createCount += 1;
                  createdSelection = selectedTorrentFileIndexes;
                  return true;
                },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('new-task-source')),
      'magnet:?xt=urn:btih:0123456789abcdef',
    );

    await tester.tap(find.byKey(const ValueKey('new-task-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('torrent-file-selection-dialog')),
      findsOneWidget,
    );

    await tester.tap(find.text(AppStrings.zh.close));
    await tester.pumpAndSettle();
    expect(createCount, 0);
    expect(find.byType(NewTaskDialog), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('new-task-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.byKey(const ValueKey('torrent-file-selection-confirm')),
    );
    await tester.pumpAndSettle();

    expect(createCount, 1);
    expect(createdSelection, [0, 1]);
  });

  testWidgets('task card displays the complete file or folder name', (
    tester,
  ) async {
    const longName = '这是一个不能在任务列表中被省略的完整文件或目录名称.mp4';
    final task = DownloadTask.create(
      source: 'https://example.com/$longName',
      outputFolder: '/downloads',
      fileName: longName,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DownloadTaskCard(
            strings: AppStrings.zh,
            task: task,
            onToggle: () {},
            onStart: () {},
            onPause: () {},
            onRemove: () {},
            onCopySource: () {},
            onShowProperties: () {},
            onOpenDetails: () {},
            onOpenFile: () {},
            onShareFile: () {},
            onRedownload: () {},
          ),
        ),
      ),
    );

    final name = tester.widget<Text>(
      find.byKey(ValueKey('task-name-${task.id}')),
    );
    expect(name.data, longName);
    expect(name.maxLines, isNull);
    expect(name.overflow, TextOverflow.visible);
  });

  testWidgets(
    'torrent details shows only selected files with complete metadata and live bytes',
    (tester) async {
      const folderName = '这是一个需要在详情页完整展示的超长 metadata 资源目录名称';
      const firstName = '第一集-这是一个需要完整显示的超长文件名.mp4';
      const skippedName = '不应在详情页显示的未选文件.txt';
      const thirdName = '第三集.mkv';
      final task =
          DownloadTask.create(
            source: 'magnet:?xt=urn:btih:0123456789abcdef',
            outputFolder: '/downloads',
            torrentName: folderName,
            torrentFiles: const [
              TorrentFileEntry(
                index: 0,
                path: '$folderName/第一季/$firstName',
                name: firstName,
                size: 1024,
              ),
              TorrentFileEntry(
                index: 1,
                path: '$folderName/$skippedName',
                name: skippedName,
                size: 2048,
              ),
              TorrentFileEntry(
                index: 2,
                path: '$folderName/$thirdName',
                name: thirdName,
                size: 4096,
              ),
            ],
            selectedTorrentFileIndexes: const [0, 2],
          ).copyWith(
            state: DownloadState.running,
            downloadedBytes: 1536,
            totalBytes: 5120,
          );
      List<TorrentFileEntry>? loadedFiles;

      await tester.pumpWidget(
        MaterialApp(
          home: TorrentFolderPage(
            strings: AppStrings.zh,
            controller: DownloadController(),
            task: task,
            loadFileProgress: (_, files) async {
              loadedFiles = files;
              return const [512, 1024];
            },
          ),
        ),
      );
      await tester.pump();

      expect(loadedFiles?.map((file) => file.index), [0, 2]);
      expect(find.text('资源详情'), findsOneWidget);
      expect(find.text(folderName), findsOneWidget);
      final folder = tester.widget<Text>(
        find.byKey(const ValueKey('torrent-folder-name')),
      );
      expect(folder.maxLines, isNull);
      expect(folder.overflow, TextOverflow.visible);
      expect(find.text(firstName), findsOneWidget);
      expect(find.text(thirdName), findsOneWidget);
      expect(find.text(skippedName), findsNothing);
      expect(find.text('文件格式: MP4'), findsOneWidget);
      expect(find.text('文件大小: 1.0 KB'), findsOneWidget);
      expect(find.text('已下载: 512 B / 1.0 KB'), findsOneWidget);

      final fileName = tester.widget<Text>(
        find.byKey(const ValueKey('torrent-detail-file-name-0')),
      );
      expect(fileName.maxLines, isNull);
      expect(fileName.overflow, TextOverflow.visible);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('failed task primary action retries without redownloading', (
    tester,
  ) async {
    var starts = 0;
    var redownloads = 0;
    final task = DownloadTask.create(
      source: 'https://example.com/failed.bin',
      outputFolder: '/downloads',
    ).copyWith(state: DownloadState.failed, error: '连接已断开');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DownloadTaskCard(
            strings: AppStrings.zh,
            task: task,
            onToggle: () {},
            onStart: () => starts += 1,
            onPause: () {},
            onRemove: () {},
            onCopySource: () {},
            onShowProperties: () {},
            onOpenDetails: () {},
            onOpenFile: () {},
            onShareFile: () {},
            onRedownload: () => redownloads += 1,
          ),
        ),
      ),
    );

    await tester.longPress(find.byType(DownloadTaskCard));
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.zh.retry), findsOneWidget);
    expect(find.text(AppStrings.zh.redownload), findsOneWidget);
    await tester.tap(find.text(AppStrings.zh.retry));
    await tester.pumpAndSettle();
    expect(starts, 1);
    expect(redownloads, 0);
  });

  testWidgets('failed task card displays actionable error directly', (
    tester,
  ) async {
    final task = DownloadTask.create(
      source: 'https://example.com/private.bin',
      outputFolder: '/downloads',
    ).copyWith(state: DownloadState.failed, error: '认证失败，请检查账号、密码和访问权限。');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DownloadTaskCard(
            strings: AppStrings.zh,
            task: task,
            onToggle: () {},
            onStart: () {},
            onPause: () {},
            onRemove: () {},
            onCopySource: () {},
            onShowProperties: () {},
            onOpenDetails: () {},
            onOpenFile: () {},
            onShareFile: () {},
            onRedownload: () {},
          ),
        ),
      ),
    );

    expect(find.text('认证失败，请检查账号、密码和访问权限。'), findsOneWidget);
  });

  test(
    'speed limiter cancellation exits a long delay in a short slice',
    () async {
      var cancelled = false;
      final limiter = DownloadSpeedLimiter.fromKbps(1);
      final stopwatch = Stopwatch()..start();
      final pending = limiter.throttle(
        100 * 1024,
        isCancelled: () => cancelled,
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      cancelled = true;
      await pending;
      stopwatch.stop();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    },
  );
}

String _text(WidgetTester tester, String key) {
  return tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;
}

Future<bool> _acceptTask({
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
  return true;
}
