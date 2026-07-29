import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/url_utils.dart';

class ClipboardService {
  static final ClipboardService _instance = ClipboardService._internal();
  factory ClipboardService() => _instance;
  ClipboardService._internal();

  String? _lastCheckedUrl;
  DateTime? _lastCheckedTime;
  static const Duration _urlTtl = Duration(minutes: 30);
  bool _initialized = false;
  Future<void>? _initFuture;

  Future<void> _initIfNeeded() {
    return _initFuture ??= _doInit();
  }

  Future<void> _doInit() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _lastCheckedUrl = prefs.getString('clipboard_last_url');
      final timeMs = prefs.getInt('clipboard_last_time');
      if (timeMs != null) {
        _lastCheckedTime = DateTime.fromMillisecondsSinceEpoch(timeMs);
      }
      _initialized = true;
    } catch (e) {
      debugPrint('ClipboardService error loading prefs: $e');
    }
  }

  /// Checks if there is a new valid HTTP/HTTPS URL on the clipboard.
  /// Returns the URL if it's new (or if the last check was >30 minutes ago),
  /// otherwise null.
  Future<String?> checkClipboardForUrl() async {
    await _initIfNeeded();
    try {
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
        if (text != _lastCheckedUrl) {
          _lastCheckedUrl = text;
          _lastCheckedTime = DateTime.now();
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('clipboard_last_url', text);
            await prefs.setInt(
              'clipboard_last_time',
              _lastCheckedTime!.millisecondsSinceEpoch,
            );
          } catch (_) {}
          return text;
        }
        final now = DateTime.now();
        if (_lastCheckedTime == null ||
            now.difference(_lastCheckedTime!) > _urlTtl) {
          _lastCheckedTime = now;
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setInt(
              'clipboard_last_time',
              now.millisecondsSinceEpoch,
            );
          } catch (_) {}
          return text;
        }
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
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('clipboard_last_url', url);
      await prefs.setInt(
        'clipboard_last_time',
        _lastCheckedTime!.millisecondsSinceEpoch,
      );
    } catch (e) {
      debugPrint('ClipboardService error saving prefs: $e');
    }
  }
}
