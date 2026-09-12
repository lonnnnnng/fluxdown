import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:fluxdown_mobile/main.dart';
import 'package:fluxdown_mobile/src/mobile_update.dart';

void main() {
  test('compares release versions and removes tag prefixes', () {
    expect(normalizeMobileVersion('v1.2.3'), '1.2.3');
    expect(normalizeMobileVersion('1.2.3-beta+4'), '1.2.3');
    expect(compareMobileVersions('v1.0.20', '1.0.18'), greaterThan(0));
    expect(compareMobileVersions('1.0.18', 'v1.0.18'), 0);
    expect(compareMobileVersions('1.0.17', '1.0.18'), lessThan(0));
  });

  test('parses latest release and selects the Android APK asset', () async {
    final checker = MobileUpdateChecker(
      client: _FakeClient(_releasePayload('v1.0.20')),
      currentVersion: '1.0.18',
      apiUri: Uri.parse('https://example.test/releases/latest'),
    );

    final report = await checker.check();

    expect(report.currentVersion, '1.0.18');
    expect(report.latestVersion, '1.0.20');
    expect(report.hasUpdate, isTrue);
    expect(
      report.releaseUrl,
      'https://github.com/lonnnnnng/fluxdown/releases/tag/v1.0.20',
    );
    expect(report.downloadFileName, 'FluxDown-1.0.20-android-release.apk');
    expect(report.downloadUrl, contains('FluxDown-1.0.20-android-release.apk'));
    expect(report.downloadSizeBytes, 1234);
  });

  test(
    'reports no update when the release matches the installed version',
    () async {
      final checker = MobileUpdateChecker(
        client: _FakeClient(_releasePayload('v1.0.18')),
        currentVersion: '1.0.18',
      );

      final report = await checker.check();

      expect(report.hasUpdate, isFalse);
      expect(report.latestVersion, '1.0.18');
    },
  );

  testWidgets('latest version dialog has open-page and confirm actions', (
    tester,
  ) async {
    var opened = 0;
    final report = MobileUpdateReport(
      currentVersion: '1.0.18',
      latestVersion: '1.0.18',
      hasUpdate: false,
      releaseUrl: mobileReleasePageUrl,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => MobileUpdateResultDialog(
                strings: AppStrings.zh,
                report: report,
                onOpenDownloadPage: () => opened += 1,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('mobile-update-download')), findsNothing);
    expect(
      find.byKey(const ValueKey('mobile-update-open-page')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('mobile-update-confirm')), findsOneWidget);
    expect(find.text('已是最新版本'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mobile-update-open-page')));
    expect(opened, 1);
  });

  testWidgets(
    'new version dialog exposes download, page, and confirm actions',
    (tester) async {
      final report = MobileUpdateReport(
        currentVersion: '1.0.18',
        latestVersion: '1.0.20',
        hasUpdate: true,
        releaseUrl: mobileReleasePageUrl,
        downloadUrl: 'https://example.test/FluxDown-1.0.20-android-release.apk',
        downloadFileName: 'FluxDown-1.0.20-android-release.apk',
        releaseNotes: '修复下载队列\n优化暂停继续和更新检查体验。',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MobileUpdateResultDialog(
              strings: AppStrings.zh,
              report: report,
              onOpenDownloadPage: () {},
              onDownloadUpdate: () {},
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('mobile-update-download')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('mobile-update-open-page')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('mobile-update-confirm')),
        findsOneWidget,
      );
      expect(find.text('找到最新版本 v1.0.20'), findsOneWidget);
      expect(find.byKey(const ValueKey('mobile-update-notes')), findsOneWidget);
      expect(find.text('修复下载队列\n优化暂停继续和更新检查体验。'), findsOneWidget);
      final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
      expect(dialog.actionsAlignment, MainAxisAlignment.end);
      expect(dialog.actionsOverflowAlignment, OverflowBarAlignment.end);
    },
  );

  testWidgets('settings shows current version and invokes update check', (
    tester,
  ) async {
    var checks = 0;
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
            onConcurrencyChanged: (_) {},
            onDownloadThreadCountChanged: (_) {},
            onRetryAttemptsChanged: (_) {},
            onSpeedLimitChanged: (_) {},
            onCheckForUpdates: () => checks += 1,
            onPickOutputFolder: () {},
            storageStats: const StorageStats(totalBytes: 1000, freeBytes: 400),
            storageLoading: false,
            storageUnavailable: false,
          ),
        ),
      ),
    );

    expect(find.text('当前版本'), findsOneWidget);
    expect(find.text('v$mobileAppVersion'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-check-updates')));
    expect(checks, 1);
  });
}

class _FakeClient extends http.BaseClient {
  _FakeClient(this.payload);

  final Map<String, dynamic> payload;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = utf8.encode(jsonEncode(payload));
    return http.StreamedResponse(
      Stream.value(bytes),
      200,
      headers: const {'content-type': 'application/json'},
      request: request,
    );
  }
}

Map<String, dynamic> _releasePayload(String tag) {
  final version = normalizeMobileVersion(tag);
  return {
    'tag_name': tag,
    'html_url': 'https://github.com/lonnnnnng/fluxdown/releases/tag/$tag',
    'body': '更新说明',
    'published_at': '2026-09-11T00:00:00Z',
    'assets': [
      {
        'name': 'fluxdown-archive.zip',
        'browser_download_url': 'https://example.test/archive.zip',
        'size': 42,
      },
      {
        'name': 'FluxDown-$version-android-release.apk',
        'browser_download_url':
            'https://example.test/FluxDown-$version-android-release.apk',
        'size': 1234,
      },
    ],
  };
}
