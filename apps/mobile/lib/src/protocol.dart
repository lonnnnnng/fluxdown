class ProtocolSupport {
  const ProtocolSupport({
    required this.backendLabel,
    required this.executable,
    required this.note,
  });

  final String backendLabel;
  final bool executable;
  final String note;
}

ProtocolSupport supportStatus(String protocol) {
  if (protocol == 'http' || protocol == 'https') {
    return const ProtocolSupport(
      backendLabel: 'Built-in mobile',
      executable: true,
      note: 'Native HTTP downloader with progress, pause, and Range resume.',
    );
  }

  if (protocol == 'webdav' || protocol == 'webdavs') {
    return const ProtocolSupport(
      backendLabel: 'Built-in mobile',
      executable: true,
      note:
          'Native WebDAV downloader over HTTP/WebDAVS with progress, pause, and Range resume.',
    );
  }

  if (protocol == 'ipfs') {
    return const ProtocolSupport(
      backendLabel: 'Built-in mobile',
      executable: true,
      note: 'Native IPFS gateway downloader with HTTP progress and resume.',
    );
  }

  if (protocol == 'm3u8') {
    return const ProtocolSupport(
      backendLabel: 'Built-in mobile',
      executable: true,
      note:
          'Native VOD HLS downloader with master playlist selection, byte ranges, and AES-128 segment decryption.',
    );
  }

  if (protocol == 'ftp' || protocol == 'ftps') {
    return const ProtocolSupport(
      backendLabel: 'Built-in mobile',
      executable: true,
      note:
          'Native FTP/FTPS downloader with passive mode, progress, pause, and REST resume.',
    );
  }

  if (protocol == 'sftp') {
    return const ProtocolSupport(
      backendLabel: 'Built-in mobile',
      executable: true,
      note:
          'Native SFTP downloader with password authentication, progress, pause, and offset resume.',
    );
  }

  if (protocol == 'torrent' || protocol == 'magnet') {
    return const ProtocolSupport(
      backendLabel: 'Built-in mobile',
      executable: true,
      note: 'Native libtorrent downloader for .torrent files and magnet links.',
    );
  }

  if (protocol == 'ed2k') {
    return const ProtocolSupport(
      backendLabel: 'Mobile handoff',
      executable: true,
      note: 'Hands ed2k links to an installed eMule/aMule-compatible app.',
    );
  }

  if (protocol == 'smb') {
    return const ProtocolSupport(
      backendLabel: 'Built-in mobile',
      executable: true,
      note:
          'Native SMB2/3 file download backend with progress and cancellation.',
    );
  }

  return const ProtocolSupport(
    backendLabel: 'Planned',
    executable: false,
    note: 'No backend has been configured for this source yet.',
  );
}

String detectProtocol(String source) {
  final value = source.trim().toLowerCase();
  if (value.startsWith('magnet:?')) return 'magnet';
  if (value.startsWith('ed2k://')) return 'ed2k';
  if (_hasPathExtension(value, '.torrent')) return 'torrent';
  if (_hasPathExtension(value, '.m3u8')) return 'm3u8';
  if (value.startsWith('https://')) return 'https';
  if (value.startsWith('http://')) return 'http';
  if (value.startsWith('webdavs://')) return 'webdavs';
  if (value.startsWith('webdav://')) return 'webdav';
  if (value.startsWith('ftps://')) return 'ftps';
  if (value.startsWith('ftp://')) return 'ftp';
  if (value.startsWith('sftp://')) return 'sftp';
  if (value.startsWith('smb://')) return 'smb';
  if (value.startsWith('ipfs://')) return 'ipfs';
  return 'unknown';
}

bool _hasPathExtension(String value, String extension) {
  if (value.endsWith(extension)) return true;
  final uri = Uri.tryParse(value);
  return uri != null && uri.path.toLowerCase().endsWith(extension);
}
