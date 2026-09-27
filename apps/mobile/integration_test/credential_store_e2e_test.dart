import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdown_mobile/src/download_task.dart';
import 'package:fluxdown_mobile/src/mobile_credential_store.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('stores mobile credentials outside task JSON', (tester) async {
    final reference = 'e2e-${DateTime.now().microsecondsSinceEpoch}';
    final store = MobileCredentialStore();
    final credential = const MobileCredential(
      username: 'e2e-user',
      password: 'e2e-secret',
    );

    // 作者: long
    // 先清理同名引用，确保真机重复执行时不会把上一次的密钥误当成本轮结果。
    await store.deleteCredential(reference);
    await store.setCredential(reference, credential);
    final restored = await store.getCredential(reference);
    expect(restored?.username, credential.username);
    expect(restored?.password, credential.password);

    final task = DownloadTask.create(
      source: 'https://example.com/private.bin',
      outputFolder: '/tmp/fluxdown-e2e',
      credentialRef: reference,
    );
    final taskJson = task.toJson().toString();
    expect(taskJson, contains(reference));
    expect(taskJson, isNot(contains(credential.password)));

    await store.deleteCredential(reference);
    expect(await store.getCredential(reference), isNull);
  });

  testWidgets('stores an SFTP private key outside task JSON', (tester) async {
    final reference = 'e2e-sftp-key-${DateTime.now().microsecondsSinceEpoch}';
    final store = MobileCredentialStore();
    const privateKey = '''-----BEGIN OPENSSH PRIVATE KEY-----
e2e-private-key
-----END OPENSSH PRIVATE KEY-----''';
    const passphrase = 'e2e-key-passphrase';
    const credential = MobileCredential.privateKey(
      username: 'e2e-sftp-user',
      privateKeyPem: privateKey,
      passphrase: passphrase,
    );

    await store.deleteCredential(reference);
    await store.setCredential(reference, credential);
    final restored = await store.getCredential(reference);
    expect(restored?.usesPrivateKey, isTrue);
    expect(restored?.username, credential.username);
    expect(restored?.privateKeyPem, privateKey);
    expect(restored?.passphrase, passphrase);

    final task = DownloadTask.create(
      source: 'sftp://example.com/incoming/file.bin',
      outputFolder: '/tmp/fluxdown-e2e',
      credentialRef: reference,
    );
    final taskJson = task.toJson().toString();
    expect(taskJson, contains(reference));
    expect(taskJson, isNot(contains(privateKey)));
    expect(taskJson, isNot(contains(passphrase)));

    await store.deleteCredential(reference);
    expect(await store.getCredential(reference), isNull);
  });
}
