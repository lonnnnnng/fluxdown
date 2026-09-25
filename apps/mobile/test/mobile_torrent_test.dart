import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdown_mobile/src/mobile_torrent.dart';

void main() {
  test(
    'torrent update serializer preserves order after a failed update',
    () async {
      final serializer = TorrentUpdateSerializer();
      final events = <String>[];
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();

      final first = serializer.enqueue(() async {
        events.add('first-start');
        firstStarted.complete();
        await releaseFirst.future;
        events.add('first-fail');
        throw StateError('synthetic update failure');
      });
      await firstStarted.future;

      final second = serializer.enqueue(() async {
        events.add('second');
      });
      expect(events, ['first-start']);

      releaseFirst.complete();
      await expectLater(first, throwsStateError);
      await second;
      expect(events, ['first-start', 'first-fail', 'second']);

      await serializer.enqueue(() async {
        events.add('third');
      });
      expect(events, ['first-start', 'first-fail', 'second', 'third']);
    },
  );
}
