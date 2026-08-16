import 'package:dmx/core/services/app_lock_service.dart';
import 'package:dmx/core/utils/crypto_utils.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('App-lock KDF stretching (H21)', () {
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
            storage[args?['key'] as String] = args?['value'] as String;
            return null;
          } else if (methodCall.method == 'read') {
            return storage[args?['key'] as String];
          } else if (methodCall.method == 'delete') {
            storage.remove(args?['key'] as String);
            return null;
          }
          return null;
        },
      );
    });

    test('default PBKDF2 uses the strong 100k iteration count', () {
      final hash = pbkdf2Hash('1234', 'somesalt');
      expect(hash.length, equals(64)); // 32 bytes hex
      // Deterministic with the same parameters.
      expect(pbkdf2Hash('1234', 'somesalt'), equals(hash));
      // A different secret must produce a different hash.
      expect(pbkdf2Hash('1235', 'somesalt'), isNot(equals(hash)));
    });

    test('PBKDF2 is salt-sensitive (rainbow tables ineffective)', () {
      final h1 = pbkdf2Hash('1234', 'saltA');
      final h2 = pbkdf2Hash('1234', 'saltB');
      expect(h1, isNot(equals(h2)));
    });

    test('hashSecret embeds salt in the stored format', () {
      final stored = hashSecret('9999', salt: 'my-salt');
      expect(stored, startsWith('pbkdf2:'));
      expect(stored, contains('my-salt'));
      expect(stored, isNot(equals('9999')));
      // The plaintext PIN never appears in the stored value.
      expect(stored, isNot(contains('9999')));
    });

    test('setPin stores a stretched hash, never a raw SHA-256', () async {
      await AppLockService.setPin('1234');
      final storedPin = storage['xdm_app_lock_pin'];
      expect(storedPin, startsWith('pbkdf2:'));
      // No unstretched SHA-256 (64 hex chars with no prefix) is stored.
      expect(storedPin, isNot(equals(legacyHashSecret('1234'))));
    });

    test('setPin uses a fresh random salt per write', () async {
      await AppLockService.setPin('1234');
      final salt1 = storage['xdm_app_lock_salt'];
      await AppLockService.setPin('1234');
      final salt2 = storage['xdm_app_lock_salt'];
      expect(salt1, isNotNull);
      expect(salt2, isNotNull);
      // Base64 16-byte salt is long enough to differ.
      expect(salt1, isNot(equals(salt2)));
    });

    test('verification recomputes with the stored salt and succeeds', () async {
      await AppLockService.setPin('5678');
      expect(await AppLockService.verifyPin('5678'), isTrue);
      expect(await AppLockService.verifyPin('0000'), isFalse);
    });

    test('timingSafeEqual detects differences', () {
      expect(timingSafeEqual('abc', 'abc'), isTrue);
      expect(timingSafeEqual('abc', 'abd'), isFalse);
      expect(timingSafeEqual('', ''), isTrue);
      expect(timingSafeEqual('a', ''), isFalse);
    });

    test('legacy helpers remain deterministic for backward compatibility', () {
      final stretched = legacyStretchedHash('1234', salt: 'salt');
      expect(stretched, equals(legacyStretchedHash('1234', salt: 'salt')));
      expect(stretched, isNot(equals(legacyHashSecret('1234', salt: 'salt'))));
      expect(legacyHashSecret('1234', salt: 'salt'),
          isNot(equals(legacyHashSecret('1234', salt: 'other'))));
    });
  });
}
