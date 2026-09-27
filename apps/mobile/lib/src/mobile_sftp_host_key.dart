import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

// 作者: long
/// 应用内保存的一条 OpenSSH known_hosts 主机密钥记录。
class MobileSftpKnownHostEntry {
  const MobileSftpKnownHostEntry({
    required this.hostPatterns,
    required this.keyType,
    required this.fingerprint,
  });

  final List<String> hostPatterns;
  final String keyType;
  final Uint8List fingerprint;
}

// 作者: long
/// 解析并校验移动端导入的 OpenSSH known_hosts 内容。
///
/// dartssh2 的回调提供主机密钥类型和 MD5 指纹，known_hosts 的第三列正好
/// 是同一份编码后的主机公钥，因此可以在不保存私钥、不放宽主机校验的前提下
/// 复用标准文件格式。哈希主机名和通配符条目暂不接受，避免出现无法审计的
/// 匹配范围；用户可以在 known_hosts 中为目标主机增加明确的 host 条目。
class MobileSftpKnownHosts {
  const MobileSftpKnownHosts._(this.entries);

  factory MobileSftpKnownHosts.parse(String content) {
    final entries = <MobileSftpKnownHostEntry>[];
    for (final rawLine in content.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final fields = line.split(RegExp(r'\s+'));
      if (fields.length < 3) continue;
      final hostPatterns = fields[0]
          .split(',')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
      if (hostPatterns.isEmpty || hostPatterns.any(_isUnsupportedPattern)) {
        continue;
      }
      try {
        final encodedKey = base64.decode(fields[2]);
        final fingerprint = Uint8List.fromList(
          MD5Digest().process(Uint8List.fromList(encodedKey)),
        );
        entries.add(
          MobileSftpKnownHostEntry(
            hostPatterns: hostPatterns,
            keyType: _normalizeKeyType(fields[1]),
            fingerprint: fingerprint,
          ),
        );
      } on Object {
        // 作者: long
        // 忽略损坏行而不是把整份 known_hosts 变成不可用配置；最终由空记录检查
        // 阻止用户保存完全无效的文件，其他有效主机仍可继续使用。
      }
    }
    if (entries.isEmpty) {
      throw const FormatException('known_hosts 中没有可用的主机密钥记录');
    }
    return MobileSftpKnownHosts._(List.unmodifiable(entries));
  }

  final List<MobileSftpKnownHostEntry> entries;

  bool verify({
    required String host,
    required int port,
    required String keyType,
    required Uint8List fingerprint,
  }) {
    final candidates = <String>{
      host,
      if (port != 22) '[$host]:$port',
      if (port == 22) '[$host]:22',
    };
    final normalizedType = _normalizeKeyType(keyType);
    return entries.any(
      (entry) =>
          entry.keyType == normalizedType &&
          entry.hostPatterns.any(candidates.contains) &&
          _sameBytes(entry.fingerprint, fingerprint),
    );
  }

  static bool _isUnsupportedPattern(String value) {
    return value.startsWith('|') || value.contains('*') || value.contains('?');
  }

  static String _normalizeKeyType(String value) {
    final normalized = value.trim().toLowerCase();
    return switch (normalized) {
      'rsa-sha2-256' || 'rsa-sha2-512' => 'ssh-rsa',
      _ => normalized,
    };
  }

  static bool _sameBytes(Uint8List left, Uint8List right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}
