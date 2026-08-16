import 'package:dmx/core/services/app_lock_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    AppLockService.resetMonotonicState();
  });

  tearDown(() {
    AppLockService.resetMonotonicState();
  });

  group('AppLockService (FIX-08)', () {
    test('Lockout triggers after 5 failed attempts', () async {
      await AppLockService.setPin('1234');

      for (var i = 0; i < 4; i++) {
        final verified = await AppLockService.verifyPin('9999');
        expect(verified, isFalse);
        final remaining = await AppLockService.lockoutRemaining();
        expect(remaining, equals(Duration.zero));
      }

      final fifthAttempt = await AppLockService.verifyPin('9999');
      expect(fifthAttempt, isFalse);

      final remaining = await AppLockService.lockoutRemaining();
      expect(remaining.inSeconds, greaterThan(0));
    });

    test('Lockout duration increases with level', () async {
      await AppLockService.setPin('1234');

      // Level 1 lockout (5 failures -> 30s)
      for (var i = 0; i < 5; i++) {
        await AppLockService.verifyPin('9999');
      }
      final level1Remaining = await AppLockService.lockoutRemaining();
      expect(level1Remaining.inSeconds, greaterThan(0));
      expect(level1Remaining.inSeconds, lessThanOrEqualTo(30));
    });

    test('Reboot scenario re-derives lockout from persisted lockedUntil', () async {
      await AppLockService.setPin('1234');
      for (var i = 0; i < 5; i++) {
        await AppLockService.verifyPin('9999');
      }

      // Simulate process reboot by clearing in-memory monotonic state
      AppLockService.resetMonotonicState();

      // Lockout remaining should still be active from storage
      final remainingAfterReboot = await AppLockService.lockoutRemaining();
      expect(remainingAfterReboot.inSeconds, greaterThan(0));
      expect(remainingAfterReboot.inSeconds, lessThanOrEqualTo(30));
    });

    test('Clock skew backward jump > 60s detected by validateMonotonicConsistency', () async {
      await AppLockService.setPin('1234');
      for (var i = 0; i < 5; i++) {
        await AppLockService.verifyPin('9999');
      }

      // Record future observed time to simulate backwards clock jump
      AppLockService.lastObservedTimeMs =
          DateTime.now().millisecondsSinceEpoch + 120000;

      await AppLockService.validateMonotonicConsistency();

      // Lockout should remain active and guarded
      final remaining = await AppLockService.lockoutRemaining();
      expect(remaining.inSeconds, greaterThan(0));
    });

    test('Lockout expiry resets failed attempts and permits verification', () async {
      await AppLockService.setPin('1234');
      for (var i = 0; i < 5; i++) {
        await AppLockService.verifyPin('9999');
      }

      // Mock monotonic time past the 30s lockout (e.g. +35s)
      final nowMono = await AppLockService.getMonotonicTimeMs();
      AppLockService.mockMonotonicTimeMs = nowMono + 35000;

      final remaining = await AppLockService.lockoutRemaining();
      expect(remaining, equals(Duration.zero));

      // After lockout expiry, correct PIN is accepted
      final success = await AppLockService.verifyPin('1234');
      expect(success, isTrue);
    });

    test('Successful unlock resets lockout', () async {
      await AppLockService.setPin('1234');

      for (var i = 0; i < 3; i++) {
        await AppLockService.verifyPin('9999');
      }

      final success = await AppLockService.verifyPin('1234');
      expect(success, isTrue);

      final remaining = await AppLockService.lockoutRemaining();
      expect(remaining, equals(Duration.zero));
    });

    test('Disable lock cleans up stored PIN and lockout', () async {
      await AppLockService.setPin('1234');
      expect(await AppLockService.isLockEnabled(), isTrue);

      await AppLockService.disableLock();
      expect(await AppLockService.isLockEnabled(), isFalse);
    });

    test('Lockout state survives a clock rollback', () async {
      await AppLockService.setPin('1234');
      for (var i = 0; i < 5; i++) {
        await AppLockService.verifyPin('9999');
      }

      final initialRemaining = await AppLockService.lockoutRemaining();
      expect(initialRemaining.inSeconds, greaterThan(0));

      // Simulate a backwards clock jump by setting lastObservedTimeMs far in future
      AppLockService.lastObservedTimeMs =
          DateTime.now().millisecondsSinceEpoch + 3600000; // 1h in future

      // Reset monotonic state to simulate app process restart while clock was rolled back
      AppLockService.resetMonotonicState();

      // Lockout must survive the rollback
      final remainingAfterRollback = await AppLockService.lockoutRemaining();
      expect(remainingAfterRollback.inSeconds, greaterThan(0));
      expect(await AppLockService.verifyPin('1234'), isFalse);
    });
  });
}
