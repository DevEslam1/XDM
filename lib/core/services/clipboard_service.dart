import 'dart:async';

import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/url_utils.dart';

class ClipboardService {
  static final ClipboardService _instance = ClipboardService._internal();
  factory ClipboardService() => _instance;
  ClipboardService._internal();

  static const _secureStorage = FlutterSecureStorage();
  String? _lastCheckedUrl;
  DateTime? _lastCheckedTime;
  bool _initialized = false;
  bool _initStarted = false;
  int _initAttempts = 0;
  bool _clipboardMonitoringDegraded = false;
  bool get clipboardMonitoringDegraded => _clipboardMonitoringDegraded;
  static final ValueNotifier<bool> monitoringDegradedNotifier =
      ValueNotifier<bool>(false);

  /// When true, secure-storage reads/writes are skipped entirely. Used by
  /// tests where the flutter_secure_storage platform channel is unavailable.
  @visibleForTesting
  static bool bypassSecureStorage = false;

  /// One-shot lazy init triggered only after a downloadable URL is detected.
  ///
  /// Never awaited from the synchronous clipboard-check path: the future is
  /// scheduled in the background (fire-and-forget) so the UI thread can never
  /// block on the secure-storage platform channel.
  void _initIfNeeded() {
    if (_initialized || _initStarted) return;
    _initStarted = true;
    unawaited(_initWithBackoff());
  }

  /// Initializes from secure storage with a single 1.5s timeout per attempt and
  /// exponential backoff between attempts (max 3 attempts).
  Future<void> _initWithBackoff() async {
    while (!_initialized && _initAttempts < 3) {
      _initAttempts++;
      try {
        await _doInit().timeout(const Duration(milliseconds: 1500));
      } catch (e) {
        LoggingService.logger('ClipboardService').warning(
          '[ClipboardService] initialization attempt $_initAttempts failed or timed out: $e',
        );
        if (!_initialized && _initAttempts < 3) {
          await Future<void>.delayed(
            Duration(milliseconds: 100 * (1 << _initAttempts)),
          );
        }
      }
    }
    if (!_initialized) {
      LoggingService.logger('ClipboardService').warning(
        '[ClipboardService] Max initialization attempts reached. Halting init retries.',
      );
      _clipboardMonitoringDegraded = true;
      monitoringDegradedNotifier.value = true;
      // Mark as initialized to stop further attempts; dedupe uses memory state.
      _initialized = true;
    }
  }

  Future<void> _doInit() async {
    if (_initialized) return;
    if (bypassSecureStorage) {
      _initialized = true;
      return;
    }
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

  Future<String?> checkClipboardForUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool('clipboard_monitoring_enabled') ?? false;
      if (!enabled) return null;

      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();

      if (text != null &&
          (isHttpUrl(text) || isMagnetUrl(text) || isTorrentFileUrl(text))) {
        final lower = text.toLowerCase();
        if (lower.startsWith('javascript:') ||
            lower.startsWith('data:') ||
            lower.startsWith('vbscript:')) {
          return null;
        }

        // One-shot lazy init, triggered only after first URL detection.
        _initIfNeeded();

        final now = DateTime.now();
        if (text == _lastCheckedUrl && _lastCheckedTime != null) {
          final elapsed = now.difference(_lastCheckedTime!);
          if (elapsed < const Duration(seconds: 30)) {
            return null;
          }
          _lastCheckedTime = now;
          unawaited(_writeLastChecked(now, url: text));
          return text;
        }

        _lastCheckedUrl = text;
        _lastCheckedTime = now;
        unawaited(_writeLastChecked(now, url: text));
        return text;
      }
    } catch (e) {
      debugPrint('ClipboardService error checking URL: $e');
    }
    return null;
  }

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
      await _writeLastChecked(_lastCheckedTime!, url: trimmed);
    } catch (e) {
      debugPrint('ClipboardService error saving last URL: $e');
    }
  }

  Future<void> _writeLastChecked(DateTime now, {String? url}) async {
    if (bypassSecureStorage) return;
    try {
      if (url != null) {
        await _secureStorage.write(key: 'clipboard_last_url', value: url);
      }
      await _secureStorage.write(
        key: 'clipboard_last_time',
        value: '${now.millisecondsSinceEpoch}',
      );
    } catch (e) {
      LoggingService.logger('ClipboardService').info(
        '[ClipboardService] last-checked URL persist skipped: $e',
      );
    }
  }
}
