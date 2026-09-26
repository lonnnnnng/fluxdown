import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/digests/sha256.dart';

import 'download_controller.dart';
import 'download_task.dart';
import 'task_store.dart';

const defaultProtocolE2eCasesJson = String.fromEnvironment(
  'FLUXDOWN_E2E_CASES_JSON',
);
const defaultProtocolE2eKeepOutputs = bool.fromEnvironment(
  'FLUXDOWN_E2E_KEEP_OUTPUTS',
);
const defaultProtocolE2eBaseDir = String.fromEnvironment(
  'FLUXDOWN_E2E_BASE_DIR',
);

class ProtocolE2eRunResult {
  const ProtocolE2eRunResult({required this.results, required this.failures});

  final List<Map<String, Object?>> results;
  final List<String> failures;
}

Future<ProtocolE2eRunResult> runProtocolE2e({
  String casesJson = defaultProtocolE2eCasesJson,
  bool keepOutputs = defaultProtocolE2eKeepOutputs,
  String baseDirOverride = defaultProtocolE2eBaseDir,
  void Function(String line)? emitLine,
}) async {
  final cases = loadProtocolE2eCases(casesJson);
  if (cases.isEmpty) {
    throw const FormatException(
      'Pass cases with --dart-define=FLUXDOWN_E2E_CASES_JSON=...',
    );
  }

  final baseDir = await _resolveBaseDir(baseDirOverride);
  final outputDir = Directory(p.join(baseDir.path, 'downloads'));
  await outputDir.create(recursive: true);

  late final DownloadController controller;
  var activeCaseId = '';
  var lastProgressPrint = DateTime.fromMillisecondsSinceEpoch(0);
  // 作者: long
  // 这里同时服务 flutter integration_test 和 simctl 启动的隐藏自检入口，所有平台验证都走同一套下载与断言逻辑。
  controller = DownloadController(
    store: TaskStore(baseDirectory: baseDir),
    onChanged: () {
      final now = DateTime.now();
      if (now.difference(lastProgressPrint).inSeconds < 10) {
        return;
      }
      lastProgressPrint = now;
      for (final task in controller.tasks) {
        if (task.state != DownloadState.running) {
          continue;
        }
        emitLine?.call(
          'FLUXDOWN_E2E_PROGRESS ${jsonEncode({'caseId': activeCaseId, 'taskId': task.id, 'state': task.state.name, 'downloadedBytes': task.downloadedBytes, 'totalBytes': task.totalBytes, 'speedBytesPerSecond': task.currentSpeedBytesPerSecond, 'error': task.error})}',
        );
      }
    },
  );
  await controller.load();

  final results = <Map<String, Object?>>[];
  final failures = <String>[];
  try {
    for (var index = 0; index < cases.length; index++) {
      final testCase = cases[index];
      activeCaseId = testCase.id;
      final source = testCase.source;
      final fileName = testCase.fileName;
      // 作者: long
      // 每个协议用例独占落盘目录，避免 Magnet 复用前一个 Torrent 用例的已下载文件。
      final caseOutputDir = Directory(
        p.join(outputDir.path, 'case_${index + 1}'),
      );
      await caseOutputDir.create(recursive: true);
      final task = await controller.add(
        source: source,
        outputFolder: caseOutputDir.path,
        fileName: fileName,
        selectedTorrentFileIndexes: testCase.selectedTorrentFileIndexes,
      );

      final started = DateTime.now().toUtc();
      Object? timeoutError;
      try {
        final download = controller.start(task.id);
        final timeoutSeconds = testCase.timeoutSeconds;
        if (timeoutSeconds == null) {
          await download;
        } else {
          await download.timeout(Duration(seconds: timeoutSeconds));
        }
      } on TimeoutException catch (error) {
        timeoutError = error;
        await controller.pause(task.id);
      }
      final finished = DateTime.now().toUtc();
      final actual = controller.tasks.firstWhere((item) => item.id == task.id);
      final outputFile = await _resolveOutputFile(
        outputDir: caseOutputDir,
        fileName: actual.fileName,
        outputRelativePath: testCase.outputRelativePath,
        scanForLargest:
            actual.protocol == 'torrent' || actual.protocol == 'magnet',
        selectedTorrentFiles: actual.selectedTorrentFiles,
      );
      final outputBytes = await outputFile.exists()
          ? await outputFile.length()
          : 0;
      final outputHeadHex = await _readHeadHex(outputFile);
      final outputSha256 = await _readSha256(outputFile);

      final result = <String, Object?>{
        'id': testCase.id,
        'protocol': actual.protocol,
        'source': source,
        'fileName': actual.fileName,
        'state': actual.state.name,
        'downloadedBytes': actual.downloadedBytes,
        'totalBytes': actual.totalBytes,
        'outputBytes': outputBytes,
        'outputHeadHex': outputHeadHex,
        'outputSha256': outputSha256,
        'outputPath': outputFile.path,
        'error': timeoutError == null
            ? actual.error
            : 'Timed out after ${testCase.timeoutSeconds}s',
        'startedAt': started.toIso8601String(),
        'finishedAt': finished.toIso8601String(),
      };
      results.add(result);
      emitLine?.call('FLUXDOWN_E2E_RESULT ${jsonEncode(result)}');

      _collectCaseFailures(
        testCase: testCase,
        task: actual,
        result: result,
        outputFile: outputFile,
        outputBytes: outputBytes,
        outputHeadHex: outputHeadHex,
        outputSha256: outputSha256,
        timeoutError: timeoutError,
        failures: failures,
      );
    }

    emitLine?.call('FLUXDOWN_E2E_SUMMARY ${jsonEncode(results)}');
    return ProtocolE2eRunResult(results: results, failures: failures);
  } finally {
    if (!keepOutputs && await baseDir.exists()) {
      await baseDir.delete(recursive: true);
    }
  }
}

