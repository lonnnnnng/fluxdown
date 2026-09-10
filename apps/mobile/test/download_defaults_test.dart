import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdown_mobile/src/download_defaults.dart';

void main() {
  test('download defaults match product settings', () {
    expect(defaultQueueConcurrency, 5);
    expect(defaultDownloadThreadCount, 16);
    expect(defaultRetryAttempts, 3);

    expect(defaultQueueConcurrency, inInclusiveRange(1, maxQueueConcurrency));
    expect(
      defaultDownloadThreadCount,
      inInclusiveRange(1, maxDownloadThreadCount),
    );
    expect(defaultRetryAttempts, inInclusiveRange(0, maxRetryAttempts));
  });
}
