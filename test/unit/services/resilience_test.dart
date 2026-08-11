import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/circuit_breaker.dart';
import 'package:dmx/core/services/diagnostic_service.dart';
import 'package:dmx/core/services/error_taxonomy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ErrorTaxonomy', () {
    test('classifies 5xx as retryable server error', () {
      final result = ErrorTaxonomy.classify(
        DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.badResponse,
          response: Response(
            requestOptions: RequestOptions(path: '/x'),
            statusCode: 503,
          ),
        ),
      );
      expect(result.family, ErrorFamily.server);
      expect(result.retryable, isTrue);
      expect(result.httpStatus, 503);
    });

    test('classifies 401 as severe auth error', () {
      final result = ErrorTaxonomy.classify(
        DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.badResponse,
          response: Response(
            requestOptions: RequestOptions(path: '/x'),
            statusCode: 401,
          ),
        ),
      );
      expect(result.family, ErrorFamily.auth);
      expect(result.severe, isTrue);
      expect(result.retryable, isFalse);
    });

    test('classifies cancellation as non-retryable', () {
      final result = ErrorTaxonomy.classify(
        DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.cancel,
        ),
      );
      expect(result.family, ErrorFamily.cancelled);
      expect(result.retryable, isFalse);
    });

    test('classifies timeout and socket errors as retryable', () {
      final timeout = ErrorTaxonomy.classify(
        DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.connectionTimeout,
        ),
      );
      expect(timeout.family, ErrorFamily.timeout);
      expect(timeout.retryable, isTrue);

      final socket = ErrorTaxonomy.classify(const SocketException('refused'));
      expect(socket.family, ErrorFamily.network);
      expect(socket.retryable, isTrue);
    });

    test('classifies disk-full file errors as severe disk', () {
      final result = ErrorTaxonomy.classify(
        const FileSystemException('No space left on device'),
      );
      expect(result.family, ErrorFamily.disk);
      expect(result.severe, isTrue);
    });
  });

  group('CircuitBreaker', () {
    var now = DateTime(2026, 1, 1);
    late CircuitBreaker breaker;

    setUp(() {
      now = DateTime(2026, 1, 1);
      breaker = CircuitBreaker(
        failureThreshold: 3,
        openTimeout: const Duration(seconds: 30),
        halfOpenTimeout: const Duration(seconds: 5),
        clock: () => now,
      );
    });

    test('starts closed and allows requests', () {
      expect(breaker.state, CircuitBreakerState.closed);
      expect(breaker.allowRequest(), isTrue);
    });

    test('opens after threshold failures and rejects while open', () {
      expect(breaker.allowRequest(), isTrue);
      breaker.recordFailure();
      breaker.recordFailure();
      breaker.recordFailure();
      expect(breaker.state, CircuitBreakerState.open);
      expect(breaker.allowRequest(), isFalse);
    });

    test('half-opens after openTimeout and allows a probe', () {
      breaker.recordFailure();
      breaker.recordFailure();
      breaker.recordFailure();
      expect(breaker.state, CircuitBreakerState.open);

      now = now.add(const Duration(seconds: 31));
      // First call while open flips state to halfOpen and returns false.
      expect(breaker.allowRequest(), isFalse);
      expect(breaker.state, CircuitBreakerState.halfOpen);

      // Second call in halfOpen state allows the probe.
      expect(breaker.allowRequest(), isTrue);

      // Third call while probe is in flight is rejected.
      expect(breaker.allowRequest(), isFalse);

      // After halfOpenTimeout elapses, new probe is allowed.
      now = now.add(const Duration(seconds: 6));
      expect(breaker.allowRequest(), isTrue);
    });

    test('success in half-open re-arms the breaker', () {
      breaker.recordFailure();
      breaker.recordFailure();
      breaker.recordFailure();
      now = now.add(const Duration(seconds: 31));
      breaker.allowRequest();
      now = now.add(const Duration(seconds: 6));
      breaker.allowRequest();
      breaker.recordSuccess();
      expect(breaker.state, CircuitBreakerState.closed);
      expect(breaker.allowRequest(), isTrue);
    });

    test('failure in half-open re-opens the breaker', () {
      breaker.recordFailure();
      breaker.recordFailure();
      breaker.recordFailure();
      now = now.add(const Duration(seconds: 31));
      breaker.allowRequest();
      now = now.add(const Duration(seconds: 6));
      breaker.allowRequest();
      breaker.recordFailure();
      expect(breaker.state, CircuitBreakerState.open);
      expect(breaker.allowRequest(), isFalse);
    });
  });

  group('DiagnosticService', () {
    late DiagnosticService service;

    setUp(() {
      service = DiagnosticService();
      service.clear();
    });

    test('records entries and formats snapshot', () {
      service.record('download', 'Server error', error: Exception('boom'));
      expect(service.entries.length, 1);
      expect(service.snapshot(), contains('download'));
      expect(service.snapshot(), contains('Server error'));
    });

    test('snapshot keeps entries in order', () {
      service.record('a', 'first');
      service.record('b', 'second');
      final lines = service.snapshot().split('\n');
      expect(lines.length, 2);
      expect(lines[0], contains('first'));
      expect(lines[1], contains('second'));
    });

    test('clear removes all entries', () {
      service.record('a', 'x');
      service.clear();
      expect(service.entries, isEmpty);
    });
  });
}
