import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/retry_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RetryEngine', () {
    test('succeeds on first attempt without retry', () async {
      final engine = RetryEngine(maxRetries: 3);
      var calls = 0;

      final result = await engine.execute(() async {
        calls++;
        return 'success';
      });

      expect(result, 'success');
      expect(calls, 1);
    });

    test('retries transient network error and succeeds', () async {
      final engine = RetryEngine(
        maxRetries: 3,
        baseDelay: const Duration(milliseconds: 10),
      );
      var attempts = 0;

      final result = await engine.execute(() async {
        attempts++;
        if (attempts == 1) {
          throw const SocketException('Temporary network failure');
        }
        return 'recovered';
      });

      expect(result, 'recovered');
      expect(attempts, 2);
    });

    test('rethrows immediately on DioExceptionType.cancel', () async {
      final engine = RetryEngine(maxRetries: 3);
      var attempts = 0;

      final cancelError = DioException(
        requestOptions: RequestOptions(path: 'https://example.com'),
        type: DioExceptionType.cancel,
      );

      expect(
        () => engine.execute(() async {
          attempts++;
          throw cancelError;
        }),
        throwsA(isA<DioException>()),
      );

      expect(attempts, 1); // Does not retry cancel
    });

    test('getDelayForAttempt increases with attempt count and clamps to maxDelay', () {
      final engine = RetryEngine(
        baseDelay: const Duration(seconds: 1),
        backoffMultiplier: 2.0,
        maxDelay: const Duration(seconds: 10),
      );

      final delay0 = engine.getDelayForAttempt(0);
      final delay1 = engine.getDelayForAttempt(1);
      final delay10 = engine.getDelayForAttempt(10);

      expect(delay0.inMilliseconds, greaterThanOrEqualTo(1000));
      expect(delay1.inMilliseconds, greaterThanOrEqualTo(2000));
      expect(delay10.inMilliseconds, lessThanOrEqualTo(10000));
    });

    test('shouldRetry returns false when maxRetries exceeded', () {
      final engine = RetryEngine(maxRetries: 2);
      const networkError = SocketException('Lost connection');

      expect(engine.shouldRetry(networkError, 0), true);
      expect(engine.shouldRetry(networkError, 1), true);
      expect(engine.shouldRetry(networkError, 2), false);
    });
  });
}
