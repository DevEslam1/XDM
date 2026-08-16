import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
  static const String _lockoutDurationKey = 'xdm_app_lock_lockout_duration';
  static const String _lockoutStartElapsedKey = 'xdm_app_lock_start_elapsed';

  static const MethodChannel _monotonicChannel =
      MethodChannel('com.dmx.app/monotonic_clock');
  static final _log = LoggingService.logger('AppLockService');

  static int? _monotonicLockoutStartMs;
  static int? _totalLockoutDurationMs;
  static int _lastObservedTimeMs = 0;

  @visibleForTesting
  static int? mockMonotonicTimeMs;

  @visibleForTesting
  static int get lastObservedTimeMs => _lastObservedTimeMs;

  @visibleForTesting
  static set lastObservedTimeMs(int v) => _lastObservedTimeMs = v;

  static Future<int> getMonotonicTimeMs() async {
    if (mockMonotonicTimeMs != null) return mockMonotonicTimeMs!;
    try {
      final val = await _monotonicChannel.invokeMethod<int>('elapsedRealtime');
      if (val != null && val > 0) return val;
    } catch (e, st) {
      _log.warning('Operation failed', e, st);
    }
    return DateTime.now().millisecondsSinceEpoch;
  }

  /// Detects clock jumps > 60s backward and re-derives lockout from persisted `lockedUntil`.
  static Future<void> validateMonotonicConsistency() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_lastObservedTimeMs > 0 && (_lastObservedTimeMs - nowMs) > 60000) {
      _log.warning(
        'Detected backwards clock jump of ${_lastObservedTimeMs - nowMs}ms. '
        'Re-deriving lockout from persisted lockedUntil.',
      );
      final rawUntil = await _storage.read(key: _lockedUntilKey);
      final rawDuration = await _storage.read(key: _lockoutDurationKey);
      final lockedUntil = int.tryParse(rawUntil ?? '');
      final totalDurationMs = int.tryParse(rawDuration ?? '');
      if (lockedUntil != null && totalDurationMs != null) {
        final remainingMs = lockedUntil - nowMs;
        if (remainingMs > 0) {
          _monotonicLockoutStartMs = await getMonotonicTimeMs();
          _totalLockoutDurationMs = min(remainingMs, totalDurationMs);
        } else {
          await resetFailedAttempts();
        }
      }
    }
    _lastObservedTimeMs = nowMs;
  }

  @visibleForTesting
  static void resetMonotonicState() {
    _monotonicLockoutStartMs = null;
    _totalLockoutDurationMs = null;
    mockMonotonicTimeMs = null;
    _lastObservedTimeMs = 0;
  }

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

    if (storedPin == null || salt == null) {
      return false;
    }

    bool matches = false;
    if (storedPin.startsWith('pbkdf2:')) {
      final hashedInput = hashSecret(pin, salt: salt);
      matches = timingSafeEqual(storedPin, hashedInput);
    } else {
      // Legacy SHA-256 fallback check for transparent upgrade
      final stretchedInput = legacyStretchedHash(pin, salt: salt);
      final legacyInput = legacyHashSecret(pin, salt: salt);
      if (timingSafeEqual(storedPin, stretchedInput) ||
          timingSafeEqual(storedPin, legacyInput)) {
        matches = true;
        // Transparently upgrade to PBKDF2 format
        final upgradedHash = hashSecret(pin, salt: salt);
        await _storage.write(key: _pinKey, value: upgradedHash);
      }
    }

    if (matches) {
      await resetFailedAttempts();
      return true;
    }
    await _registerFailedAttempt();
    return false;
  }

  static Future<Duration> lockoutRemaining() async {
    await validateMonotonicConsistency();
    final currentMono = await getMonotonicTimeMs();

    // 1. Monotonic in-memory check (immune to clock changes during process runtime)
    if (_monotonicLockoutStartMs != null && _totalLockoutDurationMs != null) {
      final elapsedSinceStart = currentMono - _monotonicLockoutStartMs!;
      final remainingMs = _totalLockoutDurationMs! - elapsedSinceStart;
      if (remainingMs <= 0) {
        await resetFailedAttempts();
        return Duration.zero;
      }
      return Duration(milliseconds: remainingMs);
    }

    // 2. Storage check across process restarts
    final rawUntil = await _storage.read(key: _lockedUntilKey);
    final rawDuration = await _storage.read(key: _lockoutDurationKey);
    final rawStartElapsed = await _storage.read(key: _lockoutStartElapsedKey);
    final lockedUntil = int.tryParse(rawUntil ?? '');
    final totalDurationMs = int.tryParse(rawDuration ?? '');
    final startElapsed = int.tryParse(rawStartElapsed ?? '');

    if (lockedUntil == null || totalDurationMs == null) {
      return Duration.zero;
    }

    // If monotonic start was stored and current monotonic is available
    if (startElapsed != null && currentMono >= startElapsed) {
      final elapsedSinceStart = currentMono - startElapsed;
      if (elapsedSinceStart < totalDurationMs) {
        _monotonicLockoutStartMs = startElapsed;
        _totalLockoutDurationMs = totalDurationMs;
        return Duration(milliseconds: totalDurationMs - elapsedSinceStart);
      }
    }

    final wallRemaining = DateTime.fromMillisecondsSinceEpoch(lockedUntil)
        .difference(DateTime.now());

    // If wall clock was manipulated backwards, enforce full duration
    if (wallRemaining.inMilliseconds > totalDurationMs + 1000) {
      _monotonicLockoutStartMs = currentMono;
      _totalLockoutDurationMs = totalDurationMs;
      return Duration(milliseconds: totalDurationMs);
    }

    if (wallRemaining <= Duration.zero) {
      await resetFailedAttempts();
      return Duration.zero;
    }

    _monotonicLockoutStartMs = currentMono;
    _totalLockoutDurationMs = wallRemaining.inMilliseconds;
    return wallRemaining;
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
    final durationMs = seconds * 1000;
    final lockedUntil =
        DateTime.now().add(Duration(seconds: seconds)).millisecondsSinceEpoch;

    final monoNow = await getMonotonicTimeMs();
    _monotonicLockoutStartMs = monoNow;
    _totalLockoutDurationMs = durationMs;

    await _storage.write(key: _failedAttemptsKey, value: '0');
    await _storage.write(key: _lockoutLevelKey, value: nextLevel.toString());
    await _storage.write(
      key: _lockedUntilKey,
      value: lockedUntil.toString(),
    );
    await _storage.write(
      key: _lockoutDurationKey,
      value: durationMs.toString(),
    );
    await _storage.write(
      key: _lockoutStartElapsedKey,
      value: monoNow.toString(),
    );
  }

  static Future<void> resetFailedAttempts() async {
    _monotonicLockoutStartMs = null;
    _totalLockoutDurationMs = null;
    await _storage.delete(key: _failedAttemptsKey);
    await _storage.delete(key: _lockoutLevelKey);
    await _storage.delete(key: _lockedUntilKey);
    await _storage.delete(key: _lockoutDurationKey);
    await _storage.delete(key: _lockoutStartElapsedKey);
  }

  static Future<void> disableLock() async {
    await _storage.delete(key: _pinKey);
    await _storage.delete(key: _saltKey);
    await _storage.write(key: _enabledKey, value: 'false');
    await resetFailedAttempts();
  }

  static Completer<bool>? _activeAuthCompleter;

  /// Authenticates using the configured [authAction] callback.
  /// If an authentication request is already in-flight, subsequent concurrent calls
  /// await and share the same active authentication result without spawning multiple prompts (E1).
  static Future<bool> authenticate(
      {Future<bool> Function()? authAction}) async {
    if (!await isLockEnabled()) return true;

    if (_activeAuthCompleter != null) {
      return _activeAuthCompleter!.future;
    }

    final completer = Completer<bool>();
    _activeAuthCompleter = completer;

    try {
      final result = authAction != null ? await authAction() : false;
      completer.complete(result);
      return result;
    } catch (e, st) {
      LoggingService.logger('AppLockService')
          .warning('Authentication action threw error', e, st);
      completer.complete(false);
      return false;
    } finally {
      _activeAuthCompleter = null;
    }
  }
}
