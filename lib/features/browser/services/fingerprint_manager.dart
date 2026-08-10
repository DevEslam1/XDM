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
      // 1. Webdriver Stub
      Object.defineProperty(navigator, 'webdriver', {get: () => undefined});
      
      // 2. Chrome Stub
      window.chrome = { runtime: {} };
      
      // 3. Plugins & Languages
      Object.defineProperty(navigator, 'plugins', {get: () => []});
      Object.defineProperty(navigator, 'languages', {get: () => ['en-US', 'en']});
      
      // 4. Canvas Data Poisoning (BUG FP3)
      var orgGetImageData = CanvasRenderingContext2D.prototype.getImageData;
      CanvasRenderingContext2D.prototype.getImageData = function() {
        var imgData = orgGetImageData.apply(this, arguments);
        if (imgData && imgData.data && imgData.data.length >= 4) {
          var len = imgData.data.length;
          // Fix #25: Use a random delta (1 or 2) instead of a constant +1.
          // Constant +1 produced the same poisoned output every time (same input
          // → same output) so the fingerprint was still unique and stable.
          // A random delta ensures different output on each getImageData call.
          var delta = 1 + Math.floor(Math.random() * 2);
          imgData.data[len - 4] = (imgData.data[len - 4] + delta) % 256;
        }
        return imgData;
      };
      
      // 6. WebGL Vendor & Renderer Spoofing (BUG FP3)
      var orgGetParameter = WebGLRenderingContext.prototype.getParameter;
      WebGLRenderingContext.prototype.getParameter = function(p) {
        // UNMASKED_VENDOR_WEBGL
        if (p === 37445) return 'Google Inc. (Intel)';
        // UNMASKED_RENDERER_WEBGL
        if (p === 37446) return 'ANGLE (Intel, Intel(R) UHD Graphics (0x00009BC4) Direct3D11 vs_5_0 ps_5_0)';
        return orgGetParameter.apply(this, arguments);
      };
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

  /// Hides navigator.webdriver and injects window.chrome runtime stub to
  /// obscure WebView automation fingerprints.
  ///
  /// Requires a [SettingsProvider] so the caller's anti-fingerprinting
  /// preference is always respected. The nullable parameter is kept only
  /// for backward compatibility — a null value defaults to **off**.
  Future<void> hideWebViewFingerprints(BrowserTab tab,
      [SettingsProvider? settings]) async {
    // Default to OFF when no settings provider is supplied so we never
    // inject stealth JS without explicit user opt-in.
    if (settings == null || !settings.antiFingerprinting) return;
    try {
      await tab.controller?.evaluateJavascript(source: fingerprintHideJs);
    } catch (e) {
      _log.warning('Failed to inject anti-detection JS: $e');
    }
  }
}
