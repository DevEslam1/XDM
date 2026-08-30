import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:dmx/core/services/app_lock_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    AppLockService.resetMonotonicState();
  });

  group('AppLockService', () {
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

    test('Lockout cannot be bypassed by clock change', () async {
      await AppLockService.setPin('1234');

      for (var i = 0; i < 5; i++) {
        await AppLockService.verifyPin('9999');
      }

      final remainingBefore = await AppLockService.lockoutRemaining();
      expect(remainingBefore.inSeconds, greaterThan(0));

      // Attempting to verify immediately still blocked despite wall clock
      final blocked = await AppLockService.verifyPin('1234');
      expect(blocked, isFalse);

      final remainingAfter = await AppLockService.lockoutRemaining();
      expect(remainingAfter.inSeconds, greaterThan(0));
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
  });
}
