import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure PIN storage and persisted brute-force protection for the app lock.
class AppLockService {
  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _pinKey = 'xdm_app_lock_pin';
  static const String _enabledKey = 'xdm_app_lock_enabled';
  static const String _failedAttemptsKey = 'xdm_app_lock_failed_attempts';
  static const String _lockoutLevelKey = 'xdm_app_lock_lockout_level';
  static const String _lockedUntilKey = 'xdm_app_lock_locked_until';

  static Future<bool> isLockEnabled() async {
    final enabled = await _storage.read(key: _enabledKey);
    return enabled == 'true';
  }

  static Future<void> setPin(String pin) async {
    await _storage.write(key: _pinKey, value: pin);
    await _storage.write(key: _enabledKey, value: 'true');
    await resetFailedAttempts();
  }

  /// Returns whether [pin] matches and updates persisted retry protection.
  static Future<bool> verifyPin(String pin) async {
    if (await lockoutRemaining() > Duration.zero) return false;
    final storedPin = await _storage.read(key: _pinKey);
    if (storedPin != null && storedPin == pin) {
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
    final seconds = (30 * (1 << (nextLevel - 1))).clamp(30, 900);
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
    await _storage.write(key: _enabledKey, value: 'false');
    await resetFailedAttempts();
  }
}
