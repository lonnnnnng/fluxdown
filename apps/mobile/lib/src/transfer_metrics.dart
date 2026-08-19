import 'dart:async';

class DownloadSpeedLimiter {
  DownloadSpeedLimiter.fromKbps(int kilobytesPerSecond)
    : bytesPerSecond = kilobytesPerSecond <= 0 ? 0 : kilobytesPerSecond * 1024;

  final int bytesPerSecond;
  final Stopwatch _stopwatch = Stopwatch()..start();
  var _transferredBytes = 0;
  Future<void> _scheduledDelay = Future.value();

  bool get enabled => bytesPerSecond > 0;

  Future<void> throttle(int byteCount, {bool Function()? isCancelled}) {
    if (!enabled || byteCount <= 0) {
      return Future.value();
    }

    _scheduledDelay = _scheduledDelay.then((_) async {
      _transferredBytes += byteCount;
      while (isCancelled?.call() != true) {
        final expectedMicroseconds =
            (_transferredBytes * Duration.microsecondsPerSecond) ~/
            bytesPerSecond;
        final remainingMicroseconds =
            expectedMicroseconds - _stopwatch.elapsedMicroseconds;
        if (remainingMicroseconds <= 0) {
          return;
        }

        // 作者: long
        // 低速限速可能产生数秒等待，拆成短时间片后暂停请求无需等完整延迟结束。
        await Future<void>.delayed(
          Duration(microseconds: remainingMicroseconds.clamp(1, 50000).toInt()),
        );
      }
    });
    return _scheduledDelay;
  }
}

class TransferSpeedSampler {
  TransferSpeedSampler({int initialBytes = 0, DateTime? now})
    : _lastBytes = initialBytes,
      _lastSampleAt = now ?? DateTime.now();

  int _lastBytes;
  DateTime _lastSampleAt;
  int _lastSpeedBytesPerSecond = 0;

  int sample(int totalBytes, {DateTime? now}) {
    final sampleAt = now ?? DateTime.now();
    final elapsedMs = sampleAt.difference(_lastSampleAt).inMilliseconds;
    final byteDelta = totalBytes - _lastBytes;
    if (elapsedMs <= 0) {
      return _lastSpeedBytesPerSecond;
    }
    if (byteDelta <= 0) {
      if (elapsedMs >= 1500) {
        _lastSpeedBytesPerSecond = 0;
        _lastSampleAt = sampleAt;
      }
      return _lastSpeedBytesPerSecond;
    }

    _lastSpeedBytesPerSecond = (byteDelta * 1000 / elapsedMs).round();
    _lastBytes = totalBytes;
    _lastSampleAt = sampleAt;
    return _lastSpeedBytesPerSecond;
  }
}
