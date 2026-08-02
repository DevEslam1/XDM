import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

/// High-level family of an error, used to decide user messaging, retry policy
/// and severity.
enum ErrorFamily {
  network,
  server,
  auth,
  disk,
  integrity,
  cancelled,
  timeout,
  parse,
  unknown,
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

  const ErrorClassification({
    required this.family,
    this.httpStatus,
    required this.message,
    this.retryable = false,
    this.severe = false,
  });

  bool get isServerError => family == ErrorFamily.server;
  bool get isNetworkError => family == ErrorFamily.network;
}

/// Maps raw errors (Dio, socket, file-system, timeout, …) onto a stable,
/// user-facing taxonomy.
class ErrorTaxonomy {
  ErrorTaxonomy._();

  static const ErrorClassification _unknown = ErrorClassification(
    family: ErrorFamily.unknown,
    message: 'Unexpected error',
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
      );
    }

    if (status != null) {
      if (status == 401 || status == 403) {
        return ErrorClassification(
          family: ErrorFamily.auth,
          httpStatus: status,
          message: 'Authentication failed (HTTP $status)',
          severe: true,
        );
      }
      if (status >= 500) {
        return ErrorClassification(
          family: ErrorFamily.server,
          httpStatus: status,
          message: 'Server error (HTTP $status)',
          retryable: true,
        );
      }
      if (status == 408 || status == 429) {
        return ErrorClassification(
          family: ErrorFamily.server,
          httpStatus: status,
          message: 'Temporary server error (HTTP $status)',
          retryable: true,
        );
      }
      return ErrorClassification(
        family: ErrorFamily.unknown,
        httpStatus: status,
        message: 'Request failed (HTTP $status)',
      );
    }

    if (error is TimeoutException) {
      return const ErrorClassification(
        family: ErrorFamily.timeout,
        message: 'Connection timed out',
        retryable: true,
      );
    }

    if (error is SocketException) {
      return const ErrorClassification(
        family: ErrorFamily.network,
        message: 'Network error',
        retryable: true,
      );
    }

    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          return const ErrorClassification(
            family: ErrorFamily.timeout,
            message: 'Connection timed out',
            retryable: true,
          );
        case DioExceptionType.connectionError:
          return const ErrorClassification(
            family: ErrorFamily.network,
            message: 'Network error',
            retryable: true,
          );
        default:
          break;
      }
    }

    if (error is FileSystemException) {
      final isFull = _isDiskFull(error);
      return ErrorClassification(
        family: ErrorFamily.disk,
        message: isFull ? 'Storage full' : 'File system error',
        severe: true,
      );
    }

    final typeName = error.runtimeType.toString();
    final stringRep = error.toString();
    if (typeName == 'DownloadIntegrityException' ||
        stringRep.startsWith('DownloadIntegrityException')) {
      return const ErrorClassification(
        family: ErrorFamily.integrity,
        message: 'File integrity check failed',
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
