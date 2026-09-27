import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// 作者: long
/// 移动端运行时凭据；只存在内存中，不参与任务 JSON 序列化。
///
/// 私钥和口令只能通过 [MobileCredentialStore] 从 Keystore/Keychain 取出，
/// 任务 JSON 只保存引用名，避免队列备份、日志或同步文件携带认证材料。
class MobileCredential {
  const MobileCredential({
    required this.username,
    required this.password,
    this.privateKeyPem,
    this.passphrase,
  });

  const MobileCredential.privateKey({
    required this.username,
    required this.privateKeyPem,
    this.passphrase,
  }) : password = '';

  final String username;
  final String password;
  final String? privateKeyPem;
  final String? passphrase;

  bool get usesPrivateKey => privateKeyPem?.trim().isNotEmpty == true;
}

/// 可替换的凭据库接口，便于 Flutter 单测验证任务链路而不触碰真实设备密钥库。
abstract interface class MobileCredentialVault {
  Future<void> setCredential(String reference, MobileCredential credential);

  Future<MobileCredential?> getCredential(String reference);

  Future<void> deleteCredential(String reference);
}

/// Android 使用 Keystore 加密，iOS 使用 Keychain 保存凭据内容。
class MobileCredentialStore implements MobileCredentialVault {
  MobileCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _keyPrefix = 'fluxdown.credential.v1.';
  final FlutterSecureStorage _storage;

  @override
  Future<void> setCredential(
    String reference,
    MobileCredential credential,
  ) async {
    final normalized = _normalizeReference(reference);
    _validateCredential(credential);
    await _storage.write(
      key: _storageKey(normalized),
      value: jsonEncode({
        'username': credential.username,
        'authType': credential.usesPrivateKey ? 'privateKey' : 'password',
        if (!credential.usesPrivateKey) 'password': credential.password,
        if (credential.usesPrivateKey) ...{
          'privateKeyPem': credential.privateKeyPem,
          'passphrase': credential.passphrase,
        },
      }),
    );
  }

  @override
  Future<MobileCredential?> getCredential(String reference) async {
    final normalized = _normalizeReference(reference);
    final raw = await _storage.read(key: _storageKey(normalized));
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map) return null;
      final username = value['username'];
      if (username is! String || username.trim().isEmpty) {
        return null;
      }
      if (value['authType'] == 'privateKey') {
        final privateKeyPem = value['privateKeyPem'];
        final passphrase = value['passphrase'];
        if (privateKeyPem is! String || privateKeyPem.trim().isEmpty) {
          return null;
        }
        if (passphrase != null && passphrase is! String) return null;
        return MobileCredential.privateKey(
          username: username,
          privateKeyPem: privateKeyPem,
          passphrase: passphrase as String?,
        );
      }
      final password = value['password'];
      if (password is! String) return null;
      return MobileCredential(username: username, password: password);
    } on Object {
      // 作者: long
      // 密钥库内容损坏时按“凭据不存在”处理，不能把密钥内容或解密异常写入任务错误。
      return null;
    }
  }

  @override
  Future<void> deleteCredential(String reference) {
    final normalized = _normalizeReference(reference);
    return _storage.delete(key: _storageKey(normalized));
  }

  String _storageKey(String reference) =>
      '$_keyPrefix${base64Url.encode(utf8.encode(reference))}';

  static String _normalizeReference(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > 128) {
      throw const FormatException('凭据引用无效');
    }
    return normalized;
  }

  static void _validateCredential(MobileCredential credential) {
    if (credential.username.trim().isEmpty) {
      throw const FormatException('凭据用户名不能为空');
    }
    if (credential.usesPrivateKey) {
      final pem = credential.privateKeyPem!.trim();
      if (pem.length > 256 * 1024) {
        throw const FormatException('SFTP 私钥文件过大');
      }
      if (!pem.contains('PRIVATE KEY')) {
        throw const FormatException('SFTP 私钥格式无效');
      }
      return;
    }
  }
}

/// 将密钥库中的认证信息注入一次性下载 URL；调用方不得把返回值写回任务。
String sourceWithMobileCredential(String source, MobileCredential credential) {
  if (credential.usesPrivateKey) {
    throw const FormatException('SFTP 私钥凭据不能注入密码 URL');
  }
  final uri = Uri.parse(source);
  if (uri.userInfo.isNotEmpty) {
    throw const FormatException('下载链接已包含凭据，不能重复使用凭据引用');
  }
  final userInfo =
      '${Uri.encodeComponent(credential.username)}:${Uri.encodeComponent(credential.password)}';
  return uri.replace(userInfo: userInfo).toString();
}

// 作者: long
/// 为 SFTP 私钥认证注入用户名，但不把私钥或口令写进 URL。
String sourceWithMobileUsername(String source, String username) {
  final normalizedUsername = username.trim();
  if (normalizedUsername.isEmpty) {
    throw const FormatException('凭据用户名不能为空');
  }
  final uri = Uri.parse(source);
  if (uri.userInfo.isNotEmpty) {
    final parts = uri.userInfo.split(':');
    if (parts.length > 1 || parts.first.trim().isEmpty) {
      throw const FormatException('下载链接已包含密码，不能重复使用私钥凭据');
    }
    final sourceUsername = Uri.decodeComponent(parts.first);
    if (sourceUsername != normalizedUsername) {
      throw const FormatException('链接中的 SFTP 用户名与凭据不一致');
    }
    return uri.toString();
  }
  return uri
      .replace(userInfo: Uri.encodeComponent(normalizedUsername))
      .toString();
}
