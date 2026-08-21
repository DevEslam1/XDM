import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../domain/models/error_family.dart';
import 'download_engine.dart';
import 'positional_file_writer.dart';
import 'xdm_backend_exceptions.dart';

export '../domain/models/error_family.dart';

/// The concrete recovery path the app should take for a classified error.
/// Every user-facing failure must map to exactly one recovery action.
enum RecoveryAction {
  /// Retry the same URL/operation once (e.g. a 5xx server hiccup).
  retrySame,

  /// Retry with exponential backoff (network / timeout).
  retryWithDelay,

  /// The signed/stream URL expired — a fresh URL must be resolved first.
  refreshUrl,

  /// Delete temp files and restart the transfer from byte zero.
  restartDownload,

  /// The user must fix a setting (free disk space, grant permission).
  showSettings,

  /// Unrecoverable without support/diagnostics.
  contactSupport,

  /// Non-critical — log only, no user action required.
  ignore,
}

/// Classification result for a single error.
class ErrorClassification {
  final ErrorFamily family;

  /// HTTP status code when the error surfaced one (5xx / 4xx etc.).
  final int? httpStatus;

  /// User-facing description (safe to display).
  final String message;

  /// Whether a retry is likely to succeed.
  final bool retryable;

  /// Whether the failure is severe enough to surface prominently (auth/disk).
  final bool severe;

  /// The concrete recovery path derived from the family and status.
  final RecoveryAction recoveryAction;

  const ErrorClassification({
    required this.family,
    this.httpStatus,
    required this.message,
    this.retryable = false,
    this.severe = false,
    this.recoveryAction = RecoveryAction.ignore,
  });

  bool get isServerError => family == ErrorFamily.server;
  bool get isNetworkError => family == ErrorFamily.network;
}

/// Maps an [ErrorFamily] (+ optional HTTP status) to a recovery action.
/// Kept as a standalone function so the taxonomy stays data-driven and easy
/// to test.
RecoveryAction recoveryActionFor(
  ErrorFamily family, {
  int? httpStatus,
}) {
  switch (family) {
    case ErrorFamily.network:
      return RecoveryAction.retryWithDelay;
    case ErrorFamily.timeout:
      return RecoveryAction.retryWithDelay;
    case ErrorFamily.auth:
      // 410 Gone is usually a rotated/expired stream URL → refresh it.
      if (httpStatus == 410) return RecoveryAction.refreshUrl;
      return RecoveryAction.showSettings;
    case ErrorFamily.disk:
      return RecoveryAction.showSettings;
    case ErrorFamily.integrity:
      return RecoveryAction.restartDownload;
    case ErrorFamily.server:
      // 429 is a hard rate limit — longer backoff; 5xx is worth a direct retry.
      if (httpStatus == 429) return RecoveryAction.retryWithDelay;
      if (httpStatus != null && httpStatus >= 500) {
        return RecoveryAction.retrySame;
      }
      return RecoveryAction.retryWithDelay;
    case ErrorFamily.cancelled:
      return RecoveryAction.ignore;
    case ErrorFamily.parse:
      return RecoveryAction.restartDownload;
    case ErrorFamily.unknown:
      return RecoveryAction.contactSupport;
  }
}

/// Maps raw errors (Dio, socket, file-system, timeout, …) onto a stable,
/// user-facing taxonomy.
class ErrorTaxonomy {
  ErrorTaxonomy._();

  static const ErrorClassification _unknown = ErrorClassification(
    family: ErrorFamily.unknown,
    message: 'Unexpected error',
    recoveryAction: RecoveryAction.contactSupport,
  );

