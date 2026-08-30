import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/retry_engine.dart';
import 'package:dmx/core/services/error_taxonomy.dart';

void main() {
  group('RetryEngine', () {
    test('shouldRetry respects maxRetries', () {
      final engine = RetryEngine(maxRetries: 3);
      final networkError = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionTimeout,
      );

      expect(engine.shouldRetry(networkError, 0), isTrue);
      expect(engine.shouldRetry(networkError, 2), isTrue);
      expect(engine.shouldRetry(networkError, 3), isFalse);
    });

    test('shouldRetry checks error family against retryableFamilies', () {
      final engine = RetryEngine(
        maxRetries: 3,
        retryableFamilies: {ErrorFamily.network, ErrorFamily.timeout},
      );

      final connectionError = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionError,
      );

      final badResponseError = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/'),
          statusCode: 400,
        ),
      );

      expect(engine.shouldRetry(connectionError, 0), isTrue);
      expect(engine.shouldRetry(badResponseError, 0), isFalse);
    });

    test('getDelayForAttempt increases backoff with attempt count', () {
      final engine = RetryEngine(
        baseDelay: const Duration(milliseconds: 100),
        backoffMultiplier: 2.0,
        maxDelay: const Duration(seconds: 10),
      );

      final delay0 = engine.getDelayForAttempt(0);
      final delay2 = engine.getDelayForAttempt(2);

      expect(delay0.inMilliseconds, greaterThanOrEqualTo(100));
      expect(delay2.inMilliseconds, greaterThan(delay0.inMilliseconds));
    });

    test('execute throws RetryCancelledException when cancelToken is cancelled', () async {
      final engine = RetryEngine(maxRetries: 3);
      final token = CancelToken();
      token.cancel('user cancelled');

      expect(
        () => engine.execute(() async => 'result', cancelToken: token),
        throwsA(isA<RetryCancelledException>()),
      );
    });
  });
}
