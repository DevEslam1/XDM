import 'dart:convert';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../utils/crypto_utils.dart';

class AppLockService {
  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _pinKey = 'xdm_app_lock_pin';
  static const String _saltKey = 'xdm_app_lock_salt';
  static const String _enabledKey = 'xdm_app_lock_enabled';
  static const String _failedAttemptsKey = 'xdm_app_lock_failed_attempts';
  static const String _lockoutLevelKey = 'xdm_app_lock_lockout_level';
  static const String _lockedUntilKey = 'xdm_app_lock_locked_until';

  static Future<bool> isLockEnabled() async {
    final enabled = await _storage.read(key: _enabledKey);
    return enabled == 'true';
  }

  static String _generateRandomSalt() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return base64Encode(bytes);
  }

  static Future<void> setPin(String pin) async {
    final salt = _generateRandomSalt();
    await _storage.write(key: _saltKey, value: salt);
    final hashed = hashSecret(pin, salt: salt);
    await _storage.write(key: _pinKey, value: hashed);
    await _storage.write(key: _enabledKey, value: 'true');
    await resetFailedAttempts();
  }

  static Future<bool> verifyPin(String pin) async {
    if (await lockoutRemaining() > Duration.zero) return false;

    final storedPin = await _storage.read(key: _pinKey);
    final salt = await _storage.read(key: _saltKey);

    // FIX: If storedPin or salt is null, the secure storage is corrupted.
    // Do NOT register a failed attempt — the user's PIN may be correct but
    // the storage is unreadable. Registering failures here would lock out
    // users with corrupted storage rather than wrong PINs.
    if (storedPin == null || salt == null) {
      return false;
    }

    final hashedInput = hashSecret(pin, salt: salt);
    final matches = timingSafeEqual(storedPin, hashedInput);
    if (matches) {
      await resetFailedAttempts();
      return true;
    }
    await _registerFailedAttempt();
    return false;
  }

  static Future<Duration> lockoutRemaining() async {
    final raw = await _storage.read(key: _lockedUntilKey);
    final lockedUntil = int.tryParse(raw ?? '');
    if (lockedUntil == null) return Duration.zero;
    final remaining = DateTime.fromMillisecondsSinceEpoch(lockedUntil)
        .difference(DateTime.now());
    if (remaining <= Duration.zero) {
      await _storage.delete(key: _lockedUntilKey);
      return Duration.zero;
    }
    return remaining;
  }

  static int _lockoutSecondsForLevel(int level) {
    switch (level) {
      case 1:
        return 30;
      case 2:
        return 60;
      case 3:
        return 120;
      case 4:
        return 300;
      case 5:
        return 600;
      default:
        return 900;
    }
  }

  static Future<void> _registerFailedAttempt() async {
    final attempts = int.tryParse(
          await _storage.read(key: _failedAttemptsKey) ?? '',
        ) ??
        0;
    final nextAttempts = attempts + 1;

    if (nextAttempts < 5) {
      await _storage.write(
        key: _failedAttemptsKey,
        value: nextAttempts.toString(),
      );
      return;
    }

    final level = int.tryParse(
          await _storage.read(key: _lockoutLevelKey) ?? '',
        ) ??
        0;
    final nextLevel = level + 1;
    final seconds = _lockoutSecondsForLevel(nextLevel);
    final lockedUntil =
        DateTime.now().add(Duration(seconds: seconds)).millisecondsSinceEpoch;

    await _storage.write(key: _failedAttemptsKey, value: '0');
    await _storage.write(key: _lockoutLevelKey, value: nextLevel.toString());
    await _storage.write(
      key: _lockedUntilKey,
      value: lockedUntil.toString(),
    );
  }

  static Future<void> resetFailedAttempts() async {
    await _storage.delete(key: _failedAttemptsKey);
    await _storage.delete(key: _lockoutLevelKey);
    await _storage.delete(key: _lockedUntilKey);
  }

  static Future<void> disableLock() async {
    await _storage.delete(key: _pinKey);
    await _storage.delete(key: _saltKey);
    await _storage.write(key: _enabledKey, value: 'false');
    await resetFailedAttempts();
  }
}
