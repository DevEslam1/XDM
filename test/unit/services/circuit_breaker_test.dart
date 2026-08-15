import 'package:dmx/core/services/circuit_breaker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CircuitBreaker Unit Tests', () {
    test('CircuitBreaker starts closed and allows requests', () {
      final cb = CircuitBreaker(failureThreshold: 3);
      expect(cb.isClosed, isTrue);
      expect(cb.isOpen, isFalse);
      expect(cb.allowRequest(), isTrue);
    });

    test('CircuitBreaker trips to open after failureThreshold failures', () {
      final DateTime fakeTime = DateTime.now();
      final cb = CircuitBreaker(failureThreshold: 3, clock: () => fakeTime);

      cb.recordFailure();
      expect(cb.isClosed, isTrue);
      cb.recordFailure();
      expect(cb.isClosed, isTrue);
      cb.recordFailure();

      expect(cb.isOpen, isTrue);
      expect(cb.allowRequest(), isFalse);
    });

    test('CircuitBreaker transitions to halfOpen after openTimeout', () {
      DateTime fakeTime = DateTime(2026, 1, 1, 12, 0, 0);
      final cb = CircuitBreaker(
        failureThreshold: 2,
        openTimeout: const Duration(seconds: 10),
        halfOpenTimeout: const Duration(seconds: 2),
        clock: () => fakeTime,
      );

      cb.recordFailure();
      cb.recordFailure();
      expect(cb.isOpen, isTrue);

      // Advance time by 10s
      fakeTime = fakeTime.add(const Duration(seconds: 11));
      expect(cb.allowRequest(), isFalse); // Transitions to halfOpen
      expect(cb.state, equals(CircuitBreakerState.halfOpen));

      // Advance time by halfOpenTimeout
      fakeTime = fakeTime.add(const Duration(seconds: 3));
      expect(cb.allowRequest(), isTrue);

      // Success re-arms breaker to closed
      cb.recordSuccess();
      expect(cb.isClosed, isTrue);
    });

    test('CircuitBreaker reset forces closed state', () {
      final cb = CircuitBreaker(failureThreshold: 1);
      cb.recordFailure();
      expect(cb.isOpen, isTrue);

      cb.reset();
      expect(cb.isClosed, isTrue);
      expect(cb.consecutiveFailures, equals(0));
    });

    test('CircuitBreaker.guard executes operation when closed and records success', () async {
      final cb = CircuitBreaker(failureThreshold: 2);
      final val = await cb.guard(() async => 42);
      expect(val, equals(42));
      expect(cb.isClosed, isTrue);
    });

    test('CircuitBreaker.guard throws CircuitOpenException when open', () async {
      final cb = CircuitBreaker(failureThreshold: 1);
      cb.recordFailure();
      expect(cb.isOpen, isTrue);

      expect(
        () => cb.guard(() async => 'hello', service: 'TestService'),
        throwsA(isA<CircuitOpenException>()),
      );
    });
  });
}
