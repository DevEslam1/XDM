import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/browser_tab.dart';
import 'ad_blocker_service.dart';
import 'package:logging/logging.dart';

/// Thin delegate around [AdBlockerService] used by the browser screen.
///
/// Owns the block decision and the ad-blocking script/CSS injection so the
/// screen only wires WebView callbacks to it (REFACTOR B extraction from
/// `_BrowserScreenState`).
///
/// Injection order per page load:
///   1. `injectAntiDetect` — stealth layer (called first at onPageStarted)
///   2. `injectEarly`      — popup/redirect blocker + iframe/script blocker
///   3. *page renders*
///   4. `injectInto`       — CSS hiding + late DOM cleanup + YouTube skipper
class AdBlockerDelegate {
  AdBlockerDelegate({AdBlockerService? service})
      : _adBlocker = service ?? AdBlockerService.instance;

  final AdBlockerService _adBlocker;
  static final _log = Logger('ad_blocker_delegate');

  bool get isEnabled => _adBlocker.isEnabled;

  List<String> get customRules => _adBlocker.customRules;

  List<ContentBlocker> get contentBlockers => _adBlocker.contentBlockers;

  String get dynamicDomainsJson => _adBlocker.dynamicDomainsJson;

  void addListener(VoidCallback listener) => _adBlocker.addListener(listener);
  void removeListener(VoidCallback listener) => _adBlocker.removeListener(listener);

  Future<void> init() => _adBlocker.init();

  Future<void> setEnabled(bool value) => _adBlocker.setEnabled(value);

  Future<void> addCustomRule(String rule) => _adBlocker.addCustomRule(rule);

  Future<void> removeCustomRule(String rule) =>
      _adBlocker.removeCustomRule(rule);

  Future<void> toggle() => _adBlocker.setEnabled(!_adBlocker.isEnabled);

  /// Whether a navigation/resource request to [url] should be blocked.
  /// Always false while the blocker is disabled.
  bool shouldBlock(String url) =>
      _adBlocker.isEnabled && _adBlocker.shouldBlockUrl(url);

  /// Injects the stealth anti-detection layer — must be called **first**,
  /// before `injectEarly`, so fake ad globals are defined before any page
  /// script runs.
  void injectAntiDetect(BrowserTab tab) {
    if (!_adBlocker.isEnabled) return;
    
    final setupScript = 'window.__xdmDynamicAdDomains = ${_adBlocker.dynamicDomainsJson};';

    // Anti-detect JS: fakes ad SDK globals, intercepts fetch/XHR/MO
    tab.controller?.evaluateJavascript(source: '$setupScript\n${_adBlocker.antiDetectJs}').catchError((e, st) =>
        _log.warning('[ad_blocker_delegate] antiDetectJs failed', e, st));

    // Anti-detect CSS: keeps bait elements measurable but invisible.
    // Retries until <head> exists (it may not yet at onPageStarted).
    final cssJson = jsonEncode(_adBlocker.antiDetectCss);
    tab.controller?.evaluateJavascript(source: '''
      (function() {
        var css = $cssJson;
        var applied = false;
        function apply() {
          if (applied) return;
          var s = document.getElementById('xdm-antidetect-css');
          if (!s) {
            s = document.createElement('style');
            s.id = 'xdm-antidetect-css';
            if (document.head) document.head.appendChild(s);
          }
          if (s.parentNode) {
            if (s.textContent !== css) s.textContent = css;
            applied = true;
          }
        }
        apply();
        if (!applied) {
          var tries = 0;
          var timer = setInterval(function() {
            tries++;
            if (applied || tries > 250) { clearInterval(timer); return; }
            apply();
          }, 20);
        }
      })();
    ''').catchError((e,
            st) =>
        _log.warning('[ad_blocker_delegate] antiDetectCss failed', e, st));
  }

  /// Injects the early-phase blocking script (call from `onPageStarted`).
  /// Always call `injectAntiDetect` before this.
  void injectEarly(BrowserTab tab) {
    if (!_adBlocker.isEnabled) return;
    final setupScript = 'window.__xdmDynamicAdDomains = ${_adBlocker.dynamicDomainsJson};';
    tab.controller?.evaluateJavascript(source: '$setupScript\n${_adBlocker.earlyJs}').catchError(
        (e, st) => _log.warning('[ad_blocker_delegate] earlyJs failed', e, st));
  }

  String cssRulesForUrl(String url) => _adBlocker.cssRulesForUrl(url);

  /// Injects cosmetic CSS + late-phase scripts (call from `onPageFinished`).
  void injectInto(BrowserTab tab) {
    if (!_adBlocker.isEnabled) return;
    final url = tab.url;

    final cssJson = jsonEncode(cssRulesForUrl(url));
    tab.controller?.evaluateJavascript(source: '''
      (function() {
        var s = document.getElementById('xdm-adblock-css');
        if (!s) {
          s = document.createElement('style');
          s.id = 'xdm-adblock-css';
          document.head.appendChild(s);
        }
        s.textContent = $cssJson;
      })();
    ''').catchError((e,
            st) =>
        _log.warning('[ad_blocker_delegate] CSS failed', e, st));

    tab.controller?.evaluateJavascript(source: _adBlocker.lateJs).catchError(
        (e, st) => _log.warning('[ad_blocker_delegate] lateJs failed', e, st));

    if (AdBlockerService.isYoutubePage(url)) {
      tab.controller?.evaluateJavascript(source: _adBlocker.youtubeJs).catchError((e, st) =>
          _log.warning('[ad_blocker_delegate] youtubeJs failed', e, st));
    }
  }
}
