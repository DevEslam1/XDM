import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/url_utils.dart';

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
  static const Duration _urlTtl = Duration(minutes: 30);
  bool _initialized = false;
  Future<void>? _initFuture;

  Future<void> _initIfNeeded() async {
    if (_initFuture != null) {
      try {
        await _initFuture;
      } catch (_) {
        _initFuture = null;
      }
    }
    if (_initFuture == null) {
      _initFuture = _doInit();
      try {
        await _initFuture;
      } catch (e) {
        _initFuture = null;
      }
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
  /// Returns the URL if it's new (or if the last check was >30 minutes ago),
  /// otherwise null. A *new* URL is always returned; only the *same* URL seen
  /// again within 30 seconds is skipped (per-URL rate limit) to avoid
  /// re-prompting without dropping genuinely new links.
  Future<String?> checkClipboardForUrl() async {
    await _initIfNeeded();

    try {
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
          if (elapsed < const Duration(seconds: 30) || elapsed <= _urlTtl) {
            return null;
          }
          _lastCheckedTime = now;
          try {
            await _secureStorage.write(
              key: 'clipboard_last_time',
              value: '${now.millisecondsSinceEpoch}',
            );
          } catch (_) {}
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
        } catch (_) {}
        return text;
      }
    } catch (e) {
      debugPrint('ClipboardService error checking URL: $e');
    }
    return null;
  }

  /// Sets the last checked URL so we don't prompt for it again.
  Future<void> markAsChecked(String url) async {
    _lastCheckedUrl = url;
    _lastCheckedTime = DateTime.now();
    try {
      await _secureStorage.write(key: 'clipboard_last_url', value: url);
      await _secureStorage.write(
        key: 'clipboard_last_time',
        value: '${_lastCheckedTime!.millisecondsSinceEpoch}',
      );
    } catch (e) {
      debugPrint('ClipboardService error saving last URL: $e');
    }
  }
}
