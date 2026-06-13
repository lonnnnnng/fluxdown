import 'dart:async';

import 'package:flutter/services.dart';
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

  late final bool launched;
  try {
    launched = await launcher(Uri.parse(task.source));
  } on PlatformException catch (error) {
    if (error.code == 'ACTIVITY_NOT_FOUND') {
      throw StateError(_noEd2kHandlerMessage);
    }
    rethrow;
  }
  if (!launched) {
    throw StateError(_noEd2kHandlerMessage);
  }

  return running.copyWith(
    state: DownloadState.finished,
    downloadedBytes: 0,
    totalBytes: 0,
    clearError: true,
  );
}

const _noEd2kHandlerMessage =
    'No installed app can handle this ed2k link. Install an eMule/aMule-compatible client.';

Future<bool> launchEd2kUri(Uri uri) {
  return launchUrl(uri, mode: LaunchMode.externalNonBrowserApplication);
}
