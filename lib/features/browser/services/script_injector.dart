import 'dart:convert';
import 'package:logging/logging.dart';
import '../../../core/services/user_script_manager.dart';
import '../../../core/services/youtube_service.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/browser_tab.dart';
import 'ad_blocker_service.dart';
import 'fingerprint_manager.dart';

/// Handles WebScript injection orchestration for the XDM browser feature.
class ScriptInjector {
  static final _log = Logger('ScriptInjector');

  static const List<String> kMediaDomains = [
    'youtube.com',
    'youtu.be',
    'vimeo.com',
    'dailymotion.com',
    'tiktok.com',
    'facebook.com',
    'instagram.com',
    'twitch.tv',
    'bilibili.com',
    'ok.ru',
    'vk.com',
    'rumble.com',
    'bitchute.com',
    'soundcloud.com',
    'mixcloud.com',
    'streamable.com',
    'mp4upload.com',
    'doodstream',
    'fembed',
    'streamtape',
    'mixdrop',
    'upstream',
    'videopress',
    'wistia',
    'sproutvideo',
    'brightcove',
    'jwplayer',
    'kaltura',
    'peertube',
  ];

  static const String kDesktopModeScript = '''
    (function() {
      try {
        var meta = document.querySelector('meta[name="viewport"]');
        if (!meta) {
          meta = document.createElement('meta');
          meta.name = 'viewport';
          document.head.appendChild(meta);
        }
        meta.content = 'width=1280, initial-scale=0.75, maximum-scale=3.0, user-scalable=yes';
      } catch(e) {}
    })();
  ''';

  static const String kTimerSpeedScript = '''
    (function() {
      if (window.__xdmTimerSpeedInjected) return;
      window.__xdmTimerSpeedInjected = true;
      var _origSetTimeout = window.setTimeout;
      var _origSetInterval = window.setInterval;
      window.setTimeout = function(fn, delay) {
        var args = Array.prototype.slice.call(arguments, 2);
        var speedupDelay = (typeof delay === 'number' && delay > 1000) ? Math.min(delay, 1000) : delay;
        return _origSetTimeout.apply(window, [fn, speedupDelay].concat(args));
      };
      window.setInterval = function(fn, delay) {
        var args = Array.prototype.slice.call(arguments, 2);
        var speedupDelay = (typeof delay === 'number' && delay > 3000) ? Math.min(delay, 3000) : delay;
        return _origSetInterval.apply(window, [fn, speedupDelay].concat(args));
      };
    })();
  ''';

  static const String kLongPressScript = '''
    (function() {
      if (window.__xdmLongPressInjected) return;
      window.__xdmLongPressInjected = true;
      var longPressTimer = null;
      var startX = 0, startY = 0;

      function getElementInfo(el) {
        var link = el.closest('a');
        var img = el.closest('img');
        var video = el.closest('video');
        var audio = el.closest('audio');
        if (link && link.href) return { type: 'link', url: link.href, text: link.innerText || '' };
        if (img && img.src) return { type: 'image', url: img.src, text: img.alt || '' };
        if (video && (video.src || video.currentSrc)) return { type: 'video', url: video.src || video.currentSrc, text: '' };
        if (audio && (audio.src || audio.currentSrc)) return { type: 'audio', url: audio.src || audio.currentSrc, text: '' };
        return null;
      }

      document.addEventListener('touchstart', function(e) {
        if (e.touches.length !== 1) return;
        var touch = e.touches[0];
        startX = touch.clientX;
        startY = touch.clientY;
        var info = getElementInfo(e.target);
        if (!info) return;

        longPressTimer = setTimeout(function() {
          if (window.XDM_LongPress && window.XDM_LongPress.postMessage) {
            window.XDM_LongPress.postMessage(JSON.stringify(info));
          }
        }, 500);
      }, { passive: true });

      document.addEventListener('touchmove', function(e) {
        if (!longPressTimer) return;
        var touch = e.touches[0];
        if (Math.abs(touch.clientX - startX) > 10 || Math.abs(touch.clientY - startY) > 10) {
          clearTimeout(longPressTimer);
          longPressTimer = null;
        }
      }, { passive: true });

      document.addEventListener('touchend', function() {
        if (longPressTimer) {
          clearTimeout(longPressTimer);
          longPressTimer = null;
        }
      }, { passive: true });
    })();
  ''';

