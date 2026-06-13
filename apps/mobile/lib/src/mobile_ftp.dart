import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class FtpTransferSpec {
  const FtpTransferSpec({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.remotePath,
    required this.fileName,
    required this.secure,
    required this.implicitTls,
    this.allowBadCertificate = false,
  });

  factory FtpTransferSpec.fromUri(Uri uri, {String? fileName}) {
    if ((uri.scheme != 'ftp' && uri.scheme != 'ftps') ||
        uri.host.isEmpty ||
        uri.pathSegments.isEmpty) {
      throw FormatException('Invalid FTP URL: $uri');
    }

    final secure = uri.scheme == 'ftps';
    final port = uri.hasPort
        ? uri.port
        : secure
        ? 990
        : 21;
    final segment = uri.pathSegments
        .where((part) => part.trim().isNotEmpty)
        .last;
    return FtpTransferSpec(
      host: uri.host,
      port: port,
      username: uri.userInfo.isEmpty
          ? 'anonymous'
          : Uri.decodeComponent(uri.userInfo.split(':').first),
      password: _passwordFromUserInfo(uri.userInfo),
      remotePath: uri.pathSegments.map(Uri.decodeComponent).join('/'),
      fileName: fileName?.trim().isNotEmpty == true
          ? fileName!.trim()
          : Uri.decodeComponent(segment),
      secure: secure,
      implicitTls: secure && port == 990,
      allowBadCertificate: uri.queryParameters['allowBadCertificate'] == 'true',
    );
  }

  final String host;
  final int port;
  final String username;
  final String password;
  final String remotePath;
  final String fileName;
  final bool secure;
  final bool implicitTls;
  final bool allowBadCertificate;

  String get address => '$host:$port';

  static String _passwordFromUserInfo(String userInfo) {
    if (userInfo.isEmpty || !userInfo.contains(':')) {
      return 'anonymous@';
    }
    return Uri.decodeComponent(userInfo.split(':').skip(1).join(':'));
  }
}

class FtpResponse {
  const FtpResponse(this.code, this.message);

  final int code;
  final String message;
}

class MobileFtpClient {
  MobileFtpClient._(
    this._socket,
    this._lines, {
    required String host,
    required bool allowBadCertificate,
    required bool secureDataConnections,
  }) : _host = host,
       _allowBadCertificate = allowBadCertificate,
       _secureDataConnections = secureDataConnections;

  Socket _socket;
  StreamIterator<String> _lines;
  final String _host;
  final bool _allowBadCertificate;
  bool _secureDataConnections;

  static Future<MobileFtpClient> connect(FtpTransferSpec spec) async {
    final socket = spec.implicitTls
        ? await SecureSocket.connect(
            spec.host,
            spec.port,
            timeout: const Duration(seconds: 20),
            onBadCertificate: spec.allowBadCertificate ? (_) => true : null,
          )
        : await Socket.connect(
            spec.host,
            spec.port,
            timeout: const Duration(seconds: 20),
          );
    final lines = StreamIterator(
      utf8.decoder.bind(socket).transform(const LineSplitter()),
    );
    final client = MobileFtpClient._(
      socket,
      lines,
      host: spec.host,
      allowBadCertificate: spec.allowBadCertificate,
      secureDataConnections: spec.implicitTls,
    );
    await client.expect([220]);
    if (spec.secure && !spec.implicitTls) {
      await client.upgradeControlToTls();
    }
    return client;
  }

  Future<void> login(FtpTransferSpec spec) async {
    final user = await command('USER ${spec.username}');
    if (user.code == 331) {
      await expect([230], command: 'PASS ${spec.password}');
      return;
    }
    if (user.code != 230) {
      throw FtpException('USER failed: ${user.message}');
    }
  }

  Future<void> binary() async {
    await expect([200], command: 'TYPE I');
  }

  Future<void> protectDataConnections() async {
    if (!_secureDataConnections) {
      return;
    }
    await expect([200], command: 'PBSZ 0');
    await expect([200], command: 'PROT P');
  }

  Future<int?> size(String remotePath) async {
    final response = await command('SIZE $remotePath');
    if (response.code != 213) {
      return null;
    }
    final value = response.message.split(RegExp(r'\s+')).last.trim();
    return int.tryParse(value);
  }

  Future<void> resume(int offset) async {
    await expect([350], command: 'REST $offset');
  }

