// FIX: P0-01 — Custom Exceptions for DMX Download Engine

class IsolateSpawnTimeoutException implements Exception {
  final String message;
  const IsolateSpawnTimeoutException([
    this.message = 'Download engine failed to initialize. Please retry.',
  ]);
  @override
  String toString() => 'IsolateSpawnTimeoutException: $message';
}

class InsufficientStorageException implements Exception {
  final String message;
  const InsufficientStorageException([
    this.message =
        'Not enough storage space to download this file. Please free up space and try again.',
  ]);
  @override
  String toString() => 'InsufficientStorageException: $message';
}

class InvalidPathException implements Exception {
  final String message;
  const InvalidPathException(this.message);
  @override
  String toString() => 'InvalidPathException: $message';
}

class DownloadIntegrityException implements Exception {
  final String message;
  const DownloadIntegrityException(this.message);
  @override
  String toString() => 'DownloadIntegrityException: $message';
}

class UrlExpiredException implements Exception {
  final String message;
  final bool refreshAllMirrors;
  const UrlExpiredException(this.message, {this.refreshAllMirrors = false});
  @override
  String toString() => 'UrlExpiredException: $message';
}

class TorrentEnginePauseException implements Exception {
  final String message;
  final String url;
  const TorrentEnginePauseException(this.message, {required this.url});
  @override
  String toString() => 'TorrentEnginePauseException: $message';
}

/// Raised when a server does not support byte-range requests.
class RangeUnsupportedException implements Exception {}

/// Raised when the remote file changed between resume attempts.
class FileChangedOnServerException implements Exception {
  @override
  String toString() => 'File changed on server. Restart required.';
}
