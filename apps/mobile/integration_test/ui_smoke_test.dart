import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdown_mobile/main.dart' as app;
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS simulator can navigate queue, settings, and new task form', (
    tester,
  ) async {
    app.main();

    // 作者: long
    // App 启动时会异步读取本地队列、凭据和设置；分段等待避免把异步初始化误判成 UI 不可用，
    // 同时给 simulator 一个明确的失败上限，保证这条验收命令不会无限等待。
    for (var attempt = 0; attempt < 30; attempt += 1) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find
          .byKey(const ValueKey('queue-page-title'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }

    expect(find.byKey(const ValueKey('queue-page-title')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('compact-home-navigation-item-设置')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('compact-home-navigation-item-设置')),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byKey(const ValueKey('settings-page-title')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-storage-stats')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('compact-home-navigation-item-任务')),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('queue-page-title')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('new-task-fab')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('new-task-source')), findsOneWidget);
    expect(find.byKey(const ValueKey('new-task-paste')), findsOneWidget);
    expect(find.byKey(const ValueKey('new-task-scan')), findsOneWidget);
    expect(find.byKey(const ValueKey('new-task-file-name')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('new-task-output-folder')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('new-task-pick-folder')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('new-task-close')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('compact-home-navigation-item-设置')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-concurrency')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-thread-count')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-retry-attempts')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('settings-speed-limit')), findsOneWidget);
  });
}