List<ProtocolE2eCase> loadProtocolE2eCases(String casesJson) {
  if (casesJson.trim().isEmpty) {
    return const [];
  }
  final decoded = jsonDecode(casesJson);
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

Future<Directory> _resolveBaseDir(String override) async {
  if (override.trim().isEmpty) {
    // 作者: long
    // Android 沙盒中的 systemTemp 可能解析到不可写的 `/tmp`，导致真实设备自检在开始下载前就失败。
    // 使用应用临时目录既能保持测试产物隔离，也能让 Android/iOS 与桌面共享同一套夹具逻辑。
    final temporaryDirectory = await getTemporaryDirectory();
    final directory = Directory(
      p.join(
        temporaryDirectory.path,
        'fluxdown_mobile_protocol_e2e_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await directory.create(recursive: true);
    return directory;
  }

  final directory = Directory(override);
  await directory.create(recursive: true);
  return directory;
}

void _collectCaseFailures({
  required ProtocolE2eCase testCase,
  required DownloadTask task,
  required Map<String, Object?> result,
  required File outputFile,
  required int outputBytes,
  required String outputHeadHex,
  required String outputSha256,
  required Object? timeoutError,
  required List<String> failures,
}) {
  if (testCase.expectedState != null) {
    if (task.state.name != testCase.expectedState) {
      failures.add(
        '${testCase.id}: state ${task.state.name} != ${testCase.expectedState}',
      );
      return;
    }
    final expectedError = testCase.expectedErrorContains;
    if (expectedError != null &&
        !(result['error'] as String? ?? '').contains(expectedError)) {
      failures.add('${testCase.id}: error did not contain "$expectedError"');
    }
    return;
  }

  if (timeoutError != null) {
    failures.add('${testCase.id}: timed out');
    return;
  }
  if (task.state != DownloadState.finished) {
    failures.add('${testCase.id}: ${task.error ?? task.state.name}');
    return;
  }
  if (outputBytes <= 0) {
    failures.add('${testCase.id}: output was empty');
    return;
  }
  if (testCase.maxBytes != null && outputBytes > testCase.maxBytes!) {
    failures.add(
      '${testCase.id}: output $outputBytes exceeds ${testCase.maxBytes}',
    );
    return;
  }
  if (testCase.expectedBytes != null && outputBytes != testCase.expectedBytes) {
    failures.add(
      '${testCase.id}: output $outputBytes != ${testCase.expectedBytes}',
    );
    return;
  }
  if (testCase.expectedHeadHexContains != null &&
      !outputHeadHex.contains(testCase.expectedHeadHexContains!)) {
    failures.add(
      '${testCase.id}: output head did not contain ${testCase.expectedHeadHexContains}',
    );
    return;
  }
  if (testCase.expectedSha256 != null &&
      outputSha256 != testCase.expectedSha256!.toLowerCase()) {
    failures.add(
      '${testCase.id}: SHA-256 $outputSha256 != ${testCase.expectedSha256}',
    );
    return;
  }
  if (testCase.expectedText != null) {
    final text = outputFile.readAsStringSync();
    if (text != testCase.expectedText) {
      failures.add('${testCase.id}: output text did not match');
    }
  }
}

Future<String> _readHeadHex(File file) async {
  if (!await file.exists()) {
    return '';
  }
  final stream = file.openRead(0, 32);
  final chunks = <int>[];
  await for (final chunk in stream) {
    chunks.addAll(chunk);
  }
  return chunks.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

Future<String> _readSha256(File file) async {
  if (!await file.exists()) return '';
  final digest = SHA256Digest();
  await for (final chunk in file.openRead()) {
    final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    digest.update(bytes, 0, bytes.length);
  }
  final output = Uint8List(digest.digestSize);
  digest.doFinal(output, 0);
  return output.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

Future<File> _resolveOutputFile({
  required Directory outputDir,
  required String fileName,
  required String? outputRelativePath,
  required bool scanForLargest,
  required List<TorrentFileEntry> selectedTorrentFiles,
}) async {
  if (outputRelativePath != null && outputRelativePath.trim().isNotEmpty) {
    return File(
      p.joinAll([
        outputDir.path,
        ...outputRelativePath.split('/').where((part) => part.isNotEmpty),
      ]),
    );
  }

  final direct = File(p.join(outputDir.path, fileName));
  if (await direct.exists() || !scanForLargest) {
    return direct;
  }

  // 作者: long
  // Torrent/Magnet 目录下载会同时留下隐藏的 piece 临时文件；优先按 metadata 选中文件路径定位，
  // 避免把 `.parts` 等内部文件误当成最终产物，导致真实下载已成功却被 E2E 报告判错。
  for (final torrentFile in selectedTorrentFiles) {
    final parts = torrentFile.path
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty && part != '.' && part != '..')
        .toList(growable: false);
    if (parts.isEmpty) continue;
    final candidates = <String>{
      p.joinAll([outputDir.path, ...parts]),
    };
    if (parts.length > 1) {
      candidates.add(p.joinAll([outputDir.path, fileName, ...parts]));
    }
    for (final candidate in candidates) {
      final file = File(candidate);
      if (await file.exists() && await file.length() > 0) {
        return file;
      }
    }
  }

  File? largest;
  await for (final entity in outputDir.list(recursive: true)) {
    if (entity is! File) {
      continue;
    }
    final baseName = p.basename(entity.path);
    if (baseName.startsWith('.') || baseName.endsWith('.parts')) {
      continue;
    }
    if (largest == null || await entity.length() > await largest.length()) {
      largest = entity;
    }
  }
  return largest ?? direct;
}

class ProtocolE2eCase {
  const ProtocolE2eCase({
    required this.id,
    required this.source,
    this.fileName,
    this.outputRelativePath,
    this.maxBytes,
    this.expectedBytes,
    this.expectedText,
    this.expectedState,
    this.expectedErrorContains,
    this.expectedHeadHexContains,
    this.expectedSha256,
    this.timeoutSeconds,
    this.selectedTorrentFileIndexes,
  });

  factory ProtocolE2eCase.fromJson(Map<String, Object?> json) {
    return ProtocolE2eCase(
      id: json['id'] as String,
      source: json['source'] as String,
      fileName: json['fileName'] as String?,
      outputRelativePath: json['outputRelativePath'] as String?,
      maxBytes: json['maxBytes'] as int?,
      expectedBytes: json['expectedBytes'] as int?,
      expectedText: json['expectedText'] as String?,
      expectedState: json['expectedState'] as String?,
      expectedErrorContains: json['expectedErrorContains'] as String?,
      expectedHeadHexContains: json['expectedHeadHexContains'] as String?,
      expectedSha256: json['expectedSha256'] as String?,
      timeoutSeconds: json['timeoutSeconds'] as int?,
      selectedTorrentFileIndexes:
          (json['selectedTorrentFileIndexes'] as List<Object?>?)
              ?.map((value) => value is int ? value : int.tryParse('$value'))
              .whereType<int>()
              .toList(growable: false),
    );
  }

  final String id;
  final String source;
  final String? fileName;
  final String? outputRelativePath;
  final int? maxBytes;
  final int? expectedBytes;
  final String? expectedText;
  final String? expectedState;
  final String? expectedErrorContains;
  final String? expectedHeadHexContains;
  final String? expectedSha256;
  final int? timeoutSeconds;
  final List<int>? selectedTorrentFileIndexes;
}
