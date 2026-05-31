import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'download_task.dart';

class TaskStore {
  TaskStore({Directory? baseDirectory}) : _baseDirectory = baseDirectory;

  final Directory? _baseDirectory;

  Future<File> get queueFile async {
    final base = _baseDirectory ?? await getApplicationDocumentsDirectory();
    return File(p.join(base.path, 'fluxdown', 'queue.json'));
  }

  Future<List<DownloadTask>> load() async {
    final file = await queueFile;
    if (!await file.exists()) {
      return [];
    }

    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return [];
    }

    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Queue file must contain a JSON array.');
    }

    return decoded
        .map(
          (item) =>
              DownloadTask.fromJson(Map<String, Object?>.from(item as Map)),
        )
        .toList();
  }

  Future<void> save(List<DownloadTask> tasks) async {
    final file = await queueFile;
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    final tempFile = File(
      p.join(
        file.parent.path,
        '${file.uri.pathSegments.last}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    await tempFile.writeAsString(
      encoder.convert(tasks.map((task) => task.toJson()).toList()),
      flush: true,
    );
    await tempFile.rename(file.path);
  }
}
