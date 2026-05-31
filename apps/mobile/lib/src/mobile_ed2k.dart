import 'dart:async';

import 'package:url_launcher/url_launcher.dart';

import 'download_task.dart';

typedef Ed2kLauncher = Future<bool> Function(Uri uri);

Future<DownloadTask> handOffEd2kTask(
  DownloadTask task, {
  required FutureOr<void> Function(DownloadTask task) onProgress,
  Ed2kLauncher launcher = launchEd2kUri,
}) async {
  final running = task.copyWith(state: DownloadState.running, clearError: true);
  await onProgress(running);

  final launched = await launcher(Uri.parse(task.source));
  if (!launched) {
    throw StateError(
      'No installed app can handle this ed2k link. Install an eMule/aMule-compatible client.',
    );
  }

  return running.copyWith(
    state: DownloadState.finished,
    downloadedBytes: 0,
    totalBytes: 0,
    clearError: true,
  );
}

Future<bool> launchEd2kUri(Uri uri) {
  return launchUrl(uri, mode: LaunchMode.externalNonBrowserApplication);
}
