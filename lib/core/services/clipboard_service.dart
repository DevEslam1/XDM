import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../utils/url_utils.dart';

class ClipboardService {
  static final ClipboardService _instance = ClipboardService._internal();
  factory ClipboardService() => _instance;
  ClipboardService._internal();

  String? _lastCheckedUrl;

  /// Checks if there is a new valid HTTP/HTTPS URL on the clipboard.
  /// Returns the URL if it's new, otherwise null.
  Future<String?> checkClipboardForUrl() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();
      if (text != null && isHttpUrl(text)) {
        if (text != _lastCheckedUrl) {
          _lastCheckedUrl = text;
          return text;
        }
      }
    } catch (e) {
      // Clipboard access might fail on some platforms or permissions
      // We import foundation.dart or just print. debugPrint is preferred.
      debugPrint('ClipboardService error checking URL: $e');
    }
    return null;
  }

  /// Sets the last checked URL so we don't prompt for it again.
  void markAsChecked(String url) {
    _lastCheckedUrl = url;
  }
}
