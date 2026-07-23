import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../utils/url_utils.dart';

class ClipboardService {
  static final ClipboardService _instance = ClipboardService._internal();
  factory ClipboardService() => _instance;
  ClipboardService._internal();

  String? _lastCheckedUrl;
  DateTime? _lastCheckedTime;
  static const Duration _urlTtl = Duration(minutes: 30);

  /// Checks if there is a new valid HTTP/HTTPS URL on the clipboard.
  /// Returns the URL if it's new (or if the last check was >30 minutes ago),
  /// otherwise null.
  Future<String?> checkClipboardForUrl() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();
      if (text != null && isHttpUrl(text)) {
        if (text != _lastCheckedUrl) {
          _lastCheckedUrl = text;
          _lastCheckedTime = DateTime.now();
          return text;
        }
        final now = DateTime.now();
        if (_lastCheckedTime == null ||
            now.difference(_lastCheckedTime!) > _urlTtl) {
          _lastCheckedTime = now;
          return text;
        }
      }
    } catch (e) {
      debugPrint('ClipboardService error checking URL: $e');
    }
    return null;
  }

  /// Sets the last checked URL so we don't prompt for it again.
  void markAsChecked(String url) {
    _lastCheckedUrl = url;
    _lastCheckedTime = DateTime.now();
  }
}
