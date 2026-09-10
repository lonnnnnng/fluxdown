import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

class DownloadFailureInfo {
  const DownloadFailureInfo({required this.message, required this.retryable});

  final String message;
  final bool retryable;
}

class IncompleteTransferException implements Exception {
  const IncompleteTransferException({
    required this.protocol,
    required this.expectedBytes,
    required this.actualBytes,
  });

  final String protocol;
  final int expectedBytes;
  final int actualBytes;

  @override
  String toString() {
    return '${protocol.toUpperCase()} 传输中断：已下载 $actualBytes/$expectedBytes 字节';
  }
}

DownloadFailureInfo describeDownloadFailure(
  Object error, {
  required String source,
  required String protocol,
}) {
  if (error is IncompleteTransferException) {
    return DownloadFailureInfo(
      message: error.actualBytes < error.expectedBytes
          ? '$error，请检查网络后重试。'
          : '${error.protocol.toUpperCase()} 本地文件大小异常：已有 ${error.actualBytes} 字节，远端为 ${error.expectedBytes} 字节，请重新下载。',
      retryable: error.actualBytes < error.expectedBytes,
    );
  }

  if (error is FileSystemException) {
    return _fileSystemFailure(error);
  }

  if (error is HandshakeException || error is TlsException) {
    return const DownloadFailureInfo(
      message: '证书验证或 TLS 握手失败，请检查服务端证书和连接模式。',
      retryable: false,
    );
  }

  if (error is SocketException ||
      error is TimeoutException ||
      error is http.ClientException) {
    return const DownloadFailureInfo(
      message: '网络连接失败，请检查网络、代理或服务器地址后重试。',
      retryable: true,
    );
  }

  final safeText = redactDownloadErrorText(error.toString(), source: source);
  final normalized = safeText.toLowerCase();
  final status = _statusCodeFromText(normalized);
  if (status == 401 ||
      status == 403 ||
      status == 430 ||
      status == 530 ||
      normalized.contains('authentication') ||
      normalized.contains('invalid credential') ||
      normalized.contains('login failed') ||
      normalized.contains('access denied')) {
    return DownloadFailureInfo(
      message: '${protocol.toUpperCase()} 认证失败，请检查账号、密码和访问权限。',
      retryable: false,
    );
  }

  if (status == 404 ||
      status == 410 ||
      status == 550 ||
      normalized.contains('not found') ||
      normalized.contains('no such file')) {
    return DownloadFailureInfo(
      message: '${protocol.toUpperCase()} 下载资源不存在或路径已失效，请检查链接。',
      retryable: false,
    );
  }

  if (status == 408 || status == 429 || (status != null && status >= 500)) {
    return DownloadFailureInfo(
      message: status == 429
          ? '服务器请求过于频繁，请稍后重试。'
          : '服务器暂时不可用（HTTP $status），请稍后重试。',
      retryable: true,
    );
  }

  if (_containsAny(normalized, const [
    'no peer',
    'no download progress',
    'tracker',
    'peer unavailable',
  ])) {
    return const DownloadFailureInfo(
      message: '暂无可用 Peer 或 Tracker 未响应，请检查网络、Tracker 后稍后重试。',
      retryable: false,
    );
  }

  if (_containsAny(normalized, const [
    'certificate',
    'tls',
    'handshake',
    'host key',
  ])) {
    return DownloadFailureInfo(
      message: '${protocol.toUpperCase()} 安全连接失败，请检查证书、主机身份和连接模式。',
      retryable: false,
    );
  }

  if (_containsAny(normalized, const [
    'timeout',
    'timed out',
    'connection reset',
    'connection refused',
    'connection closed',
    'disconnected',
    'network unreachable',
    'host unreachable',
    'broken pipe',
  ])) {
    return DownloadFailureInfo(
      message: '${protocol.toUpperCase()} 连接中断，请检查网络后重试。',
      retryable: true,
    );
  }

  if (error is FormatException || error is ArgumentError) {
    return const DownloadFailureInfo(
      message: '下载链接或协议参数无效，请检查后重新创建任务。',
      retryable: false,
    );
  }

  // 作者: long
  // 未识别异常默认不自动重试，避免认证、路径和协议配置错误在后台反复消耗带宽；属性页仍保留脱敏后的简短详情。
  return DownloadFailureInfo(
    message: '${protocol.toUpperCase()} 下载失败：$safeText',
    retryable: false,
  );
}

String redactDownloadErrorText(String text, {required String source}) {
  var safe = text;
  final uri = Uri.tryParse(source.trim());
  if (uri != null && uri.userInfo.isNotEmpty) {
    safe = safe.replaceAll(source, uri.replace(userInfo: '***').toString());
  }
  return safe.replaceAllMapped(
    RegExp(r'([a-z][a-z0-9+.-]*://)([^/@\s]+)@', caseSensitive: false),
    (match) => '${match.group(1)}***@',
  );
}

DownloadFailureInfo _fileSystemFailure(FileSystemException error) {
  final osMessage = error.osError?.message.toLowerCase() ?? '';
  final code = error.osError?.errorCode;
  if (code == 28 ||
      code == 39 ||
      code == 112 ||
      osMessage.contains('no space left') ||
      osMessage.contains('disk full')) {
    return const DownloadFailureInfo(
      message: '磁盘空间不足，请释放空间或更换下载保存位置。',
      retryable: false,
    );
  }
  if (code == 1 ||
      code == 5 ||
      code == 13 ||
      code == 30 ||
      osMessage.contains('permission denied') ||
      osMessage.contains('access denied') ||
      osMessage.contains('read-only')) {
    return const DownloadFailureInfo(
      message: '当前下载保存位置不可写，请重新选择目录并授予访问权限。',
      retryable: false,
    );
  }
  return const DownloadFailureInfo(
    message: '文件读写失败，请检查下载保存位置和存储设备后重试。',
    retryable: false,
  );
}

int? _statusCodeFromText(String text) {
  final matches = RegExp(r'\b(?:http\s*)?([45]\d{2})\b').allMatches(text);
  final match = matches.isEmpty ? null : matches.last;
  return match == null ? null : int.tryParse(match.group(1)!);
}

bool _containsAny(String value, List<String> candidates) {
  return candidates.any(value.contains);
}
