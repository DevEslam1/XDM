import 'package:dmx/core/services/circuit_breaker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DateTime fakeNow;

  setUp(() {
    fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
  });

  CircuitBreaker createBreaker({
    int failureThreshold = 3,
    Duration openTimeout = const Duration(seconds: 30),
  }) {
    return CircuitBreaker(
      failureThreshold: failureThreshold,
      openTimeout: openTimeout,
      clock: () => fakeNow,
    );
  }

  group('CircuitBreaker State Transitions', () {
    test('starts closed', () {
      final cb = createBreaker();
      expect(cb.state, equals(CircuitBreakerState.closed));
      expect(cb.isClosed, isTrue);
    });

    test('opens after reaching failureThreshold', () {
      final cb = createBreaker(failureThreshold: 3);

      cb.allowRequest();
      cb.recordFailure();
      expect(cb.isClosed, isTrue);

      cb.allowRequest();
      cb.recordFailure();
      expect(cb.isClosed, isTrue);

      cb.allowRequest();
      cb.recordFailure();
      expect(cb.isOpen, isTrue);
    });

    test('rejects requests when open', () {
      final cb = createBreaker(failureThreshold: 1);
      cb.allowRequest();
      cb.recordFailure();
      expect(cb.isOpen, isTrue);

      expect(cb.allowRequest(), isFalse);
    });

    test('transitions to halfOpen after openTimeout and allows a probe', () {
      final cb = createBreaker(failureThreshold: 1, openTimeout: const Duration(seconds: 30));
      cb.allowRequest();
      cb.recordFailure();
      expect(cb.isOpen, isTrue);

      // Advance time by 31 seconds
      fakeNow = fakeNow.add(const Duration(seconds: 31));

      // First call transitions to halfOpen and returns false (or allows single probe)
      cb.allowRequest();
      expect(cb.state, equals(CircuitBreakerState.halfOpen));

      // Next call allows single probe request
      expect(cb.allowRequest(), isTrue);
    });

    test('closes when probe succeeds in halfOpen', () {
      final cb = createBreaker(failureThreshold: 1, openTimeout: const Duration(seconds: 30));
      cb.allowRequest();
      cb.recordFailure();
      expect(cb.isOpen, isTrue);

      fakeNow = fakeNow.add(const Duration(seconds: 31));
      cb.allowRequest(); // transitions to halfOpen
      cb.allowRequest(); // probe allowed

      cb.recordSuccess();
      expect(cb.isClosed, isTrue);
    });
  });
}
