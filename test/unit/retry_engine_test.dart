import 'package:dio/dio.dart';
import 'package:dmx/core/services/error_taxonomy.dart';
import 'package:dmx/core/services/retry_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RetryEngine', () {
    test('1. execute() returns result on first success', () async {
      final engine = RetryEngine(
        maxRetries: 3,
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
      );
      var calls = 0;
      final result = await engine.execute(() async {
        calls++;
        return 'success';
      });
      expect(result, equals('success'));
      expect(calls, equals(1));
    });

    test('2. execute() retries on retryable error', () async {
      final engine = RetryEngine(
        maxRetries: 3,
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
      );
      var attempts = 0;
      final result = await engine.execute(() async {
        attempts++;
        if (attempts < 3) {
          throw DioException(
            requestOptions: RequestOptions(path: '/'),
            response: Response(
              requestOptions: RequestOptions(path: '/'),
              statusCode: 500,
            ),
          );
        }
        return 'recovered';
      });
      expect(result, equals('recovered'));
      expect(attempts, equals(3));
    });

    test('3. execute() stops after maxRetries', () async {
      final engine = RetryEngine(
        maxRetries: 2,
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
      );
      expect(
        () => engine.execute(() async {
          throw DioException(
            requestOptions: RequestOptions(path: '/'),
            response: Response(
              requestOptions: RequestOptions(path: '/'),
              statusCode: 500,
            ),
          );
        }),
        throwsA(isA<DioException>()),
      );
    });

    test('4. execute() throws immediately on non-retryable error', () async {
      final engine = RetryEngine(
        maxRetries: 3,
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
      );
      var attempts = 0;
      expect(
        () => engine.execute(() async {
          attempts++;
          throw DioException(
            requestOptions: RequestOptions(path: '/'),
            response: Response(
              requestOptions: RequestOptions(path: '/'),
              statusCode: 403, // Auth error (non-retryable by default)
            ),
          );
        }),
        throwsA(isA<DioException>()),
      );
      expect(attempts, equals(1));
    });

    test('5. execute() respects CancelToken', () async {
      final engine = RetryEngine(
        maxRetries: 3,
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
      );
      final token = CancelToken();
      token.cancel();

      expect(
        () => engine.execute(
          () async => 'test',
          cancelToken: token,
        ),
        throwsA(isA<RetryCancelledException>()),
      );
    });

    test('6. getDelayForAttempt uses exponential backoff', () {
      final engine = RetryEngine(
        baseDelay: const Duration(seconds: 2),
        backoffMultiplier: 2.0,
        maxDelay: const Duration(seconds: 60),
      );
      final delay1 = engine.getDelayForAttempt(1);
      final delay2 = engine.getDelayForAttempt(2);

      expect(delay1.inSeconds, greaterThanOrEqualTo(3));
      expect(delay2.inSeconds, greaterThanOrEqualTo(7));
    });

    test('7. getDelayForAttempt caps at maxDelay', () {
      final engine = RetryEngine(
        baseDelay: const Duration(seconds: 10),
        backoffMultiplier: 2.0,
        maxDelay: const Duration(seconds: 30),
      );
      final delay = engine.getDelayForAttempt(10);
      expect(delay.inSeconds, lessThanOrEqualTo(31));
    });

    test('8. shouldRetry checks family against retryableFamilies', () {
      final engine = RetryEngine(
        maxRetries: 3,
        retryableFamilies: {ErrorFamily.network, ErrorFamily.timeout},
      );
      final netErr = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionTimeout,
      );
      expect(engine.shouldRetry(netErr, 0), isTrue);

      final authErr = DioException(
        requestOptions: RequestOptions(path: '/'),
        response: Response(
          requestOptions: RequestOptions(path: '/'),
          statusCode: 403,
        ),
      );
      expect(engine.shouldRetry(authErr, 0), isFalse);
    });
  });
}
