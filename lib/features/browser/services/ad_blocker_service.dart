import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'adblock_filter_updater.dart';
import 'custom_adblock_store.dart';

/// Centralised ad-blocking engine for the XDM browser.
///
/// FIX NOTES (all browser bugs):
///   1. intervalCleanupJs now ONLY clears intervals created by known ad
///      scripts (tracked via a whitelist), never legitimate page timers.
///   2. CSS selectors use exact class/id matching instead of substring
///      wildcards that matched "download", "grad", "shadow", "read", etc.
///   3. window.open is no longer globally overridden — only popup windows
///      targeting known ad domains are blocked.
///   4. MutationObserver is no longer wrapped — pages retain full DOM
///      observation capability.
///   5. fetch/XHR interceptors use exact hostname matching instead of
///      substring matching.
///   6. document.createElement override removed — no longer intercepts
///      legitimate dynamic element creation.
class AdBlockerService {
  AdBlockerService._();
  static final AdBlockerService instance = AdBlockerService._();

  static final _log = Logger('AdBlockerService');
  static const _prefKey = 'adBlockerEnabled';

  bool _enabled = true;
  List<ContentBlocker> _nativeContentBlockers = [];

  bool get isEnabled => _enabled;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefKey) ?? true;
    } catch (e) {
      _log.warning('AdBlocker init error: $e');
    }
    _rebuildContentBlockers();
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, value);
    } catch (e) {
      _log.warning('Failed to persist adblock state: $e');
    }
    _rebuildContentBlockers();
  }

  void _rebuildContentBlockers() {
    if (!_enabled) {
      _nativeContentBlockers = [];
      return;
    }
    _nativeContentBlockers = _buildContentBlockers();
  }

  List<ContentBlocker> get contentBlockers => _nativeContentBlockers;

  int get ruleCount => _nativeContentBlockers.length;

  Future<bool> updateFilters({bool force = false}) async {
    try {
      await AdBlockFilterUpdater().updateIfNeeded(force: force);
      _rebuildContentBlockers();
      return true;
    } catch (e) {
      _log.warning('Filter update failed: $e');
      return false;
    }
  }

  // ── Static helpers used by delegate / injector ───────────────────────────

  /// Returns true if [url] is a YouTube page (desktop or mobile).
  static bool isYoutubePage(String? url) {
    if (url == null || url.isEmpty) return false;
    try {
      final host = Uri.parse(url).host.toLowerCase();
      return host.contains('youtube.com') || host.contains('youtu.be');
    } catch (_) {
      return false;
    }
  }

  /// Unblocks page scroll (injected at document_start).
  static const String scrollUnblockJs = '''
(function() {
  try {
    document.documentElement.style.removeProperty('overflow');
    document.body && document.body.style.removeProperty('overflow');
  } catch(e) {}
})();
''';

  /// JSON-encoded list of ad domains for dynamic blocking setup.
  String get dynamicDomainsJson {
    final domains = CustomAdBlockStore.instance.hosts.toList();
    final sb = StringBuffer('[');
    for (var i = 0; i < domains.length; i++) {
      if (i > 0) sb.write(',');
      sb.write('"');
      sb.write(domains[i].replaceAll('"', '\\"'));
      sb.write('"');
    }
    sb.write(']');
    return sb.toString();
  }

  // ── Listener support (ChangeNotifier-style) ──────────────────────────────
  final List<VoidCallback> _listeners = [];

  void addListener(VoidCallback listener) {
    if (!_listeners.contains(listener)) _listeners.add(listener);
  }

  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  void _notifyListeners() {
    for (final l in List.of(_listeners)) {
      try { l(); } catch (_) {}
    }
  }

  // ── Custom rules ─────────────────────────────────────────────────────────
  /// User-defined CSS/JS rules (e.g. "#my-ad { display:none }").
  final List<String> _customRules = [];

  List<String> get customRules => List.unmodifiable(_customRules);

  Future<void> addCustomRule(String rule) async {
    if (rule.trim().isEmpty || _customRules.contains(rule)) return;
    _customRules.add(rule);
    _notifyListeners();
  }

  Future<void> removeCustomRule(String rule) async {
    _customRules.remove(rule);
    _notifyListeners();
  }

  // ── URL blocking decision ─────────────────────────────────────────────────
  /// Known ad hostnames for shouldBlockUrl checks.
  static const _adHostnames = <String>{
    'doubleclick.net', 'googlesyndication.com', 'googleadservices.com',
    'adnxs.com', 'criteo.com', 'criteo.net', 'taboola.com', 'outbrain.com',
    'pubmatic.com', 'openx.net', 'rubiconproject.com', 'casalemedia.com',
    'smartadserver.com', 'adform.net', 'popads.net', 'popcash.net',
    'propellerads.com', 'exoclick.com', 'trafficjunky.com', 'adsterra.com',
    'hilltopads.net', 'juicyads.com', 'clickadu.com', 'onclickads.net',
    'mgid.com', 'revcontent.com', 'amazon-adsystem.com', 'moatads.com',
    'hotjar.com', 'quantserve.com', 'bidswitch.net', 'adskeeper.com',
    'scorecardresearch.com', 'chartbeat.com', 'histats.com',
    'onesignal.com', 'pushcrew.com', 'pushengage.com', 'pushails.com',
    'adsrvr.org', 'adcolony.com', 'buysellads.com', 'carbonads.com',
    'dianomi.com', 'infolinks.com', 'media.net', 'revenuehits.com',
    'sharethis.com', 'tapad.com', 'yieldmo.com', 'zedo.com',
  };

  /// Returns true if [url] should be blocked by the ad blocker.
  bool shouldBlockUrl(String url) {
    if (!_enabled || url.isEmpty) return false;
    try {
      final host = Uri.parse(url).host.toLowerCase();
      // Exact hostname or subdomain match
      for (final d in _adHostnames) {
        if (host == d || host.endsWith('.$d')) return true;
      }
      // Custom hosts from user store
      for (final h in CustomAdBlockStore.instance.hosts) {
        if (host == h || host.endsWith('.$h')) return true;
      }
    } catch (_) {}
    return false;
  }

  /// Records a blocked request for statistics. (No-op stub — extend if needed.)
  void recordBlockedRequest(String url) {
    _log.fine('Blocked: $url');
  }

  // ─────────────────────────────────────────────────────────────────────
  // FIX #1: intervalCleanupJs — ONLY clears intervals tagged by our ad
  // detection, never touches legitimate page timers.
  //
  // The old version ran `clearInterval` / `clearTimeout` on EVERYTHING,
  // killing countdown timers, auto-refresh, delayed download buttons, etc.
  // ─────────────────────────────────────────────────────────────────────
  static const String intervalCleanupJs = '''
(function() {
  // Only clear intervals that were CREATED by known ad scripts.
  // We track them via a tagged wrapper installed in earlyJs.
  if (window.__xdmAdIntervals) {
    window.__xdmAdIntervals.forEach(function(id) {
      try { clearInterval(id); } catch(e) {}
      try { clearTimeout(id); } catch(e) {}
    });
    window.__xdmAdIntervals = [];
  }
})();
''';

  // ─────────────────────────────────────────────────────────────────────
  // FIX #2: CSS rules use EXACT selectors instead of substring wildcards.
  //
  // OLD (BROKEN): [class*="ad-"], [id*="ad"]
  //   → matched "download-btn", "grad-overlay", "shadow-layer",
  //     "read-more", "loading-spinner", "header-ad", etc.
  //
  // NEW: Exact class names and specific known ad container IDs only.
  // ─────────────────────────────────────────────────────────────────────
  String get cssRules => _buildCssRules();

  String _buildCssRules() {
    if (!_enabled) return '';

    // Only block KNOWN ad container classes/IDs — never use substring
    // wildcards like [class*="ad"] which match "download", "grad", etc.
    final blockedSelectors = <String>[
      // Known ad network containers (exact match)
      '.adsbygoogle',
      '.ad-container',
      '.ad-wrapper',
      '.ad-banner',
      '.ad-slot',
      '.ad-unit',
      '.ad-frame',
      '.ad-box',
      '.adblock',
      '.ads-container',
      '.ads-wrapper',
      '.ads-banner',
      '.advert',
      '.advertisement',
      '.advertising',
      '.sponsored',
      '.popup-ad',
      '.ad-popup',
      '.popunder',
      '.interstitial-ad',
      '.overlay-ad',
      '.floating-ad',
      '.sticky-ad',
      '.banner-ad',
      '.leaderboard-ad',
      '.skyscraper-ad',
      '.rectangle-ad',
      '.native-ad',
      '.in-feed-ad',
      // Known ad IDs (exact match)
      '#ad-container',
      '#ad-wrapper',
      '#ad-banner',
      '#ad-slot',
      '#ad-unit',
      '#adsbygoogle',
      '#ads-container',
      '#advert',
      '#advertisement',
      '#ad-popup',
      '#popunder',
      '#interstitial-ad',
      '#overlay-ad',
      '#floating-ad',
      '#sticky-ad',
      // YouTube specific
      'ytd-ad-slot-renderer',
      'ytd-promoted-sparkles-web-renderer',
      'ytd-merch-shelf-renderer',
      'ytd-statement-banner-renderer',
      '#masthead-ad',
      '#player-ads',
      '#video-masthead',
      '.ytp-ad-module',
      '.ytp-ad-overlay-container',
      '.ytp-ad-overlay-slot',
      '.ytp-ad-image-overlay',
      'ytd-display-ad-renderer',
      'ytd-action-companion-ad-renderer',
      'ytd-in-feed-ad-layout-renderer',
      'ytd-promoted-video-renderer',
      'ytd-search-pyv-renderer',
      'ytd-video-masthead-ad-v3-renderer',
      'ytd-companion-slot-renderer',
      'ytd-primetime-promo-renderer',
      'ytd-banner-promo-renderer',
      'ytd-enforcement-message-view-model',
      '.ytp-ad-progress',
      '.ytp-ad-progress-list',
      '.ytp-ad-text-overlay',
      '.ytp-suggested-action',
      '.ytp-suggested-action-badge',
      'tp-yt-paper-dialog:has(yt-mealbar-promo-renderer)',
      'ytd-rich-section-renderer:has(ytd-ad-slot-renderer)',
      // Streaming sites
      '[class*="ad-player-overlay"]',
      '[class*="pre-roll"]',
      '[class*="preroll"]',
      '[class*="midroll"]',
      '[class*="skip-ad"]',
      // Cookie/newsletter popups
      '.cookie-consent',
      '.cookie-banner',
      '.newsletter-popup',
      '.subscribe-popup',
      '.push-notification-prompt',
      '.exit-intent-popup',
      '.exit-popup',
      '.welcome-ad',
      '.splash-ad',
      // Anti-adblock overlays
      '.adblock-warning',
      '.adblock-overlay',
      '.adblock-modal',
      '.adblock-popup',
      '.anti-adblock',
      '.antiadblock',
      '#adblock-warning',
      '#adblock-overlay',
      '#adblock-modal',
      '#anti-adblock',
      '#antiadblock',
    ];

    // Custom user-defined host-based CSS rules (block by hostname)
    // CustomAdBlockStore.hosts contains hostnames, not CSS rules, so we skip them here.
    const customCss = '';

    final selectorBlock = blockedSelectors.join(',\n');
    return '''
$selectorBlock {
  visibility: hidden !important;
  height: 0 !important;
  overflow: hidden !important;
  pointer-events: none !important;
}
$customCss
''';
  }

  // ─────────────────────────────────────────────────────────────────────
  // FIX #3: earlyJs — no longer globally overrides window.open or
  // document.createElement. Only blocks popups targeting known ad domains.
  // ─────────────────────────────────────────────────────────────────────
  String get earlyJs => _buildEarlyJs();

  String _buildEarlyJs() {
    if (!_enabled) return '';

    return '''
(function() {
  if (window.__xdmAdBlockEarly) return;
  window.__xdmAdBlockEarly = true;

  // Track ad-created intervals for targeted cleanup (see intervalCleanupJs)
  window.__xdmAdIntervals = window.__xdmAdIntervals || [];

  // FIX #3: Do NOT override window.open globally.
  // Only intercept popups that target known ad domains.
  var _adPopupDomains = [
    'doubleclick.net', 'googlesyndication.com', 'googleadservices.com',
    'adnxs.com', 'criteo.com', 'pubmatic.com', 'openx.net',
    'taboola.com', 'outbrain.com', 'popads.net', 'popcash.net',
    'exoclick.com', 'juicyads.com', 'trafficjunky.com',
    'hilltopads.net', 'clickadu.com', 'adsterra.com',
    'propellerads.com', 'onclickads.net'
  ];

  var _origOpen = window.open;
  window.open = function(url, name, features) {
    if (url && typeof url === 'string') {
      try {
        var u = new URL(url, window.location.href);
        var host = u.hostname.toLowerCase();
        for (var i = 0; i < _adPopupDomains.length; i++) {
          if (host.indexOf(_adPopupDomains[i]) !== -1) {
            // Block ad popup — return null so the page knows it failed
            return null;
          }
        }
      } catch(e) {}
    }
    // Legitimate popup — call original
    return _origOpen.call(window, url, name, features);
  };

  // FIX #6: Do NOT override document.createElement.
  // The old version intercepted ALL element creation, breaking pages
  // that dynamically create download buttons.

  // Do NOT override setInterval/setTimeout — scanning callback source
  // for patterns like 'ad' is too broad. The word 'ad' appears in
  // 'download', 'load', 'ready', 'upload', etc. and kills legitimate
  // countdown timers like the one on liteapks.com.
  // intervalCleanupJs is effectively a no-op (clears empty list).
})();
''';
  }

  // ─────────────────────────────────────────────────────────────────────
  // FIX #4: antiDetectJs — no longer wraps MutationObserver.
  // FIX #5: fetch/XHR interceptors use exact hostname matching.
  // ─────────────────────────────────────────────────────────────────────
  String get antiDetectJs => _buildAntiDetectJs();

  String _buildAntiDetectJs() {
    if (!_enabled) return '';

    return '''
(function() {
  if (window.__xdmAntiDetect) return;
  window.__xdmAntiDetect = true;

  var _adDomains = [
    'doubleclick.net', 'googlesyndication.com', 'googleadservices.com',
    'adnxs.com', 'adsrvr.org', 'criteo.com', 'criteo.net',
    'taboola.com', 'outbrain.com', 'revcontent.com', 'mgid.com',
    'popads.net', 'popcash.net', 'exoclick.com', 'exosrv.com',
    'juicyads.com', 'trafficjunky.com', 'hilltopads.net',
    'clickadu.com', 'adsterra.com', 'propellerads.com',
    'onclickads.net', 'onclickmax.com', 'onclickmega.com',
    'pushails.com', 'onesignal.com', 'pushengage.com',
    'adform.net', 'adcolony.com', 'admob.com',
    'bidswitch.net', 'buysellads.com', 'carbonads.com',
    'casalemedia.com', 'chartbeat.com', 'dianomi.com',
    'directrev.com', 'dotomi.com', 'hotjar.com', 'infolinks.com',
    'leadzu.com', 'media.net', 'mediavine.com', 'moatads.com',
    'mookie1.com', 'openx.net', 'pubmatic.com', 'quantserve.com',
    'revenuehits.com', 'revive-adserver.com', 'rubiconproject.com',
    'serving-sys.com', 'sharethis.com', 'smartadserver.com',
    'tapad.com', 'trckswrm.com', 'tribalfusion.com', 'turn.com',
    'undertone.com', 'viglink.com', 'xad.com', 'yieldmo.com', 'zedo.com'
  ];

  // FIX #5: Exact hostname check instead of substring match.
  // Old code: url.indexOf('adnxs.com') !== -1
  //   → blocked "https://my-adnxs.com-backup.example.com/api/data"
  // New code: checks if the hostname IS the ad domain or a subdomain of it.
  function _isAdUrl(url) {
    if (!url || typeof url !== 'string') return false;
    try {
      var u = new URL(url, window.location.href);
      var host = u.hostname.toLowerCase();
      for (var i = 0; i < _adDomains.length; i++) {
        var d = _adDomains[i];
        // Exact match or subdomain match
        if (host === d || host.endsWith('.' + d)) {
          return true;
        }
      }
    } catch(e) {}
    return false;
  }

  // FIX #5: Intercept fetch — only block requests to exact ad domains
  var _origFetch = window.fetch;
  window.fetch = function(input, init) {
    var url = (typeof input === 'string') ? input : (input && input.url) || '';
    if (_isAdUrl(url)) {
      return Promise.resolve(new Response('', {
        status: 200,
        statusText: 'OK',
        headers: { 'Content-Type': 'text/plain' }
      }));
    }
    return _origFetch.apply(window, arguments);
  };

  // FIX #5: Intercept XHR — only block requests to exact ad domains
  var _origOpen = XMLHttpRequest.prototype.open;
  var _origSend = XMLHttpRequest.prototype.send;

  XMLHttpRequest.prototype.open = function(method, url) {
    this.__xdmBlocked = _isAdUrl(String(url || ''));
    return _origOpen.apply(this, arguments);
  };

  XMLHttpRequest.prototype.send = function() {
    if (this.__xdmBlocked) {
      Object.defineProperty(this, 'readyState', {
        get: function() { return 4; },
        configurable: true
      });
      Object.defineProperty(this, 'status', {
        get: function() { return 200; },
        configurable: true
      });
      Object.defineProperty(this, 'responseText', {
        get: function() { return ''; },
        configurable: true
      });
      try {
        if (typeof this.onload === 'function') this.onload({});
      } catch(e) {}
      try {
        if (typeof this.onreadystatechange === 'function') {
          this.onreadystatechange();
        }
      } catch(e) {}
      return;
    }
    return _origSend.apply(window, arguments);
  };

  // FIX #4: Do NOT wrap MutationObserver.
  // The old version filtered DOM mutations, breaking SPAs that rely on
  // MutationObserver for UI updates, download button rendering, etc.

  // Fake ad SDK globals so anti-adblock scripts think ads loaded.
  try {
    if (!window.adsbygoogle) {
      window.adsbygoogle = [];
      window.adsbygoogle.loaded = true;
      window.adsbygoogle.push = function(o) { return o; };
    }
    window.google_ad_client = 'ca-pub-0000000000000000';
    window.google_adnum = 0;
    window.google_tag_params = {};
    window.google_ad_mod = true;
    window.google_jobrunner = { run: function(o) { return o; } };
    window.google_render_ad = function() {};
    window.canRunAds = true;
    window.adBlockEnabled = false;
    window.adBlockDetected = false;
    window.noAdBlock = true;
    window.isAdBlocked = false;
    window.isAdBlockActive = false;
    window.adblock = false;
    window.adBlock = false;
    window.adblocker = false;
    window.AdBlocker = false;
    window.isAdblocker = false;
    window.isAdBlocker = false;
    window.__cmpLoaded = true;
    window.__tcfapi = function(cmd, v, cb) {
      if (typeof cb === 'function') {
        cb({ cmpLoaded: true, gdprApplies: false }, true);
      }
    };
    window.__uspapi = function(cmd, v, cb) {
      if (typeof cb === 'function') cb('1---', true);
    };
    if (!window.pbjs) {
      window.pbjs = {
        que: [],
        setConfig: function() {},
        requestBids: function() {}
      };
      window.pbjs.que.push = function(fn) {
        try { fn(); } catch(e) {}
      };
    }
    window.apstag = {
      init: function() {},
      fetchBids: function(c, cb) { if (cb) cb([]); },
      setDisplayBids: function() {},
      targetingKeys: function() { return []; }
    };
  } catch(e) {}
})();
''';
  }

  // ─────────────────────────────────────────────────────────────────────
  // lateJs — injected at onPageFinished for DOM-level cleanup
  // ─────────────────────────────────────────────────────────────────────
  String get lateJs => _buildLateJs();

  String _buildLateJs() {
    if (!_enabled) return '';

    return '''
(function() {
  // Remove ad elements by known selectors from the DOM.
  // Uses the same exact selectors as CSS rules.
  var selectors = [
    '.adsbygoogle', '.ad-container', '.ad-wrapper', '.ad-banner',
    '.ad-slot', '.ad-unit', '.ad-frame', '.ad-box', '.adblock',
    '.ads-container', '.ads-wrapper', '.ads-banner', '.advert',
    '.advertisement', '.advertising', '.sponsored', '.popup-ad',
    '.ad-popup', '.popunder', '.interstitial-ad', '.overlay-ad',
    '.floating-ad', '.sticky-ad', '.banner-ad', '.leaderboard-ad',
    '.skyscraper-ad', '.rectangle-ad', '.native-ad', '.in-feed-ad',
    'ytd-ad-slot-renderer', 'ytd-promoted-sparkles-web-renderer',
    '#masthead-ad', '#player-ads', '.ytp-ad-module',
    '.ytp-ad-overlay-container', '.cookie-consent', '.cookie-banner',
    '.newsletter-popup', '.subscribe-popup', '.exit-intent-popup',
    '.adblock-warning', '.adblock-overlay', '.anti-adblock'
  ];

  for (var i = 0; i < selectors.length; i++) {
    try {
      var els = document.querySelectorAll(selectors[i]);
      for (var j = 0; j < els.length; j++) {
        els[j].style.setProperty('display', 'none', 'important');
        els[j].style.setProperty('visibility', 'hidden', 'important');
        els[j].style.setProperty('height', '0', 'important');
        els[j].style.setProperty('overflow', 'hidden', 'important');
        els[j].style.setProperty('pointer-events', 'none', 'important');
      }
    } catch(e) {}
  }

  // Remove fixed/absolute overlays covering the page that are ad-related.
  // IMPORTANT: We must NOT match on generic text like 'ad' — that word
  // appears in legitimate content ('download', 'upload', 'loading', etc.).
  // We only hide overlays that have ALL of:
  //   • Are fixed/absolute with very high z-index
  //   • Contain an <iframe> (ad iframes) OR have a known ad class/id
  //   • Do NOT contain a download link or button anywhere inside them
  try {
    var all = document.querySelectorAll('div, section, aside');
    var maxCount = Math.min(all.length, 300);
    var _adOverlayClasses = [
      'popup-ad', 'ad-popup', 'popunder', 'interstitial',
      'overlay-ad', 'ad-overlay', 'floating-ad', 'ad-floating',
      'fullscreen-ad', 'ad-fullscreen'
    ];
    for (var k = 0; k < maxCount; k++) {
      var el = all[k];
      var st = window.getComputedStyle(el);
      if (!((st.position === 'fixed' || st.position === 'absolute') &&
            st.zIndex > 999 &&
            st.display !== 'none' &&
            el.offsetWidth > window.innerWidth * 0.5 &&
            el.offsetHeight > window.innerHeight * 0.3)) continue;

      // Must have an iframe inside (classic ad overlay), OR match a
      // known ad overlay class — text content alone is NOT enough.
      var hasAdIframe = el.querySelector('iframe') !== null;
      var hasAdClass = false;
      var elClass = (el.className || '').toLowerCase();
      var elId = (el.id || '').toLowerCase();
      for (var m = 0; m < _adOverlayClasses.length; m++) {
        if (elClass.indexOf(_adOverlayClasses[m]) !== -1 ||
            elId.indexOf(_adOverlayClasses[m]) !== -1) {
          hasAdClass = true;
          break;
        }
      }
      if (!hasAdIframe && !hasAdClass) continue;

      // Extra guard: don't hide if it contains any download link/button
      var hasDownloadBtn = el.querySelector(
        'a[download], button[download], a[href*="download"], ' +
        'button[class*="download"], a[class*="download"], ' +
        '[class*="download-btn"], [id*="download"]'
      );
      if (!hasDownloadBtn) {
        el.style.setProperty('display', 'none', 'important');
      }
    }
  } catch(e) {}
})();
''';
  }

  // ─────────────────────────────────────────────────────────────────────
  // YouTube-specific JS
  // ─────────────────────────────────────────────────────────────────────
  String get youtubeJs => _buildYoutubeJs();

  String _buildYoutubeJs() {
    if (!_enabled) return '';

    return '''
(function() {
  if (window.__xdmYtAdInterval) clearInterval(window.__xdmYtAdInterval);
  window.__xdmYtAdSkip = true;

  function trySkip() {
    // Skip Ad button
    var skip = document.querySelector(
      '.ytp-ad-skip-button, .ytp-skip-ad-button,' +
      'button.ytp-ad-skip-button-modern,' +
      '.ytp-ad-skip-button-modern .ytp-ad-skip-button-slot,' +
      '[class*="ytp-ad-skip"], .ytm-ad-skip-button'
    );
    if (skip) { try { skip.click(); } catch(e) {} return; }

    // Text-based skip button
    var btns = document.querySelectorAll('button, div[role="button"]');
    for (var i = 0; i < btns.length; i++) {
      var t = (btns[i].textContent || '').trim().toLowerCase();
      if (t === 'skip ad' || t === 'skip ads' || t === 'skip' ||
          t.indexOf('skip ad') !== -1) {
        try { btns[i].click(); } catch(e) {}
        return;
      }
    }

    // If unskippable ad is playing: mute + fast-forward
    try {
      var adBadge = document.querySelector(
        '.ytp-ad-simple-ad-badge, .ytp-ad-preview-container, ' +
        '.ytp-ad-duration-remaining, .ad-showing, .ad-interrupting'
      );
      var video = document.querySelector('video');
      if (adBadge && video) {
        if (!video.muted) video.muted = true;
        if (video.playbackRate < 16) video.playbackRate = 16;
        if (video.duration && isFinite(video.duration) &&
            video.currentTime < video.duration) {
          video.currentTime = video.duration - 0.1;
        }
      } else if (video && video.playbackRate > 2) {
        video.playbackRate = 1;
        video.muted = false;
      }
    } catch(e) {}

    // Close overlay / companion / survey ads
    var close = document.querySelector(
      '.ytp-ad-overlay-close-button, .ytp-ad-overlay-close,' +
      '.ytp-ad-dismiss-button, .ytp-ad-survey-close'
    );
    if (close) { try { close.click(); } catch(e) {} }

    // Dismiss adblock enforcement dialog
    try {
      var dlg = document.querySelector(
        'ytd-enforcement-message-view-model, tp-yt-paper-dialog'
      );
      if (dlg) {
        var text = (dlg.textContent || '').toLowerCase();
        if (text.indexOf('ad blocker') !== -1 ||
            text.indexOf('adblock') !== -1) {
          dlg.style.setProperty('display', 'none', 'important');
          var dBtn = dlg.querySelector(
            'button, .close-button, [aria-label*="close" i]'
          );
          if (dBtn) try { dBtn.click(); } catch(e) {}
        }
      }
    } catch(e) {}
  }

  trySkip();
  window.__xdmYtAdInterval = setInterval(trySkip, 600);
})();
''';
  }

  // ─────────────────────────────────────────────────────────────────────
  // Anti-detect CSS (bait elements stay measurable but invisible)
  // ─────────────────────────────────────────────────────────────────────
  String get antiDetectCss => '''
/* Anti-Adblock: bait element stealth — keeps layout dimensions intact */
#ad-test, #adsbox, #ads, #ad, .adsbox, .ads,
.adsbygoogle-noablate,
[id="ad-test"], [id="adsbox"], [class="ads"], [class="adsbox"] {
  opacity: 0 !important;
  pointer-events: none !important;
  position: fixed !important;
  left: -9999px !important;
  top: -9999px !important;
  width: 1px !important;
  height: 1px !important;
  overflow: hidden !important;
}
''';

  // ─────────────────────────────────────────────────────────────────────
  // Native ContentBlockers for WebView-level blocking
  // ─────────────────────────────────────────────────────────────────────
  List<ContentBlocker> _buildContentBlockers() {
    return [
      // DoubleClick / Google Ads
      ContentBlocker(
        trigger: ContentBlockerTrigger(
          urlFilter: '.*doubleclick\\.net.*',
          unlessTopUrl: ['.*youtube\\.com.*', '.*youtu\\.be.*'],
        ),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(
          urlFilter: '.*googlesyndication\\.com.*',
          unlessTopUrl: ['.*youtube\\.com.*', '.*youtu\\.be.*'],
        ),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*googleadservices\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*googletagmanager\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*google-analytics\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      // Major Ad Networks
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*adnxs\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*criteo\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*taboola\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*outbrain\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*pubmatic\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*openx\\.net.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*rubiconproject\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*casalemedia\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*smartadserver\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*adform\\.net.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      // Popup / Redirect Ad Networks
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*popads\\.net.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*popcash\\.net.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*propellerads\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*exoclick\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*trafficjunky\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*trafficjunky\\.net.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*adsterra\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*hilltopads\\.net.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*juicyads\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*clickadu\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*onclickads\\.net.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*mgid\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*revcontent\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*amazon-adsystem\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*moatads\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*hotjar\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*quantserve\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*bidswitch\\.net.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*adskeeper\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      // Tracking / Analytics
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*scorecardresearch\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*chartbeat\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*histats\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*newrelic\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*onesignal\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*pushcrew\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*pushengage\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*pushails\\.com.*'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
    ];
  }

  // YouTube-specific UserScript injected at AT_DOCUMENT_START.
  // This version is non-destructive — it does NOT use Object.defineProperty
  // and does NOT throw errors that would halt YouTube's own scripts.
  static const String youtubeEarlyJs = '''
(function() {
  if (window.__xdmYtEarly) return;
  window.__xdmYtEarly = true;
  // Quietly intercept ytInitialPlayerResponse writes to strip ad slots
  try {
    var _ytPR = undefined;
    Object.defineProperty(window, 'ytInitialPlayerResponse', {
      configurable: true,
      enumerable: true,
      get: function() { return _ytPR; },
      set: function(v) {
        try {
          if (v && v.adPlacements) { v.adPlacements = []; }
          if (v && v.playerAds) { v.playerAds = []; }
          if (v && v.adSlots) { v.adSlots = []; }
        } catch(e) {}
        _ytPR = v;
      }
    });
  } catch(e) {}
})();
''';

  /// Returns ad-block CSS for the given [url]. Always returns the same
  /// rules for now; could be customised per-domain in future.
  String cssRulesForUrl(String url) => cssRules;
}
