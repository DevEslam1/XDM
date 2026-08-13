import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/circuit_breaker.dart';

void main() {
  late DateTime fakeTime;

  setUp(() {
    fakeTime = DateTime(2026, 1, 1, 12, 0, 0);
  });

  CircuitBreaker createBreaker({
    int failureThreshold = 3,
    Duration openTimeout = const Duration(seconds: 30),
  }) {
    return CircuitBreaker(
      failureThreshold: failureThreshold,
      openTimeout: openTimeout,
      clock: () => fakeTime,
    );
  }

  group('CircuitBreaker', () {
    test('1. Starts in closed state', () {
      final breaker = createBreaker();
      expect(breaker.state, equals(CircuitBreakerState.closed));
      expect(breaker.isClosed, isTrue);
      expect(breaker.isOpen, isFalse);
    });

    test('2. Allows requests when closed', () {
      final breaker = createBreaker();
      expect(breaker.allowRequest(), isTrue);
    });

    test('3. Opens after failureThreshold consecutive failures', () {
      final breaker = createBreaker(failureThreshold: 3);
      breaker.recordFailure();
      fakeTime = fakeTime.add(const Duration(seconds: 1));
      breaker.recordFailure();
      fakeTime = fakeTime.add(const Duration(seconds: 1));
      expect(breaker.state, equals(CircuitBreakerState.closed));

      breaker.recordFailure();
      expect(breaker.state, equals(CircuitBreakerState.open));
      expect(breaker.isOpen, isTrue);
    });

    test('4. Rejects requests when open', () {
      final breaker = createBreaker(failureThreshold: 1);
      breaker.recordFailure();
      expect(breaker.isOpen, isTrue);
      expect(breaker.allowRequest(), isFalse);
    });

    test('5. Transitions to halfOpen after openTimeout', () {
      final breaker = createBreaker(
        failureThreshold: 1,
        openTimeout: const Duration(seconds: 10),
      );
      breaker.recordFailure();
      expect(breaker.isOpen, isTrue);

      fakeTime = fakeTime.add(const Duration(seconds: 11));
      // First call after timeout transitions to halfOpen and returns false (or probe check)
      breaker.allowRequest();
      expect(breaker.state, equals(CircuitBreakerState.halfOpen));
    });

    test('6. halfOpen allows exactly one probe request', () {
      final breaker = createBreaker(
        failureThreshold: 1,
        openTimeout: const Duration(seconds: 10),
      );
      breaker.recordFailure();

      fakeTime = fakeTime.add(const Duration(seconds: 11));
      breaker.allowRequest(); // transitions to halfOpen
      expect(breaker.state, equals(CircuitBreakerState.halfOpen));

      final probe1 = breaker.allowRequest();
      expect(probe1, isTrue);

      final probe2 = breaker.allowRequest();
      expect(probe2, isFalse);
    });

    test('7. Success in halfOpen → closed', () {
      final breaker = createBreaker(
        failureThreshold: 1,
        openTimeout: const Duration(seconds: 10),
      );
      breaker.recordFailure();
      fakeTime = fakeTime.add(const Duration(seconds: 11));
      breaker.allowRequest();
      expect(breaker.state, equals(CircuitBreakerState.halfOpen));

      breaker.recordSuccess();
      expect(breaker.state, equals(CircuitBreakerState.closed));
    });

    test('8. Failure in halfOpen → open', () {
      final breaker = createBreaker(
        failureThreshold: 1,
        openTimeout: const Duration(seconds: 10),
      );
      breaker.recordFailure();
      fakeTime = fakeTime.add(const Duration(seconds: 11));
      breaker.allowRequest();
      expect(breaker.state, equals(CircuitBreakerState.halfOpen));

      fakeTime = fakeTime.add(const Duration(seconds: 1));
      breaker.recordFailure();
      expect(breaker.state, equals(CircuitBreakerState.open));
    });

    test('9. reset() returns to closed', () {
      final breaker = createBreaker(failureThreshold: 1);
      breaker.recordFailure();
      expect(breaker.isOpen, isTrue);

      breaker.reset();
      expect(breaker.state, equals(CircuitBreakerState.closed));
      expect(breaker.consecutiveFailures, equals(0));
    });
  });
}
