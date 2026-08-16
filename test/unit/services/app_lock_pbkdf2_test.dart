import 'package:dmx/core/services/app_lock_service.dart';
import 'package:dmx/core/utils/crypto_utils.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppLockService PBKDF2 Tests (SEC-04)', () {
    final Map<String, String> storage = {};

    setUp(() {
      storage.clear();
      AppLockService.resetMonotonicState();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (methodCall) async {
          final args = methodCall.arguments as Map?;
          if (methodCall.method == 'write') {
            final key = args?['key'] as String;
            final value = args?['value'] as String;
            storage[key] = value;
            return null;
          } else if (methodCall.method == 'read') {
            final key = args?['key'] as String;
            return storage[key];
          } else if (methodCall.method == 'delete') {
            final key = args?['key'] as String;
            storage.remove(key);
            return null;
          }
          return null;
        },
      );
    });

    test(
        'pbkdf2Hash produces deterministic output for given salt and iterations',
        () {
      final hash1 =
          pbkdf2Hash('1234', 'test_salt_1234', iterations: 1000, keyLength: 16);
      final hash2 =
          pbkdf2Hash('1234', 'test_salt_1234', iterations: 1000, keyLength: 16);
      expect(hash1, equals(hash2));
      expect(hash1.length, equals(32)); // 16 bytes hex = 32 chars
    });

    test('setPin and verifyPin round-trip succeeds with PBKDF2', () async {
      await AppLockService.setPin('4321');
      final storedPin = storage['xdm_app_lock_pin'];
      expect(storedPin, startsWith('pbkdf2:'));

      final verified = await AppLockService.verifyPin('4321');
      expect(verified, isTrue);

      final wrong = await AppLockService.verifyPin('9999');
      expect(wrong, isFalse);
    });

    test('verifyPin transparently migrates legacy SHA-256 hash to PBKDF2',
        () async {
      const salt = 'legacy_salt';
      storage['xdm_app_lock_salt'] = salt;
      storage['xdm_app_lock_pin'] = legacyHashSecret('1111', salt: salt);
      storage['xdm_app_lock_enabled'] = 'true';

      expect(storage['xdm_app_lock_pin'], isNot(startsWith('pbkdf2:')));

      final verified = await AppLockService.verifyPin('1111');
      expect(verified, isTrue);

      // Successfully migrated
      expect(storage['xdm_app_lock_pin'], startsWith('pbkdf2:'));

      // Subsequent verification uses PBKDF2 directly
      final verifiedAgain = await AppLockService.verifyPin('1111');
      expect(verifiedAgain, isTrue);
    });

    test('lockout remains enforced when device clock is rolled back', () async {
      await AppLockService.setPin('1234');

      // Trigger 5 failed attempts to initiate lockout (level 1 = 30s = 30000ms)
      for (int i = 0; i < 5; i++) {
        await AppLockService.verifyPin('0000');
      }

      final remainingInitial = await AppLockService.lockoutRemaining();
      expect(remainingInitial.inSeconds, greaterThan(0));
      expect(remainingInitial.inSeconds, lessThanOrEqualTo(30));

      // Simulate wall clock rollback by modifying stored locked_until far into future or past
      final storedDuration =
          int.parse(storage['xdm_app_lock_lockout_duration']!);
      expect(storedDuration, equals(30000));

      // Simulate device clock rollback by setting lockedUntil 1 hour in future vs now
      storage['xdm_app_lock_locked_until'] =
          (DateTime.now().millisecondsSinceEpoch + 3600000).toString();

      // Reset in-memory state to force re-reading from storage
      AppLockService.resetMonotonicState();

      // Lockout remaining should enforce full duration rather than allowing bypass
      final remainingAfterRollback = await AppLockService.lockoutRemaining();
      expect(remainingAfterRollback.inSeconds, greaterThan(0));
      expect(remainingAfterRollback.inMilliseconds, inInclusiveRange(29000, 30000));

      // Verification must be rejected while lockout is active
      expect(await AppLockService.verifyPin('1234'), isFalse);
    });
  });
}
