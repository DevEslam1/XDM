import 'dart:convert';

import '../models/browser_tab.dart';
import 'ad_blocker_service.dart';

/// Thin delegate around [AdBlockerService] used by the browser screen.
///
/// Owns the block decision and the ad-blocking script/CSS injection so the
/// screen only wires WebView callbacks to it (REFACTOR B extraction from
/// `_BrowserScreenState`).
class AdBlockerDelegate {
  AdBlockerDelegate({AdBlockerService? service})
    : _adBlocker = service ?? AdBlockerService.instance;

  final AdBlockerService _adBlocker;

  bool get isEnabled => _adBlocker.isEnabled;

  Future<void> init() => _adBlocker.init();

  Future<void> setEnabled(bool value) => _adBlocker.setEnabled(value);

  Future<void> toggle() => _adBlocker.setEnabled(!_adBlocker.isEnabled);

  /// Whether a navigation/resource request to [url] should be blocked.
  /// Always false while the blocker is disabled.
  bool shouldBlock(String url) =>
      _adBlocker.isEnabled && _adBlocker.shouldBlockUrl(url);

  /// Injects the early-phase blocking script (call from `onPageStarted`).
  void injectEarly(BrowserTab tab) {
    if (!_adBlocker.isEnabled) return;
    tab.controller.runJavaScript(_adBlocker.earlyJs).catchError((_) {});
  }

  /// Injects cosmetic CSS + late-phase scripts (call from `onPageFinished`).
  void injectInto(BrowserTab tab) {
    if (!_adBlocker.isEnabled) return;
    final url = tab.url;

    final cssJson = jsonEncode(_adBlocker.cssRules);
    tab.controller
        .runJavaScript('''
      (function() {
        var s = document.getElementById('xdm-adblock-css');
        if (!s) {
          s = document.createElement('style');
          s.id = 'xdm-adblock-css';
          document.head.appendChild(s);
        }
        s.textContent = $cssJson;
      })();
    ''')
        .catchError((_) {});

    tab.controller.runJavaScript(_adBlocker.lateJs).catchError((_) {});

    if (AdBlockerService.isYoutubePage(url)) {
      tab.controller.runJavaScript(_adBlocker.youtubeJs).catchError((_) {});
    }
  }
}
