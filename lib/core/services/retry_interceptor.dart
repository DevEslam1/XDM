import 'dart:math' as math;
import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

class ProfessionalRetryInterceptor extends Interceptor {
  final Dio _dio;

  /// Retries reuse [_dio] so proxy, SSL, and header configuration are
  /// preserved across attempts (a bare `Dio()` would bypass user settings).
  ProfessionalRetryInterceptor(this._dio);

  static final _log = Logger('RetryInterceptor');
  static const int maxRetries = 5;
  static const int baseDelayMs = 1000;
  static const int maxDelayMs = 30000;
  static const int staleEntryTtlMs = 120000;
  static final _rng = math.Random();

  final Map<int, int> _retryCounts = {};
  final Map<int, int> _retryTimestamps = {};

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final key = identityHashCode(err.requestOptions);

    // Break infinite retry loops: if the request already carries a retry
    // count at the max, stop retrying regardless of the in-memory map state.
    final existingRetryCount =
        int.tryParse(
          err.requestOptions.headers['X-Retry-Count']?.toString() ?? '0',
        ) ??
        0;
    if (existingRetryCount >= maxRetries) {
      _removeEntry(key);
      handler.next(err);
      return;
    }

    _cleanupStaleEntries();

    if (!_isTransient(err)) {
      _log.fine(
        'Permanent error (${err.type}, '
        '${err.response?.statusCode}), not retrying: '
        '${err.requestOptions.uri}',
      );
      _removeEntry(key);
      handler.next(err);
      return;
    }

    final count = _retryCounts[key] ?? 0;
    if (count >= maxRetries) {
      _log.warning(
        'Max retries ($maxRetries) exhausted for '
        '${err.requestOptions.uri}',
      );
      _removeEntry(key);
      handler.next(err);
      return;
    }

    _retryCounts[key] = count + 1;
    _retryTimestamps[key] = DateTime.now().millisecondsSinceEpoch;

    final delayMs = _computeDelay(err, count);

    _log.info(
      'Retry ${count + 1}/$maxRetries for '
      '${err.requestOptions.uri} in ${delayMs}ms '
      '(error: ${err.type}, status: ${err.response?.statusCode})',
    );

    await Future.delayed(Duration(milliseconds: delayMs));

    try {
      // Retry using the SAME Dio instance to preserve proxy, SSL, and header config.
      // Add a retry-count header to allow servers / downstream interceptors to
      // detect and break infinite retry loops.
      err.requestOptions.headers['X-Retry-Count'] = (count + 1).toString();
      final response = await _dio.fetch(err.requestOptions);
      _removeEntry(key);
      handler.resolve(response);
    } catch (retryErr) {
      _log.fine('Retry attempt failed: $retryErr');
      handler.next(err);
    }
  }

  int _computeDelay(DioException err, int attemptCount) {
    final retryAfter = err.response?.headers.value('retry-after');
    if (retryAfter != null) {
      final seconds = int.tryParse(retryAfter);
      if (seconds != null && seconds > 0) {
        return (seconds * 1000).clamp(baseDelayMs, maxDelayMs);
      }
    }

    final exponential = baseDelayMs * math.pow(2, attemptCount);
    final capped = math.min(exponential, maxDelayMs).toDouble();
    final jitter = capped * 0.25 * (_rng.nextDouble() * 2 - 1);
    return (capped + jitter).round().clamp(baseDelayMs, maxDelayMs);
  }

  bool _isTransient(DioException err) {
    switch (err.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.badResponse:
        final code = err.response?.statusCode ?? 0;
        return code == 429 || code >= 500;
      case DioExceptionType.cancel:
        return false;
      default:
        return false;
    }
  }

  void _cleanupStaleEntries() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final staleKeys = <int>[];
    for (final entry in _retryTimestamps.entries) {
      if (now - entry.value > staleEntryTtlMs) {
        staleKeys.add(entry.key);
      }
    }
    for (final key in staleKeys) {
      _removeEntry(key);
    }
  }

  void _removeEntry(int key) {
    _retryCounts.remove(key);
    _retryTimestamps.remove(key);
  }
}
