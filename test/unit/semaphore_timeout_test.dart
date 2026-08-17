import 'dart:async';
import 'package:dmx/core/utils/semaphore.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Semaphore Timeout & Concurrency Tests', () {
    test('acquires and releases within maxCount', () async {
      final semaphore = Semaphore(2);

      await semaphore.acquire();
      expect(semaphore.currentCount, 1);

      await semaphore.acquire();
      expect(semaphore.currentCount, 2);

      semaphore.release();
      expect(semaphore.currentCount, 1);

      semaphore.release();
      expect(semaphore.currentCount, 0);
    });

    test('acquireWithTimeout succeeds when permits available', () async {
      final semaphore = Semaphore(2);

      await semaphore.acquireWithTimeout(const Duration(milliseconds: 50));
      expect(semaphore.currentCount, 1);

      await semaphore.acquireWithTimeout(const Duration(milliseconds: 50));
      expect(semaphore.currentCount, 2);

      semaphore.release();
      semaphore.release();
      expect(semaphore.currentCount, 0);
    });

    test('acquireWithTimeout throws TimeoutException without leaking permit',
        () async {
      final semaphore = Semaphore(1);
      await semaphore.acquire();
      expect(semaphore.currentCount, 1);

      // Try acquiring second permit with timeout
      expect(
        () => semaphore.acquireWithTimeout(const Duration(milliseconds: 50)),
        throwsA(isA<TimeoutException>()),
      );

      await Future.delayed(const Duration(milliseconds: 70));
      expect(semaphore.waiterCount, 0);
      expect(semaphore.currentCount, 1);

      // Now release first permit
      semaphore.release();
      expect(semaphore.currentCount, 0);

      // A new acquire should succeed immediately and not be blocked or starved
      await semaphore.acquireWithTimeout(const Duration(milliseconds: 50));
      expect(semaphore.currentCount, 1);
      semaphore.release();
      expect(semaphore.currentCount, 0);
    });

    test('multiple timed-out waiters do not starve future acquires', () async {
      final semaphore = Semaphore(1);
      await semaphore.acquire();

      final timeouts = <Future>[];
      for (int i = 0; i < 5; i++) {
        timeouts.add(
          expectLater(
            semaphore.acquireWithTimeout(const Duration(milliseconds: 30)),
            throwsA(isA<TimeoutException>()),
          ),
        );
      }

      await Future.wait(timeouts);
      expect(semaphore.waiterCount, 0);

      semaphore.release();
      expect(semaphore.currentCount, 0);

      // Verify semaphore can still be acquired up to maxCount
      await semaphore.acquire();
      expect(semaphore.currentCount, 1);
      semaphore.release();
      expect(semaphore.currentCount, 0);
    });
  });
}
