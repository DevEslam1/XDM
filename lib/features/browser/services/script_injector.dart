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

  /// High-quality, smart Dark Mode CSS engine for non-native WebView rendering or CSS injection.
  static String buildForceDarkCss() => '''
    :root {
      color-scheme: dark !important;
    }
    html {
      filter: invert(0.92) hue-rotate(180deg) !important;
      background-color: #121212 !important;
    }
    /* Preserve natural appearance of multimedia, embedded objects, canvases and photos */
    img, video, iframe, canvas, svg, picture, [style*="background-image"] {
      filter: invert(1.08) hue-rotate(180deg) !important;
    }
    /* Darken scrollbars */
    ::-webkit-scrollbar {
      background-color: #1a1a1a !important;
      color: #b2b2b2 !important;
    }
    ::-webkit-scrollbar-thumb {
      background-color: #333333 !important;
    }
  ''';

  /// CSS that hides all `<img>` and `<picture>` elements (image blocking).
  static String buildBlockImagesCss() => '''
    img, picture { display: none !important; }
  ''';

  /// Injects saved form data (from SharedPreferences) into inputs that match
  /// the stored field name or id on page load.
  static String buildAutofillScript(Map<String, String> fields) {
    if (fields.isEmpty) return '';
    final buf = StringBuffer()
      ..writeln('(function() {')
      ..writeln('  function xdmFill() {')
      ..writeln('    var data = ${jsonEncode(fields)};')
      ..writeln(
          '    document.querySelectorAll("input, textarea").forEach(function(el) {')
      ..writeln('      if (el.disabled || el.readOnly) return;')
      ..writeln('      var name = (el.name || el.id || "").toLowerCase();')
      ..writeln('      var hit = null;')
      ..writeln('      Object.keys(data).forEach(function(k) {')
      ..writeln('        if (k.toLowerCase() === name) hit = data[k];')
      ..writeln('      });')
      ..writeln('      if (hit == null) return;')
      ..writeln('      var tag = el.tagName.toLowerCase();')
      ..writeln('      if (tag === "textarea") { el.value = hit; }')
      ..writeln(
          '      else if (el.type === "email" || el.type === "text" || el.type === "tel" || el.type === "url" || el.type === "search" || el.type === "password") { el.value = hit; }')
      ..writeln('      else return;')
      ..writeln(
          '      el.dispatchEvent(new Event("input", { bubbles: true }));')
      ..writeln(
          '      el.dispatchEvent(new Event("change", { bubbles: true }));')
      ..writeln('    });')
      ..writeln('  }')
      ..writeln('  if (document.readyState === "loading") {')
      ..writeln('    document.addEventListener("DOMContentLoaded", xdmFill);')
      ..writeln('  } else { xdmFill(); }')
      ..writeln('  setTimeout(xdmFill, 1500);')
      ..writeln('})();');
    return buf.toString();
  }

  /// Captures submitted form values and posts them to the XDM_Autofill
  /// handler so the app can persist them for the current host.
  static const String kAutofillCaptureScript = '''
    (function() {
      if (window.__xdmAutofillCaptureInjected) return;
      window.__xdmAutofillCaptureInjected = true;
      document.addEventListener('submit', function(e) {
        try {
          var form = e.target;
          var fields = {};
          Array.prototype.slice.call(form.querySelectorAll('input, textarea, select')).forEach(function(el) {
            var name = el.name || el.id;
            if (!name) return;
            var val = '';
            if (el.type === 'checkbox') val = el.checked ? 'true' : 'false';
            else if (el.tagName === 'SELECT') val = el.options[el.selectedIndex] ? el.options[el.selectedIndex].value : '';
            else val = el.value || '';
            if (val.length > 0) fields[name] = val;
          });
          var keys = Object.keys(fields);
          if (keys.length > 0 && window.XDM_Autofill && window.XDM_Autofill.postMessage) {
            window.XDM_Autofill.postMessage(JSON.stringify({ url: window.location.href, fields: fields }));
          }
        } catch (err) {}
      }, true);
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

      var LONG_PRESS_MS = 480;
      var FIRE_AFTER_CANCEL_MS = 430;
      var MOVE_TOLERANCE = 12;

      var longPressTimer = null;
      var pressStartTime = 0;
      var startX = 0, startY = 0;
      var pressedInfo = null;

      function nowMs() {
        return (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
      }

      function resolveInfo(el) {
        try {
          if (!el || el.nodeType !== 1) el = null;
          if (el) {
            var link = el.closest('a[href]');
            var img = el.closest('img');
            var video = el.closest('video');
            var audio = el.closest('audio');
            var source = el.closest('source[src]');
            if (link && link.href) return { type: 'link', url: link.href, text: (link.innerText || '').trim() };
            if (img) return { type: 'image', url: img.currentSrc || img.src || '', text: img.alt || '' };
            if (video) return { type: 'video', url: video.currentSrc || video.src || '', text: '' };
            if (audio) return { type: 'audio', url: audio.currentSrc || audio.src || '', text: '' };
            if (source && source.src) {
              var parent = source.parentNode;
              if (parent && parent.tagName === 'VIDEO') return { type: 'video', url: source.src, text: '' };
              if (parent && parent.tagName === 'AUDIO') return { type: 'audio', url: source.src, text: '' };
            }
          }
        } catch (e) {}
        return null;
      }

      function elementAtPoint(x, y) {
        try {
          var el = document.elementFromPoint(x, y);
          return (el && el.nodeType === 1) ? el : null;
        } catch (e) { return null; }
      }

      function rememberPoint(x, y) {
        try { window.__xdmLastTouch = { x: x, y: y }; } catch (e) {}
      }

      function postLongPress() {
        if (!pressedInfo) return;
        var info = pressedInfo;
        clearLongPress();
        try {
          if (window.XDM_LongPress && window.XDM_LongPress.postMessage) {
            window.XDM_LongPress.postMessage(JSON.stringify(info));
          }
        } catch (e) {}
      }

      function clearLongPress() {
        if (longPressTimer) {
          clearTimeout(longPressTimer);
          longPressTimer = null;
        }
        pressedInfo = null;
        pressStartTime = 0;
      }

      function beginLongPress(clientX, clientY, target) {
        clearLongPress();
        rememberPoint(clientX, clientY);
        startX = clientX;
        startY = clientY;
        var info = resolveInfo(target);
        if (!info && typeof clientX === 'number' && typeof clientY === 'number') {
          info = resolveInfo(elementAtPoint(clientX, clientY));
        }
        if (!info) return;
        pressedInfo = info;
        pressStartTime = nowMs();
        longPressTimer = setTimeout(postLongPress, LONG_PRESS_MS);
      }

      function endLongPress() {
        // Android fires touchcancel when the OS begins its own long-press
        // (text selection / ACTION_MODE). If the press was already long enough,
        // treat the cancel as a valid long press and fire immediately.
        if (longPressTimer) {
          if (pressStartTime > 0 && nowMs() - pressStartTime >= FIRE_AFTER_CANCEL_MS) {
            postLongPress();
            return;
          }
        }
        clearLongPress();
      }

      function moveLongPress(clientX, clientY) {
        if (!longPressTimer) return;
        if (Math.abs(clientX - startX) > MOVE_TOLERANCE || Math.abs(clientY - startY) > MOVE_TOLERANCE) {
          clearLongPress();
        }
      }

      document.addEventListener('touchstart', function(e) {
        if (!e.touches || e.touches.length !== 1) return;
        var t = e.touches[0];
        beginLongPress(t.clientX, t.clientY, e.target);
      }, { passive: true });

      document.addEventListener('touchmove', function(e) {
        if (!e.touches || !e.touches.length) return;
        var t = e.touches[0];
        moveLongPress(t.clientX, t.clientY);
      }, { passive: true });

      document.addEventListener('touchend', endLongPress, { passive: true });
      document.addEventListener('touchcancel', endLongPress, { passive: true });

      document.addEventListener('mousedown', function(e) {
        if (e.button !== 2) return;
        beginLongPress(e.clientX, e.clientY, e.target);
      }, { passive: true });

      document.addEventListener('mousemove', function(e) {
        moveLongPress(e.clientX, e.clientY);
      }, { passive: true });

      document.addEventListener('mouseup', endLongPress, { passive: true });
      document.addEventListener('contextmenu', endLongPress, { passive: true });
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
      tab.controller
          ?.evaluateJavascript(source: kDesktopModeScript)
          .catchError((e) {
        _log.warning('[DMX Browser] Error injecting desktop script: $e');
        return null;
      });
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

    // FIX: intervalCleanupJs now only clears AD-tagged intervals,
    // never legitimate page timers. Safe to run first.
    scripts.add(AdBlockerService.intervalCleanupJs);

    // Dynamic ad blocker MutationObserver
    scripts.add(AdBlockerService.dynamicAdBlockJs);

    // Scroll unblock (all pages)
    scripts.add(AdBlockerService.scrollUnblockJs);

    // YouTube-specific ad skip
    if (YoutubeService.isYoutubeUrl(url)) {
      scripts.add(AdBlockerService.youtubeEarlyJs);
    }

    // Ad blocker CSS injection
    final css = adBlocker.cssRulesForUrl(url);
    if (css.isNotEmpty) {
      scripts.add(
        'var s=document.createElement("style");'
        's.textContent=${jsonEncode(css)};'
        'document.head.appendChild(s);',
      );
    }

    if (adBlocker.isEnabled) {
      scripts.add(adBlocker.scriptletJs);
    }

    // Desktop mode script
    if (settings.desktopMode) {
      scripts.add(kDesktopModeScript);
    }

    // Force-dark CSS fallback (non-Android); Android uses the native
    // `forceDark` WebView setting instead. Enabled whenever the dedicated
    // force-dark switch is on.
    if (settings.forceDarkMode) {
      final css = buildForceDarkCss();
      scripts.add('(function() {'
          '  var s = document.getElementById("xdm-force-dark");'
          '  if (!s) {'
          '    s = document.createElement("style");'
          '    s.id = "xdm-force-dark";'
          '    document.head.appendChild(s);'
          '  }'
          '  s.textContent = ${jsonEncode(css)};'
          '})();');
    }

    // Image blocking
    if (settings.blockImages) {
      final css = buildBlockImagesCss();
      scripts.add('(function() {'
          '  var s = document.createElement("style");'
          '  s.textContent = ${jsonEncode(css)};'
          '  document.head.appendChild(s);'
          '})();');
    }

    // Form autofill capture (always safe; gated by the app-side handler)
    scripts.add(kAutofillCaptureScript);

    // Custom JS/CSS for this site
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

    // User scripts
    final userJs = await UserScriptManager.instance.getJsForUrl(url);
    if (userJs.isNotEmpty) scripts.add(userJs);

    // Fingerprint hiding (only when the user has opted in)
    if (settings.antiFingerprinting) {
      scripts.add(FingerprintManager.fingerprintHideJs);
    }

    // Long-press handler (all pages; guarded against double-injection
    // by the __xdmLongPressInjected flag).
    scripts.add(kLongPressScript);

    if (scripts.isEmpty) return;

    final safeScripts = scripts.map((s) => '''
try {
$s
} catch(e) {
  console.warn('[DMX Script Injection Error]', e);
}
''').join('\n;\n');

    try {
      await controller.evaluateJavascript(source: safeScripts);
    } catch (e) {
      _log.warning('[Browser] Batched script injection failed: $e');
    }
  }
}
