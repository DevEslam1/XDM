import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'error_taxonomy.dart';

/// A `DioException` thrown when a retry loop is aborted because the supplied
/// [CancelToken] was cancelled mid-sequence. Callers can catch this and treat
/// it as a plain cancellation (never retryable, never surfaced as an error).
class RetryCancelledException implements Exception {
  final String message;
  const RetryCancelledException([
    this.message = 'Operation cancelled during retry sequence.',
  ]);
  @override
  String toString() => 'RetryCancelledException: $message';
}

/// Centralized retry engine with exponential backoff + jitter.
///
/// Used wherever a transient failure (network, timeout, server 5xx/429) can
/// be safely retried: HTTP download attempts, backend API calls, mirror
/// failover and database writes.
///
/// Retry policy is driven by [ErrorTaxonomy] so it stays consistent with the
/// rest of the resilience infrastructure. A supplied [CancelToken] aborts the
/// loop immediately (no backoff sleeps) and rethrows a
/// [RetryCancelledException].
class RetryEngine {
  RetryEngine({
    this.maxRetries = 3,
    this.baseDelay = const Duration(seconds: 3),
    this.backoffMultiplier = 2.0,
    this.maxDelay = const Duration(seconds: 60),
    Set<ErrorFamily>? retryableFamilies,
    Random? random,
  })  : retryableFamilies = retryableFamilies ??
            const {
              ErrorFamily.network,
              ErrorFamily.timeout,
              ErrorFamily.server
            },
        _random = random ?? Random();

  final int maxRetries;
  final Duration baseDelay;
  final double backoffMultiplier;
  final Duration maxDelay;
  final Set<ErrorFamily> retryableFamilies;
  final Random _random;

  /// Exponential backoff with jitter (0–500 ms), clamped to [maxDelay].
  @visibleForTesting
  Duration getDelayForAttempt(int attempt) {
    final exponent = max(0, attempt);
    final rawMs = baseDelay.inMilliseconds * pow(backoffMultiplier, exponent);
    final jitterMs = _random.nextInt(501);
    final totalMs =
        (rawMs + jitterMs).round().clamp(0, maxDelay.inMilliseconds);
    return Duration(milliseconds: totalMs);
  }

  /// Whether [error] should be retried on the given [attempt] (0-based).
  bool shouldRetry(Object error, int attempt) {
    if (attempt >= maxRetries) return false;
    final classification = ErrorTaxonomy.classify(error);
    return retryableFamilies.contains(classification.family);
  }

  /// Runs [operation], retrying transient failures up to [maxRetries] times.
  ///
  /// - Cancelled requests ([DioExceptionType.cancel]) rethrow immediately.
  /// - A cancelled [cancelToken] between attempts throws [RetryCancelledException].
  /// - Non-retryable errors propagate immediately through [onFinalFailure].
  Future<T> execute<T>(
    Future<T> Function() operation, {
    void Function(Object error, int attempt, Duration delay)? onRetry,
    void Function(Object error)? onFinalFailure,
    CancelToken? cancelToken,
  }) async {
    var attempt = 0;
    while (true) {
      if (cancelToken?.isCancelled == true) {
        throw const RetryCancelledException();
      }
      try {
        return await operation();
      } catch (e) {
        if (e is DioException && e.type == DioExceptionType.cancel) {
          rethrow;
        }
        if (!shouldRetry(e, attempt)) {
          onFinalFailure?.call(e);
          rethrow;
        }
        attempt++;
        final delay = getDelayForAttempt(attempt);
        onRetry?.call(e, attempt, delay);
        await _delayWithCancellation(delay, cancelToken);
      }
    }
  }

  Future<void> _delayWithCancellation(
    Duration delay,
    CancelToken? cancelToken,
  ) async {
    if (cancelToken == null) {
      await Future<void>.delayed(delay);
      return;
    }
    if (cancelToken.isCancelled) {
      throw const RetryCancelledException();
    }
    final completer = Completer<void>();
    final timer = Timer(delay, () {
      if (!completer.isCompleted) completer.complete();
    });

    void onCancel(dynamic _) {
      timer.cancel();
      if (!completer.isCompleted) {
        completer.completeError(
          DioException(
            requestOptions: RequestOptions(path: ''),
            type: DioExceptionType.cancel,
            error: const RetryCancelledException(),
          ),
        );
      }
    }

    cancelToken.whenCancel.then(onCancel).catchError((_) {});

    try {
      await completer.future;
    } finally {
      timer.cancel();
    }
  }
}
