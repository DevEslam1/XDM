import 'package:dmx/core/services/download_journal.dart';
import 'package:flutter_test/flutter_test.dart';

/// M-4: persistence-failure observability. Before this, a failing `StateStore.save`
/// was swallowed with a `debugPrint`, so resume state could silently stop advancing.
/// These counters + the `persistenceDegraded` flag make every failure observable.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('M-4: StateStore persistence-failure observability', () {
    setUp(() {
      // Counters are static/process-wide; reset the consecutive streak so each
      // test starts from a known baseline (totalSaveFailures is delta-checked).
      StateStore.markSaveSuccess();
    });

    test(
        'persistenceDegraded flips true only after 3 consecutive failures and clears on success',
        () {
      final err = Exception('disk full');
      final st = StackTrace.current;

      expect(StateStore.persistenceDegraded, isFalse);

      StateStore.recordSaveFailure('/tmp/a.dmxpart', err, st);
      expect(StateStore.persistenceDegraded, isFalse); // 1 consecutive

      StateStore.recordSaveFailure('/tmp/a.dmxpart', err, st);
      expect(StateStore.persistenceDegraded, isFalse); // 2 consecutive

      StateStore.recordSaveFailure('/tmp/a.dmxpart', err, st);
      expect(StateStore.persistenceDegraded, isTrue); // 3 -> degraded

      StateStore.markSaveSuccess();
      expect(StateStore.persistenceDegraded, isFalse); // a good save clears it
    });

    test('a single success resets the consecutive counter mid-streak', () {
      final err = Exception('io error');
      final st = StackTrace.current;

      StateStore.recordSaveFailure('/tmp/b.dmxpart', err, st);
      StateStore.recordSaveFailure('/tmp/b.dmxpart', err, st);
      StateStore.markSaveSuccess(); // interrupts the streak

      StateStore.recordSaveFailure('/tmp/b.dmxpart', err, st);
      StateStore.recordSaveFailure('/tmp/b.dmxpart', err, st);
      // Only 2 consecutive since the reset -> not degraded.
      expect(StateStore.persistenceDegraded, isFalse);
    });

    test(
        'totalSaveFailures accumulates and lastSaveError tracks the most recent error',
        () {
      final before = StateStore.totalSaveFailures;
      final firstErr = Exception('first');
      final secondErr = StateError('second');

      StateStore.recordSaveFailure(
          '/tmp/c.dmxpart', firstErr, StackTrace.current);
      expect(StateStore.lastSaveError, same(firstErr));

      StateStore.recordSaveFailure(
          '/tmp/c.dmxpart', secondErr, StackTrace.current);
      expect(StateStore.lastSaveError, same(secondErr));

      expect(StateStore.totalSaveFailures, equals(before + 2));
    });
  });
}
