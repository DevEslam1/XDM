import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/browser_tab.dart';

/// Manages User-Agent spoofing and WebView fingerprint obfuscation
/// for the XDM browser feature.
class FingerprintManager {
  static final _log = Logger('FingerprintManager');

  static const String desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static const String mobileUserAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP1A.240505.005) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

  static const String incognitoUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
      'Mobile/15E148 Safari/604.1';

  static const String fingerprintHideJs = r'''
    try {
      Object.defineProperty(navigator, 'webdriver', {get: () => undefined});
      window.chrome = { runtime: {} };
    } catch(e) {}
  ''';

  /// Resolves the appropriate User-Agent string based on tab mode and settings.
  String resolveUserAgent({
    required bool isIncognito,
    required SettingsProvider settings,
  }) {
    if (settings.desktopMode) return desktopUserAgent;
    if (isIncognito) return incognitoUserAgent;
    if (settings.customUserAgent.isNotEmpty) return settings.customUserAgent;
    return mobileUserAgent;
  }

  /// Applies the resolved User-Agent to [tab]'s WebViewController settings.
  Future<void> applyUserAgent(
    BrowserTab tab,
    SettingsProvider settings,
  ) async {
    try {
      await tab.controller?.setSettings(
        settings: InAppWebViewSettings(
          userAgent: resolveUserAgent(
            isIncognito: tab.isIncognito,
            settings: settings,
          ),
          incognito: tab.isIncognito,
        ),
      );
    } catch (e) {
      _log.warning('[DMX Browser] UA apply failed for tab ${tab.id}: $e');
    }
  }

  /// Hides navigator.webdriver and injects window.chrome runtime stub to obscure WebView automation fingerprints.
  Future<void> hideWebViewFingerprints(BrowserTab tab,
      [SettingsProvider? settings]) async {
    if (settings != null && !settings.antiFingerprinting) return;
    try {
      await tab.controller?.evaluateJavascript(source: fingerprintHideJs);
    } catch (e) {
      _log.warning('Failed to inject anti-detection JS: $e');
    }
  }
}
