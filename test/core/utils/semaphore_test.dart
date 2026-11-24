import 'dart:async';

import 'package:dmx/core/utils/semaphore.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Semaphore', () {
    test('acquire increments up to maxCount and release decrements', () async {
      final semaphore = Semaphore(2);
      expect(semaphore.maxCount, 2);
      expect(semaphore.currentCount, 0);

      await semaphore.acquire();
      expect(semaphore.currentCount, 1);
      await semaphore.acquire();
      expect(semaphore.currentCount, 2);
      expect(semaphore.waiterCount, 0);

      semaphore.release();
      expect(semaphore.currentCount, 1);
      semaphore.release();
      expect(semaphore.currentCount, 0);
    });

    test('acquire beyond maxCount queues a waiter until release', () async {
      final semaphore = Semaphore(1);
      await semaphore.acquire();

      var acquired = false;
      final pending = semaphore.acquire().then((_) => acquired = true);
      // Let the microtask queue drain.
      await Future<void>.delayed(Duration.zero);

      expect(acquired, isFalse);
      expect(semaphore.waiterCount, 1);

      semaphore.release();
      await pending;
      expect(acquired, isTrue);
      expect(semaphore.waiterCount, 0);
      expect(semaphore.currentCount, 1);
    });

    test('acquireWithTimeout acquires immediately when a permit is free',
        () async {
      final semaphore = Semaphore(1);
      await semaphore.acquireWithTimeout(const Duration(milliseconds: 50));
      expect(semaphore.currentCount, 1);
      semaphore.release();
      expect(semaphore.currentCount, 0);
    });

    test('acquireWithTimeout times out without leaking a permit or waiter',
        () async {
      final semaphore = Semaphore(1);
      await semaphore.acquire();

      await expectLater(
        semaphore.acquireWithTimeout(const Duration(milliseconds: 30)),
        throwsA(isA<TimeoutException>()),
      );

      expect(semaphore.waiterCount, 0);
      expect(semaphore.currentCount, 1);

      // The semaphore is still usable after a timeout.
      semaphore.release();
      expect(semaphore.currentCount, 0);
      await semaphore.acquireWithTimeout(const Duration(milliseconds: 30));
      expect(semaphore.currentCount, 1);
      semaphore.release();
    });

    test('release with no outstanding permits trips the debug assertion', () {
      final semaphore = Semaphore(1);
      expect(() => semaphore.release(), throwsA(isA<AssertionError>()));
    });
  });
}