  Future<Socket> openPassiveDataSocket() async {
    final epsv = await command('EPSV');
    if (epsv.code == 229) {
      final port = _parseEpsvPort(epsv.message);
      return _connectDataSocket(_socket.remoteAddress, port);
    }

    final pasv = await expect([227], command: 'PASV');
    final endpoint = _parsePasvEndpoint(pasv.message);
    return _connectDataSocket(endpoint.host, endpoint.port);
  }

  Future<void> beginRetrieve(String remotePath) async {
    await expect([125, 150], command: 'RETR $remotePath');
  }

  Future<void> completeRetrieve() async {
    await expect([226, 250]);
  }

  Future<FtpResponse> command(String value) async {
    _socket.write('$value\r\n');
    await _socket.flush();
    return readResponse();
  }

  Future<void> upgradeControlToTls() async {
    await expect([234, 334], command: 'AUTH TLS');
    _socket = await SecureSocket.secure(
      _socket,
      host: _host,
      onBadCertificate: _allowBadCertificate ? (_) => true : null,
    );
    _lines = StreamIterator(
      utf8.decoder.bind(_socket).transform(const LineSplitter()),
    );
    _secureDataConnections = true;
  }

  Future<FtpResponse> expect(List<int> codes, {String? command}) async {
    final response = command == null
        ? await readResponse()
        : await this.command(command);
    if (!codes.contains(response.code)) {
      throw FtpException(
        'Expected ${codes.join('/')} but got ${response.code}: ${response.message}',
      );
    }
    return response;
  }

  Future<FtpResponse> readResponse() async {
    if (!await _lines.moveNext()) {
      throw const FtpException('FTP control connection closed.');
    }

    final first = _lines.current;
    if (first.length < 3) {
      throw FtpException('Invalid FTP response: $first');
    }

    final code = int.tryParse(first.substring(0, 3));
    if (code == null) {
      throw FtpException('Invalid FTP response code: $first');
    }

    final message = StringBuffer(first);
    if (first.length > 3 && first[3] == '-') {
      final terminator = '$code ';
      while (await _lines.moveNext()) {
        final line = _lines.current;
        message
          ..write('\n')
          ..write(line);
        if (line.startsWith(terminator)) {
          break;
        }
      }
    }

    return FtpResponse(code, message.toString());
  }

  Future<void> close() async {
    try {
      await command('QUIT');
    } on Object {
      // The connection may already be closed after failed transfers.
    }
    await _lines.cancel();
    await _socket.close();
  }

  Future<Socket> _connectDataSocket(Object host, int port) async {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 20),
    );
    if (!_secureDataConnections) {
      return socket;
    }
    return SecureSocket.secure(
      socket,
      host: _host,
      onBadCertificate: _allowBadCertificate ? (_) => true : null,
    );
  }
}

class FtpEndpoint {
  const FtpEndpoint(this.host, this.port);

  final String host;
  final int port;
}

class FtpException implements Exception {
  const FtpException(this.message);

  final String message;

  @override
  String toString() => 'FtpException: $message';
}

int _parseEpsvPort(String message) {
  final match = RegExp(r'\(\|\|\|(\d+)\|\)').firstMatch(message);
  final port = match == null ? null : int.tryParse(match.group(1)!);
  if (port == null) {
    throw FtpException('Invalid EPSV response: $message');
  }
  return port;
}

FtpEndpoint _parsePasvEndpoint(String message) {
  final match = RegExp(
    r'\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)',
  ).firstMatch(message);
  if (match == null) {
    throw FtpException('Invalid PASV response: $message');
  }
  final parts = List<int>.generate(
    6,
    (index) => int.parse(match.group(index + 1)!),
  );
  return FtpEndpoint(
    '${parts[0]}.${parts[1]}.${parts[2]}.${parts[3]}',
    parts[4] * 256 + parts[5],
  );
}

Future<int> pipeFtpData({
  required Socket dataSocket,
  required IOSink sink,
  required int startingBytes,
  required bool Function() isCancelled,
  FutureOr<void> Function(int byteCount)? throttleBytes,
  required FutureOr<void> Function(int downloadedBytes) onProgress,
}) async {
  var downloaded = startingBytes;
  await for (final chunk in dataSocket) {
    if (isCancelled()) {
      dataSocket.destroy();
      throw const FtpException('FTP download was cancelled.');
    }
    await throttleBytes?.call(chunk.length);
    if (isCancelled()) {
      dataSocket.destroy();
      throw const FtpException('FTP download was cancelled.');
    }
    sink.add(Uint8List.fromList(chunk));
    downloaded += chunk.length;
    await onProgress(downloaded);
  }
  await dataSocket.close();
  return downloaded;
}
