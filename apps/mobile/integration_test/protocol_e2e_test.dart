import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdown_mobile/src/protocol_e2e_runner.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('runs configured mobile protocol downloads', (tester) async {
    final result = await runProtocolE2e(emitLine: _emitLine);
    expect(result.failures, isEmpty);
  }, timeout: Timeout.none);
}

void _emitLine(String line) {
  // ignore: avoid_print
  print(line);
}
