import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdown_mobile/src/download_controller.dart';
import 'package:fluxdown_mobile/src/download_task.dart';
import 'package:fluxdown_mobile/src/task_store.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

const _casesJson = String.fromEnvironment('FLUXDOWN_E2E_CASES_JSON');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('runs configured mobile protocol downloads', (tester) async {
    final cases = _loadCases();
    expect(
      cases,
      isNotEmpty,
      reason: 'Pass cases with --dart-define=FLUXDOWN_E2E_CASES_JSON=...',
    );

    final baseDir = await Directory.systemTemp.createTemp(
      'fluxdown_mobile_protocol_e2e_',
    );
    final outputDir = Directory(p.join(baseDir.path, 'downloads'));
    await outputDir.create(recursive: true);
    addTearDown(() async {
      if (await baseDir.exists()) {
        await baseDir.delete(recursive: true);
      }
    });

    final controller = DownloadController(
      store: TaskStore(baseDirectory: baseDir),
    );
    await controller.load();

    final results = <Map<String, Object?>>[];
    final failures = <String>[];
    for (final testCase in cases) {
      final source = testCase.source;
      final fileName = testCase.fileName;
      final task = await controller.add(
        source: source,
        outputFolder: outputDir.path,
        fileName: fileName,
      );

      final started = DateTime.now().toUtc();
      Object? timeoutError;
      try {
        await controller
            .start(task.id)
            .timeout(Duration(seconds: testCase.timeoutSeconds ?? 45));
      } on TimeoutException catch (error) {
        timeoutError = error;
        await controller.pause(task.id);
      }
      final finished = DateTime.now().toUtc();
      final actual = controller.tasks.firstWhere((item) => item.id == task.id);
      final outputPath = p.join(outputDir.path, actual.fileName);
      final outputFile = File(outputPath);
      final outputBytes = await outputFile.exists()
          ? await outputFile.length()
          : 0;

      final result = <String, Object?>{
        'id': testCase.id,
        'protocol': actual.protocol,
        'source': source,
        'fileName': actual.fileName,
        'state': actual.state.name,
        'downloadedBytes': actual.downloadedBytes,
        'totalBytes': actual.totalBytes,
        'outputBytes': outputBytes,
        'outputPath': outputPath,
        'error': timeoutError == null
            ? actual.error
            : 'Timed out after ${testCase.timeoutSeconds ?? 45}s',
        'startedAt': started.toIso8601String(),
        'finishedAt': finished.toIso8601String(),
      };
      results.add(result);
      // Integration automation consumes these structured stdout lines.
      // ignore: avoid_print
      print('FLUXDOWN_E2E_RESULT ${jsonEncode(result)}');

      if (testCase.expectedState != null) {
        if (actual.state.name != testCase.expectedState) {
          failures.add(
            '${testCase.id}: state ${actual.state.name} != ${testCase.expectedState}',
          );
          continue;
        }
        final expectedError = testCase.expectedErrorContains;
        if (expectedError != null &&
            !(result['error'] as String? ?? '').contains(expectedError)) {
          failures.add(
            '${testCase.id}: error did not contain "$expectedError"',
          );
        }
        continue;
      }

      if (timeoutError != null) {
        failures.add('${testCase.id}: timed out');
        continue;
      }
      if (actual.state != DownloadState.finished) {
        failures.add('${testCase.id}: ${actual.error ?? actual.state.name}');
        continue;
      }
      if (outputBytes <= 0) {
        failures.add('${testCase.id}: output was empty');
        continue;
      }
      if (testCase.maxBytes != null && outputBytes > testCase.maxBytes!) {
        failures.add(
          '${testCase.id}: output $outputBytes exceeds ${testCase.maxBytes}',
        );
        continue;
      }
      if (testCase.expectedBytes != null &&
          outputBytes != testCase.expectedBytes) {
        failures.add(
          '${testCase.id}: output $outputBytes != ${testCase.expectedBytes}',
        );
        continue;
      }
      if (testCase.expectedText != null) {
        final text = await outputFile.readAsString();
        if (text != testCase.expectedText) {
          failures.add('${testCase.id}: output text did not match');
        }
      }
    }

    // ignore: avoid_print
    print('FLUXDOWN_E2E_SUMMARY ${jsonEncode(results)}');
    expect(failures, isEmpty);
  });
}

List<ProtocolE2eCase> _loadCases() {
  if (_casesJson.trim().isEmpty) {
    return const [];
  }
  final decoded = jsonDecode(_casesJson);
  if (decoded is! List) {
    throw const FormatException('E2E cases JSON must be an array.');
  }
  return decoded
      .map(
        (item) =>
            ProtocolE2eCase.fromJson(Map<String, Object?>.from(item as Map)),
      )
      .toList(growable: false);
}

class ProtocolE2eCase {
  const ProtocolE2eCase({
    required this.id,
    required this.source,
    this.fileName,
    this.maxBytes,
    this.expectedBytes,
    this.expectedText,
    this.expectedState,
    this.expectedErrorContains,
    this.timeoutSeconds,
  });

  factory ProtocolE2eCase.fromJson(Map<String, Object?> json) {
    return ProtocolE2eCase(
      id: json['id'] as String,
      source: json['source'] as String,
      fileName: json['fileName'] as String?,
      maxBytes: json['maxBytes'] as int?,
      expectedBytes: json['expectedBytes'] as int?,
      expectedText: json['expectedText'] as String?,
      expectedState: json['expectedState'] as String?,
      expectedErrorContains: json['expectedErrorContains'] as String?,
      timeoutSeconds: json['timeoutSeconds'] as int?,
    );
  }

  final String id;
  final String source;
  final String? fileName;
  final int? maxBytes;
  final int? expectedBytes;
  final String? expectedText;
  final String? expectedState;
  final String? expectedErrorContains;
  final int? timeoutSeconds;
}
