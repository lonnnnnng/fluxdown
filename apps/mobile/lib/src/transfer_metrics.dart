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
