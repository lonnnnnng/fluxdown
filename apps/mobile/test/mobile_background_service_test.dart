import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdown_mobile/src/mobile_background_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.fluxdown.mobile/background');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'bridges queue lifecycle and progress without leaking secrets',
    () async {
      final service = MobileBackgroundService();
      await service.start(runningTasks: 2);
      await service.update(
        runningTasks: 1,
        finishedTasks: 3,
        totalTasks: 4,
        progressPercent: 127,
      );
      await service.stop();

      expect(calls.map((call) => call.method), [
        'startForegroundDownload',
        'updateForegroundDownload',
        'stopForegroundDownload',
      ]);
      expect(calls[0].arguments, {'runningTasks': 2});
      expect(calls[1].arguments, {
        'runningTasks': 1,
        'finishedTasks': 3,
        'totalTasks': 4,
        'progressPercent': 100,
      });
    },
  );

  test('bridges iOS short background window separately', () async {
    final service = MobileBackgroundService();
    await service.beginIosBackgroundWindow();
    await service.endIosBackgroundWindow();

    expect(calls.map((call) => call.method), [
      'beginBackgroundWindow',
      'endBackgroundWindow',
    ]);
  });
}
