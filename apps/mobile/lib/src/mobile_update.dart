import 'dart:convert';

import 'package:http/http.dart' as http;

// 作者: long
// 移动端版本号与 pubspec.yaml 保持同步，避免为版本展示引入额外运行时依赖。
const mobileAppVersion = '1.0.20';
const mobileUpdateApiUrl =
    'https://api.github.com/repos/lonnnnnng/fluxdown/releases/latest';
const mobileReleasePageUrl =
    'https://github.com/lonnnnnng/fluxdown/releases/latest';

class MobileUpdateException implements Exception {
  const MobileUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class MobileUpdateReport {
  const MobileUpdateReport({
    required this.currentVersion,
    required this.latestVersion,
    required this.hasUpdate,
    required this.releaseUrl,
    this.releaseNotes,
    this.publishedAt,
    this.downloadUrl,
    this.downloadFileName,
    this.downloadSizeBytes,
  });

  final String currentVersion;
  final String latestVersion;
  final bool hasUpdate;
  final String releaseUrl;
  final String? releaseNotes;
  final String? publishedAt;
  final String? downloadUrl;
  final String? downloadFileName;
  final int? downloadSizeBytes;
}

class MobileUpdateChecker {
  MobileUpdateChecker({
    http.Client? client,
    this.currentVersion = mobileAppVersion,
    Uri? apiUri,
  }) : _client = client,
       apiUri = apiUri ?? Uri.parse(mobileUpdateApiUrl);

  final http.Client? _client;
  final String currentVersion;
  final Uri apiUri;

  Future<MobileUpdateReport> check() async {
    final client = _client ?? http.Client();
    try {
      final response = await client
          .get(
            apiUri,
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'FluxDown-Mobile',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw MobileUpdateException('更新服务器返回错误（${response.statusCode}）。');
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw const MobileUpdateException('更新信息格式无效。');
      }
      final release = Map<String, dynamic>.from(decoded);
      final latestVersion = normalizeMobileVersion(
        release['tag_name']?.toString() ?? '',
      );
      if (latestVersion.isEmpty) {
        throw const MobileUpdateException('更新信息缺少版本号。');
      }

      final asset = _findAndroidApk(release['assets']);
      final releaseUrl =
          _nonEmptyString(release['html_url']) ?? mobileReleasePageUrl;
      final current = normalizeMobileVersion(currentVersion);
      return MobileUpdateReport(
        currentVersion: current.isEmpty ? currentVersion : current,
        latestVersion: latestVersion,
        hasUpdate: compareMobileVersions(latestVersion, current) > 0,
        releaseUrl: releaseUrl,
        releaseNotes: _nonEmptyString(release['body']),
        publishedAt: _nonEmptyString(release['published_at']),
        downloadUrl: asset?.url,
        downloadFileName: asset?.name,
        downloadSizeBytes: asset?.size,
      );
    } on MobileUpdateException {
      rethrow;
    } on FormatException {
      throw const MobileUpdateException('无法解析更新信息。');
    } catch (_) {
      throw const MobileUpdateException('检查更新失败，请稍后重试。');
    } finally {
      if (_client == null) {
        client.close();
      }
    }
  }
}

class _MobileUpdateAsset {
  const _MobileUpdateAsset({required this.name, required this.url, this.size});

  final String name;
  final String url;
  final int? size;
}

_MobileUpdateAsset? _findAndroidApk(Object? rawAssets) {
  if (rawAssets is! List) return null;
  for (final rawAsset in rawAssets) {
    if (rawAsset is! Map) continue;
    final name = _nonEmptyString(rawAsset['name']);
    final url = _nonEmptyString(rawAsset['browser_download_url']);
    if (name == null || url == null) continue;
    final lowerName = name.toLowerCase();
    if (!lowerName.endsWith('.apk') ||
        !lowerName.endsWith('-android-release.apk')) {
      continue;
    }
    final rawSize = rawAsset['size'];
    final size = rawSize is num ? rawSize.toInt() : int.tryParse('$rawSize');
    return _MobileUpdateAsset(name: name, url: url, size: size);
  }
  return null;
}

String? _nonEmptyString(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

String normalizeMobileVersion(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  final withoutPrefix = trimmed.replaceFirst(RegExp(r'^[vV]'), '');
  return withoutPrefix.split(RegExp(r'[-+]')).first.trim();
}

int compareMobileVersions(String left, String right) {
  final leftParts = _versionParts(left);
  final rightParts = _versionParts(right);
  final length = leftParts.length > rightParts.length
      ? leftParts.length
      : rightParts.length;
  for (var index = 0; index < length; index += 1) {
    final leftPart = index < leftParts.length ? leftParts[index] : 0;
    final rightPart = index < rightParts.length ? rightParts[index] : 0;
    if (leftPart != rightPart) return leftPart.compareTo(rightPart);
  }
  return 0;
}

List<int> _versionParts(String value) {
  final normalized = normalizeMobileVersion(value);
  final matches = RegExp(r'\d+').allMatches(normalized);
  if (matches.isEmpty) return const [0];
  return matches.map((match) => int.parse(match.group(0)!)).toList();
}
