import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/circuit_breaker.dart';

void main() {
  group('CircuitBreaker', () {
    test('starts in closed state and allows requests', () {
      final cb = CircuitBreaker(failureThreshold: 3);
      expect(cb.isClosed, true);
      expect(cb.isOpen, false);
      expect(cb.allowRequest(), true);
    });

    test('opens after consecutive failure threshold reached', () {
      final cb = CircuitBreaker(failureThreshold: 3);
      cb.recordFailure();
      cb.recordFailure();
      expect(cb.isClosed, true);

      cb.recordFailure(); // 3rd failure
      expect(cb.isOpen, true);
      expect(cb.isClosed, false);
      expect(cb.allowRequest(), false);
    });

    test('recordSuccess resets failure count in closed state', () {
      final cb = CircuitBreaker(failureThreshold: 3);
      cb.recordFailure();
      cb.recordFailure();
      expect(cb.consecutiveFailures, 2);

      cb.recordSuccess();
      expect(cb.consecutiveFailures, 0);
      expect(cb.isClosed, true);
    });

    test('guard throws CircuitOpenException when open', () async {
      final cb = CircuitBreaker(failureThreshold: 1);
      cb.recordFailure();

      expect(
        () => cb.guard(() async => 'result', service: 'TestService'),
        throwsA(isA<CircuitOpenException>()),
      );
    });

    test('guard executes operation and records success when closed', () async {
      final cb = CircuitBreaker(failureThreshold: 3);
      final result = await cb.guard(() async => 42, service: 'TestService');
      expect(result, 42);
      expect(cb.isClosed, true);
    });
  });
}
