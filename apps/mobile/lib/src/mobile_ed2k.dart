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
    // 作者: long
    // 外部应用接收链接只代表移交成功，FluxDown 无法读取其下载进度，因此不能标记为已完成。
    state: DownloadState.handedOff,
    downloadedBytes: 0,
    clearTotalBytes: true,
    clearError: true,
  );
}

const _noEd2kHandlerMessage =
    'No installed app can handle this ed2k link. Install an eMule/aMule-compatible client.';

Future<bool> launchEd2kUri(Uri uri) {
  return launchUrl(uri, mode: LaunchMode.externalNonBrowserApplication);
}
