import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

import 'package:fluxdown_mobile/src/mobile_credential_store.dart';
import 'package:fluxdown_mobile/src/mobile_sftp.dart';
import 'package:fluxdown_mobile/src/mobile_sftp_host_key.dart';

void main() {
  test('matches an exact known_hosts host and port', () {
    final encodedKey = base64.encode(const <int>[1, 2, 3, 4]);
    final fingerprint = Uint8List.fromList(
      MD5Digest().process(Uint8List.fromList(const <int>[1, 2, 3, 4])),
    );
    final hosts = MobileSftpKnownHosts.parse(
      'example.com ssh-ed25519 $encodedKey\n',
    );

    expect(
      hosts.verify(
        host: 'example.com',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: fingerprint,
      ),
      isTrue,
    );
    expect(
      hosts.verify(
        host: 'other.example.com',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: fingerprint,
      ),
      isFalse,
    );
  });

  test('matches non-default port notation and rsa aliases', () {
    final key = Uint8List.fromList(const <int>[5, 6, 7]);
    final encodedKey = base64.encode(key);
    final fingerprint = Uint8List.fromList(MD5Digest().process(key));
    final hosts = MobileSftpKnownHosts.parse(
      '[example.com]:2222 ssh-rsa $encodedKey\n',
    );

    expect(
      hosts.verify(
        host: 'example.com',
        port: 2222,
        keyType: 'rsa-sha2-256',
        fingerprint: fingerprint,
      ),
      isTrue,
    );
  });

  test('rejects a changed fingerprint and unsupported host patterns', () {
    final key = Uint8List.fromList(const <int>[8, 9, 10]);
    final encodedKey = base64.encode(key);
    final hosts = MobileSftpKnownHosts.parse(
      '*.example.com ssh-ed25519 $encodedKey\n'
      '|1|hashed-host|hashed-value ssh-ed25519 $encodedKey\n'
      'trusted.example.com ssh-ed25519 $encodedKey\n',
    );

    expect(hosts.entries, hasLength(1));
    expect(
      hosts.verify(
        host: 'trusted.example.com',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: Uint8List.fromList(const <int>[0, 1, 2]),
      ),
      isFalse,
    );
  });

  test('rejects a file without usable host keys', () {
    expect(
      () => MobileSftpKnownHosts.parse('# comment\nnot a known_hosts row'),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'private-key connection rejects malformed PEM before opening a socket',
    () async {
      final spec = SftpTransferSpec.fromUri(
        Uri.parse('sftp://alice@example.com/incoming/file.bin'),
      );
      expect(
        () => MobileSftpClient.connect(
          spec,
          credential: const MobileCredential.privateKey(
            username: 'alice',
            privateKeyPem: 'not-a-private-key',
            passphrase: null,
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            isNot(contains('not-a-private-key')),
          ),
        ),
      );
    },
  );

  test('injects only the SFTP username for a private-key task', () {
    expect(
      sourceWithMobileUsername(
        'sftp://example.com/incoming/file.bin',
        'alice@example',
      ),
      'sftp://alice%40example@example.com/incoming/file.bin',
    );
    expect(
      sourceWithMobileUsername(
        'sftp://alice@example.com/incoming/file.bin',
        'alice',
      ),
      'sftp://alice@example.com/incoming/file.bin',
    );
  });
}
