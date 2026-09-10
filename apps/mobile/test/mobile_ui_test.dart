import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdown_mobile/main.dart';
import 'package:fluxdown_mobile/src/download_task.dart';
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

  testWidgets('failed task card displays actionable error directly', (
    tester,
  ) async {
    final task = DownloadTask.create(
      source: 'https://example.com/private.bin',
      outputFolder: '/downloads',
    ).copyWith(
      state: DownloadState.failed,
      error: '认证失败，请检查账号、密码和访问权限。',
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
