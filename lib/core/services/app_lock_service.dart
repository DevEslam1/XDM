import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Service for managing PIN and Security Lock for the XDM app.
class AppLockService {
  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _pinKey = 'xdm_app_lock_pin';
  static const String _enabledKey = 'xdm_app_lock_enabled';

  /// Returns true if application security lock is enabled.
  static Future<bool> isLockEnabled() async {
    final enabled = await _storage.read(key: _enabledKey);
    return enabled == 'true';
  }

  /// Sets or updates the security lock PIN.
  static Future<void> setPin(String pin) async {
    await _storage.write(key: _pinKey, value: pin);
    await _storage.write(key: _enabledKey, value: 'true');
  }

  /// Verifies if [pin] matches the configured security PIN.
  static Future<bool> verifyPin(String pin) async {
    final storedPin = await _storage.read(key: _pinKey);
    return storedPin != null && storedPin == pin;
  }

  /// Disables the security lock.
  static Future<void> disableLock() async {
    await _storage.delete(key: _pinKey);
    await _storage.write(key: _enabledKey, value: 'false');
  }
}
