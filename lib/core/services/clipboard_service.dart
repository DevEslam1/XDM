import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/url_utils.dart';
import 'package:dmx/core/services/logging_service.dart';

class ClipboardService {
  static final ClipboardService _instance = ClipboardService._internal();
  factory ClipboardService() => _instance;
  ClipboardService._internal();

  // FIX(24): the last-detected URL + timestamp are persisted in secure
  // storage (they can contain auth-embedded share links); the monitoring
  // enabled flag stays in SharedPreferences since it is not sensitive.
  static const _secureStorage = FlutterSecureStorage();

  String? _lastCheckedUrl;
  DateTime? _lastCheckedTime;
  // FIX: Removed unused _urlTtl field. The 30-minute TTL logic was flawed
  // and has been replaced by a strict 30-second per-URL rate limit.
  bool _initialized = false;
  Future<void>? _initFuture;

  // FIX-P0-5: Guard concurrent initialization using a Completer pattern.
  Future<void> _initIfNeeded() async {
    if (_initialized) return;
    if (_initFuture != null) {
      try {
        await _initFuture;
        return;
      } catch (e) {
        LoggingService.logger('ClipboardService').info(
          '[ClipboardService] previous init future failed, will retry: $e',
        );
        _initFuture = null;
      }
    }
    _initFuture = _doInit();
    try {
      await _initFuture;
    } catch (e) {
      _initFuture = null;
      LoggingService.logger('ClipboardService').warning(
        '[ClipboardService] initialization failed: $e',
      );
    }
  }

  Future<void> _doInit() async {
    if (_initialized) return;
    try {
      _lastCheckedUrl = await _secureStorage.read(key: 'clipboard_last_url');
      final timeMsStr = await _secureStorage.read(key: 'clipboard_last_time');
      final timeMs = int.tryParse(timeMsStr ?? '');
      if (timeMs != null) {
        _lastCheckedTime = DateTime.fromMillisecondsSinceEpoch(timeMs);
      }
    } catch (e) {
      debugPrint('ClipboardService error reading secure storage: $e');
    }
    _initialized = true;
  }

  /// Checks if there is a new valid HTTP/HTTPS URL on the clipboard.
  /// Returns the URL if it's new, otherwise null.
  Future<String?> checkClipboardForUrl() async {
    try {
      await _initIfNeeded();

      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool('clipboard_monitoring_enabled') ?? false;
      if (!enabled) return null;

      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();
      if (text != null &&
          (isHttpUrl(text) || isMagnetUrl(text) || isTorrentFileUrl(text))) {
        // Basic safety: reject URLs with suspicious patterns
        final lower = text.toLowerCase();
        if (lower.startsWith('javascript:') ||
            lower.startsWith('data:') ||
            lower.startsWith('vbscript:')) {
          return null;
        }

        final now = DateTime.now();

        // FIX(11): per-URL rate limit. Same URL re-prompted within 30s (or
        // within the 30-minute TTL) is skipped; a different URL passes
        // through immediately.
        if (text == _lastCheckedUrl && _lastCheckedTime != null) {
          final elapsed = now.difference(_lastCheckedTime!);
          // FIX: Only skip the SAME URL within 30 seconds (per-URL rate limit).
          // The previous `|| elapsed <= _urlTtl` made the 30s window redundant
          // and effectively blocked re-prompting for the full 30-minute TTL.
          if (elapsed < const Duration(seconds: 30)) {
            return null;
          }
          _lastCheckedTime = now;
          try {
            await _secureStorage.write(
              key: 'clipboard_last_time',
              value: '${now.millisecondsSinceEpoch}',
            );
          } catch (e) {
            LoggingService.logger('ClipboardService').info(
              '[ClipboardService] rate-limit timestamp persist skipped: $e',
            );
          }
          return text;
        }

        _lastCheckedUrl = text;
        _lastCheckedTime = now;
        try {
          await _secureStorage.write(key: 'clipboard_last_url', value: text);
          await _secureStorage.write(
            key: 'clipboard_last_time',
            value: '${now.millisecondsSinceEpoch}',
          );
        } catch (e) {
          LoggingService.logger('ClipboardService').info(
            '[ClipboardService] last-checked URL persist skipped: $e',
          );
        }
        return text;
      }
    } catch (e) {
      debugPrint('ClipboardService error checking URL: $e');
    }
    return null;
  }

  /// Sets the last checked URL so we don't prompt for it again.
  Future<void> markAsChecked(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty ||
        (!isHttpUrl(trimmed) &&
            !isMagnetUrl(trimmed) &&
            !isTorrentFileUrl(trimmed))) {
      return;
    }
    _lastCheckedUrl = trimmed;
    _lastCheckedTime = DateTime.now();
    try {
      await _secureStorage.write(key: 'clipboard_last_url', value: trimmed);
      await _secureStorage.write(
        key: 'clipboard_last_time',
        value: '${_lastCheckedTime!.millisecondsSinceEpoch}',
      );
    } catch (e) {
      debugPrint('ClipboardService error saving last URL: $e');
    }
  }
}
