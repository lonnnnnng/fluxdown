import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:fluxdown_mobile/src/mobile_credential_store.dart';
import 'package:fluxdown_mobile/src/mobile_sftp.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'downloads through a mobile SFTP private key and rejects a bad host key',
    (tester) async {
      const genericPortText = String.fromEnvironment(
        'FLUXDOWN_MOBILE_SFTP_PORT',
      );
      const genericKnownHostsBase64 = String.fromEnvironment(
        'FLUXDOWN_MOBILE_SFTP_KNOWN_HOSTS',
      );
      const genericPrivateKeyBase64 = String.fromEnvironment(
        'FLUXDOWN_MOBILE_SFTP_PRIVATE_KEY',
      );
      const genericPassphrase = String.fromEnvironment(
        'FLUXDOWN_MOBILE_SFTP_PASSPHRASE',
      );
      // 作者: long
      // 保留 Android 旧参数名，避免已有真机脚本在统一入口迁移期间失效；新入口使用 MOBILE 前缀，iOS simulator/真机可直接复用同一用例。
      const legacyPortText = String.fromEnvironment(
        'FLUXDOWN_ANDROID_SFTP_PORT',
      );
      const legacyKnownHostsBase64 = String.fromEnvironment(
        'FLUXDOWN_ANDROID_SFTP_KNOWN_HOSTS',
      );
      const legacyPrivateKeyBase64 = String.fromEnvironment(
        'FLUXDOWN_ANDROID_SFTP_PRIVATE_KEY',
      );
      const legacyPassphrase = String.fromEnvironment(
        'FLUXDOWN_ANDROID_SFTP_PASSPHRASE',
      );
      final portText = genericPortText.isNotEmpty
          ? genericPortText
          : legacyPortText;
      final knownHostsBase64 = genericKnownHostsBase64.isNotEmpty
          ? genericKnownHostsBase64
          : legacyKnownHostsBase64;
      final privateKeyBase64 = genericPrivateKeyBase64.isNotEmpty
          ? genericPrivateKeyBase64
          : legacyPrivateKeyBase64;
      final passphrase = genericPassphrase.isNotEmpty
          ? genericPassphrase
          : legacyPassphrase;
      const host = String.fromEnvironment(
        'FLUXDOWN_MOBILE_SFTP_HOST',
        defaultValue: '127.0.0.1',
      );
      const username = String.fromEnvironment(
        'FLUXDOWN_MOBILE_SFTP_USERNAME',
        defaultValue: 'flux',
      );
      const remotePath = String.fromEnvironment(
        'FLUXDOWN_MOBILE_SFTP_REMOTE_PATH',
        defaultValue: '/upload/fixture.txt',
      );
      const expectedContentBase64 = String.fromEnvironment(
        'FLUXDOWN_MOBILE_SFTP_EXPECTED_CONTENT_BASE64',
      );
      final expectedContent = expectedContentBase64.isNotEmpty
          ? utf8.decode(base64Decode(expectedContentBase64))
          : legacyPortText.isNotEmpty
          ? 'android sftp private key fixture\n'
          : 'mobile sftp private key fixture\n';
      if (portText.isEmpty ||
          knownHostsBase64.isEmpty ||
          privateKeyBase64.isEmpty) {
        markTestSkipped(
          'Set FLUXDOWN_MOBILE_SFTP_PORT, _KNOWN_HOSTS and _PRIVATE_KEY for the external fixture.',
        );
        return;
      }

      final port = int.parse(portText);
      final knownHosts = utf8.decode(base64Decode(knownHostsBase64));
      final privateKeyPem = utf8.decode(base64Decode(privateKeyBase64));
      final baseDir = await getTemporaryDirectory();
      final outputDir = await Directory(
        p.join(baseDir.path, 'fluxdown-sftp-e2e'),
      ).create(recursive: true);
      final outputFile = File(p.join(outputDir.path, 'fixture.txt'));
      final spec = SftpTransferSpec.fromUri(
        Uri.parse('sftp://$username@$host:$port$remotePath'),
      );
      final runtimeCredential = MobileCredential.privateKey(
        username: username,
        privateKeyPem: privateKeyPem,
        passphrase: passphrase.isEmpty ? null : passphrase,
      );

      final client = await MobileSftpClient.connect(
        spec,
        knownHosts: knownHosts,
        credential: runtimeCredential,
      );
      try {
        final totalBytes = await client.size(spec.remotePath);
        expect(totalBytes, greaterThan(0));
        final sink = outputFile.openWrite();
        try {
          final downloaded = await client.download(
            remotePath: spec.remotePath,
            sink: sink,
            startingBytes: 0,
            isCancelled: () => false,
            onProgress: (_) {},
          );
          expect(downloaded, totalBytes);
        } finally {
          await sink.flush();
          await sink.close();
        }
        expect(await outputFile.readAsString(), expectedContent);
      } finally {
        await client.close();
      }

      final knownHost = port == 22 ? host : '[$host]:$port';
      final badKnownHosts =
          '$knownHost ssh-ed25519 ${base64Encode(const <int>[1, 2, 3, 4])}\n';
      expect(
        () => MobileSftpClient.connect(
          spec,
          knownHosts: badKnownHosts,
          credential: runtimeCredential,
        ),
        throwsA(anything),
      );
      expect(await outputFile.readAsString(), expectedContent);
    },
  );
}
