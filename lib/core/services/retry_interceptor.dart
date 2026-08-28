import 'dart:math';

import 'package:dio/dio.dart';

/// Retries idempotent (GET/HEAD) requests on transient failures:
/// connection errors, 429/5xx. Exponential backoff with jitter, max 2
/// retries. Never retries a cancelled request.
///
/// Ranged GETs are retried too: a `bytes=N-` request is idempotent (the same
/// range yields the same bytes), and this interceptor only fires during the
/// connection/header phase — before any body bytes reach the consumer — so a
/// retry simply re-opens the stream at the requested offset. Mid-stream drops
/// (after bytes have been delivered) surface to the chunk executor, which owns
/// resume via its own Range continuation.
class ProfessionalRetryInterceptor extends Interceptor {
  ProfessionalRetryInterceptor(this._dio, {this.maxRetries = 2});

  final Dio _dio;
  final int maxRetries;
  static const _retryableStatus = {429, 500, 502, 503, 504};
  static const _retryableTypes = {
    DioExceptionType.connectionTimeout,
    DioExceptionType.connectionError,
  };
  static final Random _rng = Random();

  @override
  Future<void> onError(
      DioException err, ErrorInterceptorHandler handler) async {
    final opts = err.requestOptions;
    final method = opts.method.toUpperCase();
    final attempt = (opts.extra['__retry'] as int?) ?? 0;

    final isMethodSafe = method == 'GET' || method == 'HEAD';
    final isTransient = _retryableTypes.contains(err.type) ||
        (err.type == DioExceptionType.badResponse &&
            err.response != null &&
            _retryableStatus.contains(err.response!.statusCode));

    if (!isMethodSafe || !isTransient || attempt >= maxRetries) {
      handler.next(err);
      return;
    }

    final backoff = Duration(
      milliseconds: min(30000, (1 << attempt) * 800 + _rng.nextInt(400)),
    );
    await Future<void>.delayed(backoff);

    if (err.requestOptions.cancelToken?.isCancelled == true) {
      handler.next(err);
      return;
    }

    try {
      opts.extra['__retry'] = attempt + 1;
      final response = await _dio.fetch<dynamic>(opts);
      handler.resolve(response);
    } on DioException catch (e) {
      handler.next(e);
    }
  }
}