  bool isMediaDomain(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    return kMediaDomains.any((d) => host.contains(d));
  }

  Future<void> injectTimerSpeedScript(BrowserTab tab) async {
    // No-op: do not override site timers so countdown timers run accurately
  }

  Future<void> injectLongPressScriptToTab(BrowserTab tab) async {
    try {
      await tab.controller?.evaluateJavascript(source: kLongPressScript);
    } catch (e) {
      _log.warning('[DMX Browser] Failed to inject long press script: $e');
    }
  }

  void injectDesktopModeScript(BrowserTab tab, SettingsProvider settings) {
    if (!settings.desktopMode) return;
    try {
      tab.controller?.evaluateJavascript(source: kDesktopModeScript);
    } catch (e) {
      _log.warning('[DMX Browser] Error injecting desktop script: $e');
    }
  }

  Future<void> injectCustomJsCss(
    BrowserTab tab, {
    required String customJs,
    required String customCss,
  }) async {
    if (tab.isHome) return;
    if (customJs.isNotEmpty) {
      try {
        final jsWrapper = '''
if (!window._xdmCustomJsInjected) {
  window._xdmCustomJsInjected = true;
  (function() {
$customJs
  })();
}
''';
        await tab.controller?.evaluateJavascript(source: jsWrapper);
      } catch (e) {
        _log.warning('[DMX Browser] Failed to inject custom JS: $e');
      }
    }
    if (customCss.isNotEmpty) {
      try {
        final jsonCss = jsonEncode(customCss);
        final cssWrapper = '''
(function() {
  var style = document.getElementById('xdm-custom-css');
  if (!style) {
    style = document.createElement('style');
    style.id = 'xdm-custom-css';
    document.head.appendChild(style);
  }
  style.textContent = $jsonCss;
})();
''';
        await tab.controller?.evaluateJavascript(source: cssWrapper);
      } catch (e) {
        _log.warning('[DMX Browser] Failed to inject custom CSS: $e');
      }
    }
  }

  Future<void> injectAllScripts(
    BrowserTab tab,
    String url, {
    required SettingsProvider settings,
    required AdBlockerService adBlocker,
    required String customJs,
    required String customCss,
  }) async {
    final controller = tab.controller;
    if (controller == null) return;

    final scripts = <String>[];

    // 1. Always clean up previous intervals first
    scripts.add(AdBlockerService.intervalCleanupJs);

    // 2. Scroll unblock (all pages)
    scripts.add(AdBlockerService.scrollUnblockJs);

    // 3. YouTube-specific ad skip
    if (YoutubeService.isYoutubeUrl(url)) {
      scripts.add(adBlocker.youtubeJs);
    }

    // 4. Ad blocker CSS injection
    final css = adBlocker.cssRulesForUrl(url);
    if (css.isNotEmpty) {
      scripts.add(
          'var s=document.createElement("style");s.textContent=${jsonEncode(css)};document.head.appendChild(s);');
    }

    if (adBlocker.isEnabled) {
      scripts.add(adBlocker.lateJs);
    }

    // Desktop mode script
    if (settings.desktopMode) {
      scripts.add(kDesktopModeScript);
    }

    // 5. Custom JS/CSS for this site
    if (customJs.isNotEmpty) {
      scripts.add('''
if (!window._xdmCustomJsInjected) {
  window._xdmCustomJsInjected = true;
  (function() {
$customJs
  })();
}
''');
    }
    if (customCss.isNotEmpty) {
      final jsonCss = jsonEncode(customCss);
      scripts.add('''
(function() {
  var style = document.getElementById('xdm-custom-css');
  if (!style) {
    style = document.createElement('style');
    style.id = 'xdm-custom-css';
    document.head.appendChild(style);
  }
  style.textContent = $jsonCss;
})();
''');
    }

    // 6. User scripts
    final userJs = await UserScriptManager.instance.getJsForUrl(url);
    if (userJs.isNotEmpty) scripts.add(userJs);

    // 7. Fingerprint hiding
    scripts.add(FingerprintManager.fingerprintHideJs);

    // 8. Long-press handler
    if (isMediaDomain(url)) {
      scripts.add(kLongPressScript);
    }

    if (scripts.isEmpty) return;

    // Single batched call
    try {
      await controller.evaluateJavascript(source: scripts.join('\n;\n'));
    } catch (e) {
      _log.warning('[Browser] Batched script injection failed: $e');
    }
  }
}
