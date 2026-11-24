import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/error_taxonomy.dart';
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

    test(
        'getDelayForAttempt increases with attempt count and clamps to maxDelay',
        () {
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

    test('shouldRetry honours a custom retryable family set', () {
      final engine = RetryEngine(
        maxRetries: 3,
        retryableFamilies: const {ErrorFamily.server},
      );
      expect(engine.shouldRetry(const SocketException('x'), 0), isFalse);
    });

    test('getDelayForAttempt clamps a negative attempt to zero', () {
      final engine = RetryEngine(
        baseDelay: const Duration(milliseconds: 100),
        maxDelay: const Duration(seconds: 1),
      );
      final delay = engine.getDelayForAttempt(-5);
      expect(delay.inMilliseconds, greaterThanOrEqualTo(100));
      expect(delay.inMilliseconds, lessThanOrEqualTo(600));
    });

    test('throws RetryCancelledException when the token is pre-cancelled',
        () async {
      final engine = RetryEngine();
      final token = CancelToken()..cancel();

      await expectLater(
        engine.execute(() async => 1, cancelToken: token),
        throwsA(isA<RetryCancelledException>()),
      );
    });

    test('onRetry receives the attempt number and delay', () async {
      final engine = RetryEngine(
        maxRetries: 2,
        baseDelay: const Duration(milliseconds: 1),
      );
      var attempts = 0;
      final seen = <int>[];

      final result = await engine.execute(
        () async {
          attempts++;
          if (attempts == 1) throw const SocketException('transient');
          return 'ok';
        },
        onRetry: (e, attempt, delay) => seen.add(attempt),
      );

      expect(result, 'ok');
      expect(seen, [1]);
    });

    test('onFinalFailure runs for non-retryable failures', () async {
      final engine = RetryEngine(
        maxRetries: 3,
        retryableFamilies: const {ErrorFamily.server},
      );
      Object? captured;

      await expectLater(
        engine.execute<String>(
          () async => throw const SocketException('permanent'),
          onFinalFailure: (e) => captured = e,
        ),
        throwsA(isA<SocketException>()),
      );
      expect(captured, isA<SocketException>());
    });

    test('cancelling during backoff aborts with RetryCancelledException',
        () async {
      final engine = RetryEngine(
        maxRetries: 5,
        baseDelay: const Duration(seconds: 5),
      );
      final token = CancelToken();

      await expectLater(
        engine.execute<String>(
          () async => throw const SocketException('x'),
          cancelToken: token,
          onRetry: (e, attempt, delay) => token.cancel(),
        ),
        throwsA(isA<RetryCancelledException>()),
      );
    });

    test('cancelling mid-delay surfaces a cancellation DioException', () async {
      final engine = RetryEngine(
        maxRetries: 5,
        baseDelay: const Duration(milliseconds: 200),
      );
      final token = CancelToken();

      await expectLater(
        engine.execute<String>(
          () async => throw const SocketException('x'),
          cancelToken: token,
          onRetry: (e, attempt, delay) {
            Future<void>.delayed(
              const Duration(milliseconds: 10),
              token.cancel,
            );
          },
        ),
        throwsA(isA<DioException>()),
      );
    });

    test('delay with an inactive cancel token completes normally', () async {
      final engine = RetryEngine(
        maxRetries: 2,
        baseDelay: const Duration(milliseconds: 5),
      );
      final token = CancelToken();
      var attempts = 0;

      final result = await engine.execute(
        () async {
          attempts++;
          if (attempts == 1) throw const SocketException('transient');
          return 'ok';
        },
        cancelToken: token,
      );

      expect(result, 'ok');
      expect(attempts, 2);
    });

    test('RetryCancelledException renders a readable message', () {
      expect(
        const RetryCancelledException('stop').toString(),
        contains('stop'),
      );
    });
  });
}
