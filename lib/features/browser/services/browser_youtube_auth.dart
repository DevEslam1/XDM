import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:webview_cookie_manager/webview_cookie_manager.dart';
import '../../../core/services/youtube_service.dart';
import '../models/browser_tab.dart';

class BrowserYoutubeAuth {
  static final _cookieManager = WebviewCookieManager();
  static DateTime? _lastCheck;

  static Future<bool> extractAndSignIn() async {
    try {
      final urls = [
        'https://www.youtube.com',
        'https://accounts.google.com',
        'https://www.google.com',
      ];

      final Map<String, String> allCookies = {};

      for (final url in urls) {
        try {
          final cookies = await _cookieManager.getCookies(url);
          for (final c in cookies) {
            if (c.name.isNotEmpty && c.value.isNotEmpty) {
              allCookies[c.name] = c.value;
            }
          }
        } catch (_) {}
      }

      final hasAuthCookie = allCookies.containsKey('SID') ||
          allCookies.containsKey('HSID') ||
          allCookies.containsKey('SSID') ||
          allCookies.containsKey('APISID') ||
          allCookies.containsKey('SAPISID');

      if (!hasAuthCookie) {
        debugPrint('[YT Auth] No Google auth cookies found');
        return false;
      }

      final cookieStr = allCookies.entries
          .map((e) => '${e.key}=${e.value}')
          .join('; ');

      await YoutubeService.signIn(cookieStr);
      return YoutubeService.isSignedIn;
    } catch (e) {
      debugPrint('[YT Auth] Failed: $e');
      return false;
    }
  }

  static void watchForSignIn(BrowserTab tab, VoidCallback onSignedIn) {
    final url = tab.url;
    final isGoogleDomain = url.contains('youtube.com') ||
        url.contains('accounts.google.com') ||
        url.contains('google.com');

    if (!isGoogleDomain) return;

    final now = DateTime.now();
    if (_lastCheck != null &&
        now.difference(_lastCheck!) < const Duration(seconds: 30)) {
      return;
    }
    _lastCheck = now;

    extractAndSignIn().then((success) {
      if (success) onSignedIn();
    });
  }
}