  static ErrorClassification classify(
    Object error, {
    String? message,
    int? httpStatus,
  }) {
    final status = httpStatus ?? _statusOf(error);

    // Cancellation is never retryable.
    if (error is DioException && error.type == DioExceptionType.cancel) {
      return const ErrorClassification(
        family: ErrorFamily.cancelled,
        message: 'Download cancelled',
        recoveryAction: RecoveryAction.ignore,
      );
    }

    if (error is InsufficientStorageException) {
      return const ErrorClassification(
        family: ErrorFamily.disk,
        message: 'Not enough storage space',
        severe: true,
        recoveryAction: RecoveryAction.showSettings,
      );
    }

    if (error is PositionalFileWriterException) {
      final msg = error.message.toLowerCase();
      final isSpace = msg.contains('enospc') ||
          msg.contains('space') ||
          msg.contains('disk');
      return ErrorClassification(
        family: ErrorFamily.disk,
        message: isSpace
            ? 'Not enough storage space'
            : 'Disk write error. Check storage permissions and free space.',
        severe: true,
        recoveryAction: RecoveryAction.showSettings,
      );
    }

    if (error is InvalidPathException) {
      return const ErrorClassification(
        family: ErrorFamily.disk,
        message: 'Invalid storage path',
        severe: true,
        recoveryAction: RecoveryAction.showSettings,
      );
    }

    if (error is DownloadIntegrityException) {
      return const ErrorClassification(
        family: ErrorFamily.integrity,
        message: 'File integrity verification failed',
        recoveryAction: RecoveryAction.restartDownload,
      );
    }

    if (error is IsolateSpawnTimeoutException) {
      return const ErrorClassification(
        family: ErrorFamily.timeout,
        message: 'Download engine failed to initialize',
        retryable: true,
        recoveryAction: RecoveryAction.retryWithDelay,
      );
    }

    if (error is UrlExpiredException) {
      return const ErrorClassification(
        family: ErrorFamily.auth,
        message: 'Download URL has expired',
        severe: true,
        recoveryAction: RecoveryAction.refreshUrl,
      );
    }

    if (error is TorrentEnginePauseException) {
      return const ErrorClassification(
        family: ErrorFamily.network,
        message: 'Torrent engine unavailable',
        retryable: true,
        recoveryAction: RecoveryAction.retryWithDelay,
      );
    }

    if (error is XdmBackendTimeoutException) {
      return const ErrorClassification(
        family: ErrorFamily.timeout,
        message: 'Backend request timed out',
        retryable: true,
        recoveryAction: RecoveryAction.retryWithDelay,
      );
    }

    if (error is BackendNetworkException) {
      return const ErrorClassification(
        family: ErrorFamily.network,
        message: 'Cannot reach download backend',
        retryable: true,
        recoveryAction: RecoveryAction.retryWithDelay,
      );
    }

    if (error is BackendRateLimitException) {
      return const ErrorClassification(
        family: ErrorFamily.server,
        message: 'Rate limit reached. Try again later.',
        retryable: true,
        recoveryAction: RecoveryAction.retryWithDelay,
      );
    }

    if (error is BackendUnauthorizedException) {
      return const ErrorClassification(
        family: ErrorFamily.auth,
        message: 'Backend authentication failed',
        severe: true,
        recoveryAction: RecoveryAction.showSettings,
      );
    }

    if (error is BackendException) {
      return const ErrorClassification(
        family: ErrorFamily.server,
        message: 'Backend request failed',
        retryable: true,
        recoveryAction: RecoveryAction.retryWithDelay,
      );
    }

    if (status != null) {
      if (status == 401 || status == 403 || status == 410) {
        return ErrorClassification(
          family: ErrorFamily.auth,
          httpStatus: status,
          message: status == 410
              ? 'Download URL expired (HTTP 410)'
              : 'Authentication failed (HTTP $status)',
          severe: true,
          recoveryAction:
              recoveryActionFor(ErrorFamily.auth, httpStatus: status),
        );
      }
      if (status >= 500) {
        return ErrorClassification(
          family: ErrorFamily.server,
          httpStatus: status,
          message: 'Server error (HTTP $status)',
          retryable: true,
          recoveryAction:
              recoveryActionFor(ErrorFamily.server, httpStatus: status),
        );
      }
      if (status == 408 || status == 429) {
        return ErrorClassification(
          family: ErrorFamily.server,
          httpStatus: status,
          message: status == 429
              ? 'Too many requests (HTTP 429)'
              : 'Temporary server error (HTTP $status)',
          retryable: true,
          recoveryAction:
              recoveryActionFor(ErrorFamily.server, httpStatus: status),
        );
      }
      return ErrorClassification(
        family: ErrorFamily.unknown,
        httpStatus: status,
        message: 'Request failed (HTTP $status)',
        recoveryAction: RecoveryAction.contactSupport,
      );
    }

    if (error is TimeoutException) {
      return const ErrorClassification(
        family: ErrorFamily.timeout,
        message: 'Connection timed out',
        retryable: true,
        recoveryAction: RecoveryAction.retryWithDelay,
      );
    }

    if (error is SocketException) {
      return const ErrorClassification(
        family: ErrorFamily.network,
        message: 'Network error',
        retryable: true,
        recoveryAction: RecoveryAction.retryWithDelay,
      );
    }

    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.badCertificate:
          return const ErrorClassification(
            family: ErrorFamily.auth,
            message:
                'SSL certificate verification failed (Untrusted or Expired)',
            severe: true,
            recoveryAction: RecoveryAction.refreshUrl,
          );
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          return const ErrorClassification(
            family: ErrorFamily.timeout,
            message: 'Connection timed out',
            retryable: true,
            recoveryAction: RecoveryAction.retryWithDelay,
          );
        case DioExceptionType.connectionError:
          final underlying = error.error;
          final errStr = error.toString().toLowerCase();
          final underlyingStr = underlying?.toString().toLowerCase() ?? '';
          
          if (underlying is HandshakeException ||
              underlying is TlsException ||
              underlying is CertificateException ||
              errStr.contains('certificate_verify_failed') ||
              errStr.contains('handshakeexception') ||
              errStr.contains('tlsexception') ||
              underlyingStr.contains('certificate') ||
              underlyingStr.contains('handshake') ||
              underlyingStr.contains('tls')) {
            return const ErrorClassification(
              family: ErrorFamily.auth,
              message: 'Secure connection failed (SSL/TLS Certificate Error)',
              severe: true,
              recoveryAction: RecoveryAction.refreshUrl,
            );
          }
          if (underlying is SocketException ||
              underlying is HttpException ||
              underlying is OSError ||
              errStr.contains('socketexception') ||
              errStr.contains('oserror') ||
              errStr.contains('connection refused') ||
              errStr.contains('connection reset') ||
              errStr.contains('network is unreachable')) {
            return const ErrorClassification(
              family: ErrorFamily.network,
              message: 'Network connection error',
              retryable: true,
              recoveryAction: RecoveryAction.retryWithDelay,
            );
          }
          return const ErrorClassification(
            family: ErrorFamily.network,
            message: 'Network error',
            retryable: true,
            recoveryAction: RecoveryAction.retryWithDelay,
          );
        default:
          break;
      }
    }

    if (error is HandshakeException ||
        error is TlsException ||
        error is CertificateException) {
      return const ErrorClassification(
        family: ErrorFamily.auth,
        message: 'Secure connection failed (SSL/TLS Certificate Error)',
        severe: true,
        recoveryAction: RecoveryAction.refreshUrl,
      );
    }

    if (error is FileSystemException) {
      final isFull = _isDiskFull(error);
      return ErrorClassification(
        family: ErrorFamily.disk,
        message: isFull ? 'Storage full' : 'File system error',
        severe: true,
        recoveryAction: RecoveryAction.showSettings,
      );
    }

    final typeName = error.runtimeType.toString();
    final stringRep = error.toString();
    if (typeName == 'DownloadIntegrityException' ||
        stringRep.startsWith('DownloadIntegrityException')) {
      return const ErrorClassification(
        family: ErrorFamily.integrity,
        message: 'File integrity check failed',
        recoveryAction: RecoveryAction.restartDownload,
      );
    }

    // _FileChangedOnServerException is declared as a private top-level class
    // in the isolate pool part-file, so match it by runtime type name.
    if (typeName == '_FileChangedOnServerException' ||
        stringRep.contains('_FileChangedOnServerException') ||
        stringRep.toLowerCase().contains('file changed on server')) {
      return const ErrorClassification(
        family: ErrorFamily.integrity,
        message: 'File changed on server',
        recoveryAction: RecoveryAction.restartDownload,
      );
    }

    final lowerRep = stringRep.toLowerCase();
    if (lowerRep.contains('network') ||
        lowerRep.contains('connection reset') ||
        lowerRep.contains('socket')) {
      return const ErrorClassification(
        family: ErrorFamily.network,
        message: 'Network error',
        retryable: true,
        recoveryAction: RecoveryAction.retryWithDelay,
      );
    }

    if (lowerRep.contains('disk') ||
        lowerRep.contains('storage') ||
        lowerRep.contains('no space') ||
        lowerRep.contains('space insufficient')) {
      return const ErrorClassification(
        family: ErrorFamily.disk,
        message: 'Storage full',
        severe: true,
        recoveryAction: RecoveryAction.showSettings,
      );
    }

    return _unknown;
  }

  static int? _statusOf(Object error) {
    if (error is DioException) {
      return error.response?.statusCode;
    }
    return null;
  }

  static bool _isDiskFull(FileSystemException e) {
    final osError = e.osError;
    if (osError != null) {
      final code = osError.errorCode;
      if (code == 28 || code == 112) return true;
    }
    final message = e.message.toLowerCase();
    return message.contains('no space left') ||
        message.contains('not enough space') ||
        message.contains('disk full');
  }
}
