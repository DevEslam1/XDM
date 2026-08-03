import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'adblock_filter_updater.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Centralised ad-blocking engine for the XDM browser.
///
/// Four layers of defence:
///   1. **Domain blocking** – ad-network requests are killed at navigation.
///   2. **CSS injection** – known ad containers are hidden via `visibility:hidden`.
///   3. **JS injection** – popups, overlays, video ads, and redirect chains
///      are neutralised at runtime.
///   4. **Anti-detect stealth** – fakes ad SDK globals, intercepts fetch/XHR,
///      wraps MutationObserver so sites cannot detect the blocker.
///
/// Targets: YouTube, movie/streaming sites, mod-app/APK sites, and generic
/// ad networks.
class AdBlockerService {
  AdBlockerService._();
  static final AdBlockerService instance = AdBlockerService._();

  List<ContentBlocker> get contentBlockers {
    final blockers = <ContentBlocker>[];
    if (!_enabled) return blockers;
    for (final domain in _compiledDomainCache) {
      if (domain.trim().isEmpty) continue;
      final escaped = RegExp.escape(domain).replaceAll(r'\.', r'\.');
      blockers.add(ContentBlocker(
        trigger: ContentBlockerTrigger(
          urlFilter: '.*$escaped.*',
          resourceType: const [
            ContentBlockerTriggerResourceType.IMAGE,
            ContentBlockerTriggerResourceType.SCRIPT,
            ContentBlockerTriggerResourceType.STYLE_SHEET,
            ContentBlockerTriggerResourceType.RAW,
          ],
        ),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ));
    }
    return blockers;
  }

  final List<VoidCallback> _listeners = [];
  void addListener(VoidCallback listener) => _listeners.add(listener);
  void removeListener(VoidCallback listener) => _listeners.remove(listener);
  void _notifyListeners() {
    for (final listener in List<VoidCallback>.from(_listeners)) {
      try {
        listener();
      } catch (e) {
        // ignore
      }
    }
  }

  static const String _prefKey = 'adBlockerEnabled';
  static const String _customRulesPrefKey = 'adBlockerCustomRules';
  bool _enabled = true;
  final List<String> _customRules = [];
  final AdBlockFilterUpdater _updater = AdBlockFilterUpdater();

  Set<String> _compiledDomainCache = {};

  bool get isEnabled => _enabled;

  String get dynamicDomainsJson {
    final subset = _compiledDomainCache.take(2000).toList();
    return jsonEncode(subset);
  }

  /// User-added cosmetic rules (e.g. from the element picker), persisted.
  List<String> get customRules => List.unmodifiable(_customRules);

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefKey) ?? true;
      _customRules
        ..clear()
        ..addAll(prefs.getStringList(_customRulesPrefKey) ?? []);
      await _updater.init();
      _refreshDomainCache();
      unawaited(_updater.updateIfNeeded().then((updated) {
        if (updated) {
          _refreshDomainCache();
          _notifyListeners();
        }
      }));
    } catch (e) {
      debugPrint('[AdBlocker] init error: $e');
    }
  }

  void _refreshDomainCache() {
    final set = <String>{};
    set.addAll(_blockedDomains);
    set.addAll(_updater.allBlockedDomains);
    set.addAll(_updater.allTrackingDomains);
    _compiledDomainCache = set;
  }

  /// Adds a user cosmetic rule (e.g. `selector { display: none !important; }`).
  Future<void> addCustomRule(String rule) async {
    final clean = rule.trim();
    if (clean.isEmpty || _customRules.contains(clean)) return;
    _customRules.add(clean);
    await _persistCustomRules();
  }

  /// Removes a user cosmetic rule.
  Future<void> removeCustomRule(String rule) async {
    if (_customRules.remove(rule)) {
      await _persistCustomRules();
    }
  }

  Future<void> _persistCustomRules() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_customRulesPrefKey, _customRules);
    } catch (e) {
      debugPrint('[AdBlocker] persist custom rules error: $e');
    }
  }

  AdBlockFilterUpdater get filterUpdater => _updater;

  int get ruleCount =>
      _blockedDomains.length +
      _updater.downloadedDomainCount +
      _updater.downloadedTrackingCount;

  Future<bool> updateFilters({bool force = true}) async {
    final res = await _updater.updateIfNeeded(force: force);
    if (res) {
      _refreshDomainCache();
      _notifyListeners();
    }
    return res;
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    _notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, value);
    } catch (e) {
      debugPrint('[AdBlocker] persist error: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // 1. DOMAIN BLOCKLIST
  // ─────────────────────────────────────────────────────────────────────

  /// Returns `true` if [url] should be blocked (ad/tracking domain).
  bool shouldBlockUrl(String url) {
    if (!_enabled) return false;
    final lower = url.toLowerCase();

    // Never block reCAPTCHA, Google authentication, or gstatic resources
    if (lower.contains('recaptcha') ||
        lower.contains('gstatic.com') ||
        lower.contains('accounts.google.com') ||
        lower.contains('google.com/recaptcha')) {
      return false;
    }

    if (_compiledDomainCache.isEmpty) {
      _refreshDomainCache();
    }

    // Extract host from URL for exact domain matching
    final normalized =
        lower.startsWith('http://') || lower.startsWith('https://')
            ? lower
            : 'https://$lower';
    final uri = Uri.tryParse(normalized);
    final host = uri?.host ?? '';
    if (host.isEmpty) {
      // Fallback to substring match if URL can't be parsed
      for (final domain in _compiledDomainCache) {
        if (lower.contains(domain)) return true;
      }
      return false;
    }

    // Fast-path subdomain walk check against compiled domain set
    var checkHost = host;
    while (checkHost.isNotEmpty) {
      if (_compiledDomainCache.contains(checkHost)) return true;
      final dotIdx = checkHost.indexOf('.');
      if (dotIdx == -1 || dotIdx == checkHost.length - 1) break;
      checkHost = checkHost.substring(dotIdx + 1);
    }

    // Check URL path patterns
    final path = Uri.tryParse(url)?.path ?? '';
    if (path.isNotEmpty) {
      for (final pattern in _updater.urlPatterns) {
        if (path.contains(pattern)) return true;
      }
    }

    return false;
  }

  static const Set<String> _blockedDomains = {
    // ── Google / DoubleClick ──
    'doubleclick.net',
    'googlesyndication.com',
    'googleadservices.com',
    'google-analytics.com',
    'googletagmanager.com',
    'googletagservices.com',
    'adservice.google.com',
    'pagead2.googlesyndication.com',
    'adclick.g.doubleclick.net',
    'googleads.g.doubleclick.net',
    'stats.g.doubleclick.net',

    // ── Major ad networks ──
    'adnxs.com',
    'adsrvr.org',
    'adform.net',
    'adcolony.com',
    'admob.com',
    'adsafeprotected.com',
    'adskeeper.com',
    'adsterra.com',
    'adthrive.com',
    'amazon-adsystem.com',
    'applovin.com',
    'bidswitch.net',
    'buysellads.com',
    'carbonads.com',
    'casalemedia.com',
    'chartbeat.com',
    'clickadu.com',
    'clickadilla.com',
    'clickaine.com',
    'clickiocdn.com',
    'criteo.com',
    'criteo.net',
    'dianomi.com',
    'directrev.com',
    'dotomi.com',
    'exoclick.com',
    'exosrv.com',
    'hilltopads.net',
    'histats.com',
    'hotjar.com',
    'infolinks.com',
    'juicyads.com',
    'leadzu.com',
    'media.net',
    'mediavine.com',
    'mgid.com',
    'moatads.com',
    'mookie1.com',
    'mybetterck.com',
    'newrelic.com',
    'onclickads.net',
    'onclickmax.com',
    'onclickmega.com',
    'onesignal.com',
    'openx.net',
    'outbrain.com',
    'popads.net',
    'popcash.net',
    'popmyads.com',
    'popunder.net',
    'popundertotal.com',
    'propellerads.com',
    'propellerclick.com',
    'pubmatic.com',
    'pushails.com',
    'pushcrew.com',
    'pushengage.com',
    'quantserve.com',
    'revcontent.com',
    'revenuehits.com',
    'revive-adserver.com',
    'rubiconproject.com',
    'serving-sys.com',
    'sharethis.com',
    'smartadserver.com',
    'taboola.com',
    'tapad.com',
    'trafficjunky.com',
    'trafficjunky.net',
    'traffichaus.com',
    'traffichunt.com',
    'trafficshop.com',
    'trckswrm.com',
    'tribalfusion.com',
    'turn.com',
    'undertone.com',
    'viglink.com',
    'xad.com',
    'yieldmo.com',
    'zedo.com',
  };

  // ─────────────────────────────────────────────────────────────────────
  // 2. CSS INJECTION – hide ad containers (stealthily)
  // ─────────────────────────────────────────────────────────────────────

  /// CSS injected on every page load to hide known ad elements.
  /// Uses `visibility:hidden` instead of `display:none` so bait elements
  /// retain their layout dimensions — avoiding JS-based detection.
  @Deprecated('Use cssRulesForUrl(url) instead')
  String get cssRules => cssRulesForUrl('');

  String cssRulesForUrl(String url) {
    String host = '';
    try {
      final uri = Uri.parse(url);
      host = uri.host;
    } catch (_) {}

    final dynamicRules = _updater.cosmeticRulesForHost(host);
    final custom = _customRules.join('\n');
    if (dynamicRules.isEmpty && custom.isEmpty) return _cssRules;
    final selectors = dynamicRules.take(2000).join(', ');
    final base =
        '$selectors { visibility: hidden !important; height: 0 !important; overflow: hidden !important; pointer-events: none !important; }';
    return custom.isEmpty ? '$_cssRules\n$base' : '$_cssRules\n$base\n$custom';
  }

  /// Anti-detect CSS: makes bait elements visually invisible but JS-measurable
  /// so `getComputedStyle` / `getBoundingClientRect` checks still see "ads".
  String get antiDetectCss => _antiDetectCss;

  static const String _antiDetectCss = '''
/* ─── XDM Anti-Adblock: bait element stealth ─── */
#ad-test, #adsbox, #ads, #ad, .adsbox, .ads, .adsbygoogle-noablate,
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

  static const String _cssRules = '''
/* ═══ GENERIC AD CONTAINERS ═══ */
[class*="ad-container"], [class*="ad-wrapper"], [class*="ad-banner"],
[class*="ad-slot"], [class*="ad-unit"], [class*="ad-frame"],
[class*="ad-box"], [class*="adblock"], [class*="adsbygoogle"],
[class*="ads-container"], [class*="ads-wrapper"], [class*="ads-banner"],
[class*="advert"], [class*="advertisement"], [class*="advertising"],
[class*="sponsor"], [class*="sponsored"],
[class*="popup-ad"], [class*="ad-popup"], [class*="popunder"],
[class*="interstitial"], [class*="overlay-ad"],
[class*="floating-ad"], [class*="sticky-ad"],
[class*="banner-ad"], [class*="leaderboard"],
[class*="skyscraper"], [class*="rectangle-ad"],
[class*="native-ad"], [class*="in-feed-ad"],
[id*="ad-container"], [id*="ad-wrapper"], [id*="ad-banner"],
[id*="ad-slot"], [id*="ad-unit"], [id*="adsbygoogle"],
[id*="ads-container"], [id*="advert"], [id*="advertisement"],
[id*="ad-popup"], [id*="popunder"], [id*="interstitial"],
[id*="overlay-ad"], [id*="floating-ad"], [id*="sticky-ad"],
iframe[src*="doubleclick"], iframe[src*="googlesyndication"],
iframe[src*="adnxs"], iframe[src*="adsrvr"], iframe[src*="criteo"],
iframe[src*="pubmatic"], iframe[src*="openx"],
iframe[src*="taboola"], iframe[src*="outbrain"],
iframe[src*="revcontent"], iframe[src*="mgid"],
iframe[src*="popads"], iframe[src*="popcash"],
iframe[src*="exoclick"], iframe[src*="juicyads"],
iframe[src*="trafficjunky"], iframe[src*="hilltopads"],
iframe[src*="clickadu"], iframe[src*="adsterra"],
iframe[src*="propellerads"], iframe[src*="onclickads"],
iframe[src*="adskeeper"], iframe[src*="dianomi"],
iframe[src*="infolinks"], iframe[src*="carbonads"],
iframe[src*="pushails"], iframe[src*="onesignal"],
iframe[src*="trckswrm"], iframe[src*="leadzu"],
/* ═══ YOUTUBE ═══ */
ytd-ad-slot-renderer, ytd-promoted-sparkles-web-renderer,
ytd-merch-shelf-renderer, ytd-statement-banner-renderer,
#masthead-ad, #player-ads, #video-masthead,
.ytp-ad-module, .ytp-ad-overlay-container,
.ytp-ad-overlay-slot, .ytp-ad-image-overlay,
ytd-display-ad-renderer, ytd-action-companion-ad-renderer,
ytd-in-feed-ad-layout-renderer,
ytd-promoted-video-renderer,
ytd-search-pyv-renderer,
ytd-video-masthead-ad-v3-renderer,
ytd-companion-slot-renderer,
ytd-primetime-promo-renderer,
ytd-rich-section-renderer:has(ytd-ad-slot-renderer),
/* ═══ MOVIE / STREAMING SITES ═══ */
[class*="ad-player-overlay"], [class*="preloader"],
[class*="pre-roll"], [class*="preroll"], [class*="midroll"],
[class*="countdown-overlay"], [class*="skip-ad"],
div[class*="ad-overlay"]:not(#page-manager):not(ytd-app),
div[class*="ad-layer"]:not(#page-manager):not(ytd-app),
div[class*="pop-overlay"]:not(#page-manager),
div[class*="modal-ad"]:not(#page-manager),
[class*="lightbox-ad"], [class*="full-page-ad"],
/* ═══ MOD-APP / APK SITES ═══ */
[class*="download-ad"], [class*="dl-ad"],
[class*="fake-download"], [class*="fake-button"],
[class*="ad-download"], [class*="sponsored-dl"],
[class*="promo-download"], [class*="ad-cta"],
[class*="redirect-btn"], [class*="ad-redirect"],
[class*="pop-redirect"], [class*="overlay-redirect"],
/* ═══ GENERIC OVERLAYS / POPUPS ═══ */
[class*="cookie-consent"], [class*="cookie-banner"],
[class*="newsletter-popup"], [class*="subscribe-popup"],
[class*="push-notification"], [class*="notification-prompt"],
[class*="exit-intent"], [class*="exit-popup"],
[class*="welcome-ad"], [class*="splash-ad"]
{ visibility: hidden !important;
  height: 0 !important;
  overflow: hidden !important;
  pointer-events: none !important; }

/* Never hide YouTube's main scroll containers */
ytd-app,
#page-manager,
ytd-browse,
ytd-watch-flexy,
html,
body {
  display: block !important;
  visibility: visible !important;
  overflow-y: auto !important;
}
''';

  // ─────────────────────────────────────────────────────────────────────
  // 3. JS INJECTION – runtime ad neutralisation
  // ─────────────────────────────────────────────────────────────────────

  /// JS injected at `onPageStarted` to block popups and redirect chains
  /// before the page even renders. Also blocks ad iframe/script creation.
  String get earlyJs => _earlyJs;

  static const String _earlyJs = '''
(function() {
  if (window.__xdmAdBlockEarly) return;
  window.__xdmAdBlockEarly = true;

  /* ── Shared ad-domain check ── */
  var _adDomains = ['doubleclick','googlesyndication','googleadservices',
    'adnxs','criteo','pubmatic','openx','taboola','outbrain',
    'popads','popcash','exoclick','juicyads','trafficjunky',
    'hilltopads','clickadu','adsterra','propellerads','onclickads',
    'adskeeper','mgid','revcontent','adform','admob','adcolony',
    'amazon-adsystem','applovin','bidswitch','casalemedia',
    'quantserve','rubiconproject','smartadserver','yieldmo','zedo'];

  function _isAdUrl(value) {
    if (!value || typeof value !== 'string') return false;
    var v = value.toLowerCase();
    if (v.indexOf('recaptcha') !== -1 || v.indexOf('gstatic.com') !== -1) return false;
    if (window.__xdmDynamicAdDomains && Array.isArray(window.__xdmDynamicAdDomains)) {
      for (var i = 0; i < window.__xdmDynamicAdDomains.length; i++) {
        if (v.indexOf(window.__xdmDynamicAdDomains[i]) !== -1) return true;
      }
    }
    for (var i = 0; i < _adDomains.length; i++) {
      if (v.indexOf(_adDomains[i]) !== -1) return true;
    }
    return false;
  }

  /* ── Route window.open popups to new tabs ── */
  window.open = function(url) {
    if (url && typeof url === 'string' && url.trim() !== '' && url !== 'about:blank') {
      try {
        if (window.XDM_Popups) {
          window.XDM_Popups.postMessage(url);
        }
      } catch(e) {}
    }
    return null;
  };

  /* ── Block alert/confirm/prompt spam ── */
  window.alert = function() {};
  window.confirm = function() { return false; };
  window.prompt = function() { return null; };

  /* ── Block beforeunload tricks (used to trap users on ad pages) ── */
  Object.defineProperty(window, 'onbeforeunload', {
    get: function() { return null; },
    set: function() {}
  });

  /* ── Neutralise ad redirect timers ── */
  var origSetTimeout = window.setTimeout;
  var origSetInterval = window.setInterval;
  window.setTimeout = function(fn, delay) {
    if (typeof fn === 'string' && /location|href|redirect|window\\.open/i.test(fn)) {
      return 0;
    }
    return origSetTimeout.call(window, fn, delay);
  };
  window.setInterval = function(fn, delay) {
    if (typeof fn === 'string' && /location|href|redirect|window\\.open/i.test(fn)) {
      return 0;
    }
    return origSetInterval.call(window, fn, delay);
  };

  /* ── Block ad iframes AND ad script tags from being created ── */
  var origCreateElement = document.createElement.bind(document);
  document.createElement = function(tag) {
    var el = origCreateElement(tag);
    var tagLower = (tag || '').toLowerCase();
    if (tagLower === 'iframe' || tagLower === 'script') {
      var origSetAttr = el.setAttribute.bind(el);
      el.setAttribute = function(name, value) {
        if (name === 'src' && _isAdUrl(value)) {
          return; // silently drop
        }
        origSetAttr(name, value);
      };
      /* Also intercept direct .src property assignment */
      Object.defineProperty(el, 'src', {
        get: function() { return el.getAttribute('src') || ''; },
        set: function(v) { if (!_isAdUrl(v)) el.setAttribute('src', v); },
        configurable: true
      });
    }
    return el;
  };
})();
''';

  /// JS injected at `onPageFinished` to clean up DOM-level ads that
  /// survived CSS hiding (dynamic injection, shadow DOM, etc.).
  /// Uses stealth hiding (visibility:hidden) instead of .remove() to avoid
  /// triggering site MutationObservers that watch for ad removal.
  String get lateJs => _lateJs;

  static const String _lateJs = '''
(function() {
  if (window.__xdmAdBlockLate) return;
  window.__xdmAdBlockLate = true;

  var isYoutube = false;
  try {
    var host = (window.location && window.location.hostname) || '';
    if (host.indexOf('youtube.com') !== -1 || host.indexOf('youtu.be') !== -1) {
      isYoutube = true;
    }
  } catch(e) {}

  /* ── Stealth-hide: keeps element in DOM so MutationObservers
     don't see removals, but element is invisible to users ── */
  function _stealthHide(el) {
    try {
      el.style.setProperty('visibility', 'hidden', 'important');
      el.style.setProperty('height', '0', 'important');
      el.style.setProperty('overflow', 'hidden', 'important');
      el.style.setProperty('pointer-events', 'none', 'important');
      el.style.setProperty('opacity', '0', 'important');
      el.style.setProperty('max-height', '0', 'important');
    } catch(e) {}
  }

  /* ── Stealth-hide ad elements by selector ── */
  var selectors = [
    /* generic */
    '[class*="ad-container"]','[class*="ad-wrapper"]','[class*="ad-banner"]',
    '[class*="adsbygoogle"]','[class*="advert"]','[class*="advertisement"]',
    '[class*="sponsor"]','[class*="popup-ad"]','[class*="ad-popup"]','[class*="popunder"]',
    '[class*="interstitial"]','[class*="overlay-ad"]',
    '[id*="ad-container"]','[id*="adsbygoogle"]','[id*="advert"]',
    '[id*="ad-popup"]','[id*="popunder"]',
    /* YouTube */
    'ytd-ad-slot-renderer','ytd-promoted-sparkles-web-renderer',
    '#masthead-ad','#player-ads','.ytp-ad-module',
    '.ytp-ad-overlay-container','.ytp-ad-overlay-slot',
    'ytd-display-ad-renderer','ytd-in-feed-ad-layout-renderer',
    'ytd-promoted-video-renderer','ytd-search-pyv-renderer',
    'ytd-video-masthead-ad-v3-renderer',
    'ytd-companion-slot-renderer',
    /* streaming / movie */
    '[class*="ad-player-overlay"]','[class*="preloader"]',
    '[class*="preroll"]','[class*="midroll"]',
    '[class*="countdown-overlay"]','[class*="ad-overlay"]',
    '[class*="pop-overlay"]','[class*="modal-ad"]',
    /* mod-app / APK */
    '[class*="fake-download"]','[class*="fake-button"]',
    '[class*="ad-download"]','[class*="redirect-btn"]',
    '[class*="pop-redirect"]','[class*="overlay-redirect"]',
    /* overlays / push prompts */
    '[class*="cookie-consent"]','[class*="newsletter-popup"]',
    '[class*="push-notification"]','[class*="exit-intent"]',
    '[class*="exit-popup"]','[class*="splash-ad"]'
  ];
  for (var i = 0; i < selectors.length; i++) {
    try {
      var els = document.querySelectorAll(selectors[i]);
      for (var j = 0; j < els.length; j++) {
        _stealthHide(els[j]);
      }
    } catch(e) {}
  }

  /* ── Stealth-hide fixed/absolute overlays covering the page ── */
  if (!isYoutube) {
    try {
      if (document.querySelectorAll('*').length <= 5000) {
        var all = document.querySelectorAll('div, section, aside');
        var maxCount = Math.min(all.length, 300);
        for (var k = 0; k < maxCount; k++) {
          var el = all[k];
          var st = window.getComputedStyle(el);
          if ((st.position === 'fixed' || st.position === 'absolute') &&
              st.zIndex > 999 &&
              st.display !== 'none' &&
              el.offsetWidth > window.innerWidth * 0.5 &&
              el.offsetHeight > window.innerHeight * 0.3) {
            var text = (el.textContent || '').toLowerCase();
            if (text.indexOf('ad') !== -1 || text.indexOf('sponsor') !== -1 ||
                text.indexOf('click here') !== -1 || text.indexOf('download now') !== -1 ||
                text.indexOf('install') !== -1 ||
                el.querySelector('iframe') !== null) {
              _stealthHide(el);
            }
          }
        }
      }
    } catch(e) {}
  }

  /* ── YouTube: skip video ads ── */
  try {
    var skipBtn = document.querySelector('.ytp-ad-skip-button, .ytp-skip-ad-button, button[class*="skip"]');
    if (skipBtn) skipBtn.click();
    /* auto-skip on mutation */
    var observer = new MutationObserver(function() {
      var btn = document.querySelector('.ytp-ad-skip-button, .ytp-skip-ad-button');
      if (btn) btn.click();
      /* dismiss overlay ads */
      var overlay = document.querySelector('.ytp-ad-overlay-close-button, .ytp-ad-overlay-close');
      if (overlay) overlay.click();
    });
    observer.observe(document.body, { childList: true, subtree: true });
  } catch(e) {}

  /* ── Unblock page scroll (ad overlays often set overflow:hidden) ── */
  try {
    if (window.getComputedStyle(document.body).overflow === 'hidden') {
      document.body.style.setProperty('overflow', 'auto', 'important');
      document.body.style.setProperty('overflow-y', 'scroll', 'important');
    }
    if (window.getComputedStyle(document.documentElement).overflow === 'hidden') {
      document.documentElement.style.setProperty('overflow', 'auto', 'important');
      document.documentElement.style.setProperty('overflow-y', 'scroll', 'important');
    }
    // Also fix YouTube-specific scroll containers
    var ytdApp = document.querySelector('ytd-app, #page-manager, ytd-browse');
    if (ytdApp) {
      var st = window.getComputedStyle(ytdApp);
      if (st.overflow === 'hidden' || st.overflowY === 'hidden') {
        ytdApp.style.setProperty('overflow', 'auto', 'important');
        ytdApp.style.setProperty('overflow-y', 'auto', 'important');
      }
    }
  } catch(e) {}
})();
''';

  /// YouTube-specific JS to auto-skip pre-roll / mid-roll video ads.
  /// Injected only on `youtube.com` / `youtu.be` pages.
  String get youtubeJs => _youtubeJs;

  static const String _youtubeJs = '''
(function() {
  if (window.__xdmYtAdSkip) return;
  window.__xdmYtAdSkip = true;

  function trySkip() {
    /* "Skip Ad" button */
    var skip = document.querySelector(
      '.ytp-ad-skip-button, .ytp-skip-ad-button, ' +
      'button.ytp-ad-skip-button-modern, ' +
      '[class*="ytp-ad-skip"]'
    );
    if (skip) { skip.click(); return; }

    /* "Skip" text button (newer UI) */
    var btns = document.querySelectorAll('button');
    for (var i = 0; i < btns.length; i++) {
      var t = (btns[i].textContent || '').trim().toLowerCase();
      if (t === 'skip ad' || t === 'skip' || t.indexOf('skip ad') !== -1) {
        btns[i].click();
        return;
      }
    }

    /* Dismiss overlay / companion ads */
    var close = document.querySelector(
      '.ytp-ad-overlay-close-button, .ytp-ad-overlay-close, ' +
      '.ytp-ad-dismiss-button'
    );
    if (close) close.click();
  }

  /* Poll every 500 ms while an ad is playing */
  var adCheck = setInterval(function() {
    try {
      var adState = document.querySelector('.ad-showing, .ad-interrupting');
      if (adState) trySkip();
    } catch(e) {}
  }, 500);

  /* Also react to DOM changes */
  try {
    new MutationObserver(trySkip).observe(document.body, {
      childList: true, subtree: true
    });
  } catch(e) {}

  /* ── Restore YouTube page scroll ── */
  try {
    // Fix body/html overflow
    if (window.getComputedStyle(document.body).overflow === 'hidden') {
      document.body.style.setProperty('overflow', 'auto', 'important');
      document.body.style.setProperty('overflow-y', 'scroll', 'important');
    }
    if (window.getComputedStyle(document.documentElement).overflow === 'hidden') {
      document.documentElement.style.setProperty('overflow', 'auto', 'important');
    }
    // Fix ytd-app scroll container
    var scrollContainers = document.querySelectorAll(
      'ytd-app, #page-manager, ytd-browse, ytd-watch-flexy, .html5-video-container'
    );
    for (var i = 0; i < scrollContainers.length; i++) {
      var el = scrollContainers[i];
      var cs = window.getComputedStyle(el);
      if (cs.overflow === 'hidden' || cs.overflowY === 'hidden') {
        el.style.setProperty('overflow-y', 'auto', 'important');
      }
    }
    // Ensure html element allows scroll
    document.documentElement.style.setProperty('overflow-y', 'auto', 'important');
  } catch(e) {}

  // Run periodically since YouTube dynamically changes overflow
  var scrollFixInterval = setInterval(function() {
    try {
      if (document.body && window.getComputedStyle(document.body).overflow === 'hidden') {
        document.body.style.setProperty('overflow', 'auto', 'important');
      }
    } catch(e) {}
  }, 3000);
})();
''';

  // ─────────────────────────────────────────────────────────────────────
  // 4. ANTI-DETECT STEALTH LAYER
  // ─────────────────────────────────────────────────────────────────────

  /// Anti-detect JS: fakes ad SDK globals, intercepts fetch/XHR/MO,
  /// and neutralises bait elements.
  String get antiDetectJs {
    final base = _antiDetectJs;
    final scriptlets = _updater.scriptletRules;
    if (scriptlets.isEmpty) return base;

    const iifeEnd = '})();';
    final idx = base.lastIndexOf(iifeEnd);
    final sb = StringBuffer();
    if (idx != -1) {
      sb.write(base.substring(0, idx));
      sb.writeln('  /* ════ SCRIPTLETS ════ */');
      for (final s in scriptlets) {
        if (s.contains('set-constant')) {
          final parts = s.split(',');
          if (parts.length >= 3) {
            final target = parts[1].trim();
            final value = parts[2].trim();
            sb.writeln('  try { window.$target = $value; } catch(e) {}');
          }
        }
      }
      sb.write(iifeEnd);
      return sb.toString();
    }

    sb.write(base);
    sb.writeln('\n  /* ════ SCRIPTLETS ════ */');
    for (final s in scriptlets) {
      if (s.contains('set-constant')) {
        final parts = s.split(',');
        if (parts.length >= 3) {
          final target = parts[1].trim();
          final value = parts[2].trim();
          sb.writeln('  try { window.$target = $value; } catch(e) {}');
        }
      }
    }
    return sb.toString();
  }

  // ignore: prefer_single_quotes
  static const String _antiDetectJs = r"""
(function() {
  if (window.__xdmAntiDetect) return;
  window.__xdmAntiDetect = true;

  /* ════ A. FAKE AD SDK GLOBALS ════
     Sites check these to confirm "ads loaded ok". */
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
    window.google_jobrunner = { run: function(o){ return o; } };
    window.google_render_ad = function(){};
    window.canRunAds = true;
    window.adBlockEnabled = false;
    window.adBlockDetected = false;
    window.noAdBlock = true;
    window.isAdBlocked = false;
    window.__cmpLoaded = true;
    window.__tcfapi = function(cmd, v, cb) {
      if (typeof cb === 'function') cb({ cmpLoaded: true, gdprApplies: false }, true);
    };
    window.__uspapi = function(cmd, v, cb) {
      if (typeof cb === 'function') cb('1---', true);
    };
    if (!window.pbjs) {
      window.pbjs = { que: [], setConfig: function(){}, requestBids: function(){} };
      window.pbjs.que.push = function(fn) { try { fn(); } catch(e) {} };
    }
    window.apstag = {
      init: function(){}, fetchBids: function(c, cb) { if (cb) cb([]); },
      setDisplayBids: function(){}, targetingKeys: function(){ return []; }
    };
    /* Stub common anti-adblock library flags */
    window._0x2649 = function(){ return true; }; // used by some obfuscated detectors
  } catch(e) {}

  /* ════ B. INTERCEPT fetch() TO AD DOMAINS ════
     Returns empty 200 so detector scripts think the ad loaded. */
  try {
    var _adDF = ['doubleclick','googlesyndication','googleadservices',
      'adnxs','criteo','pubmatic','openx','taboola','outbrain',
      'popads','popcash','exoclick','juicyads','trafficjunky',
      'hilltopads','clickadu','adsterra','propellerads','onclickads',
      'adskeeper','mgid','revcontent','adform','admob','adcolony',
      'amazon-adsystem','applovin','bidswitch','casalemedia',
      'quantserve','rubiconproject','smartadserver','yieldmo','zedo',
      'moatads','hotjar','/ads/','prebid','googletag'];
    function _isAD(url) {
      if (!url || typeof url !== 'string') return false;
      var u = url.toLowerCase();
      if (u.indexOf('recaptcha') !== -1 || u.indexOf('gstatic.com') !== -1 ||
          u.indexOf('accounts.google.com') !== -1) return false;
      if (window.__xdmDynamicAdDomains && Array.isArray(window.__xdmDynamicAdDomains)) {
        for (var i = 0; i < window.__xdmDynamicAdDomains.length; i++) {
          if (u.indexOf(window.__xdmDynamicAdDomains[i]) !== -1) return true;
        }
      }
      for (var i = 0; i < _adDF.length; i++) { if (u.indexOf(_adDF[i]) !== -1) return true; }
      return false;
    }
    var _origFetch = window.fetch;
    window.fetch = function(input, init) {
      var url = (typeof input === 'string') ? input : (input && input.url) || '';
      if (_isAD(url)) {
        return Promise.resolve(new Response('', {
          status: 200, statusText: 'OK',
          headers: { 'Content-Type': 'text/plain' }
        }));
      }
      return _origFetch.apply(this, arguments);
    };
    var _origOpen = XMLHttpRequest.prototype.open;
    var _origSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function(method, url) {
      this.__xdmBlocked = _isAD(String(url || ''));
      return _origOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function() {
      if (this.__xdmBlocked) {
        Object.defineProperty(this, 'readyState',   { get: function() { return 4; }, configurable: true });
        Object.defineProperty(this, 'status',       { get: function() { return 200; }, configurable: true });
        Object.defineProperty(this, 'responseText', { get: function() { return ''; }, configurable: true });
        try { if (typeof this.onload === 'function') this.onload({}); } catch(e) {}
        try { if (typeof this.onreadystatechange === 'function') this.onreadystatechange(); } catch(e) {}
        return;
      }
      return _origSend.apply(this, arguments);
    };
  } catch(e) {}

  /* ════ C. NEUTRALISE BAIT-ELEMENT DETECTION ════
     Sites inject a <div class="ad-banner"> then check
     getComputedStyle().display or offsetHeight. */
  try {
    var _bait = ['adsbox','ad-banner','ads','ad-test','banner-ad',
      'advertising','ad-slot','advert','sponsored-ad','native-ad'];
    function _isBait(el) {
      if (!el || !el.getAttribute) return false;
      var cls = (el.getAttribute('class') || '').toLowerCase();
      var id  = (el.getAttribute('id')    || '').toLowerCase();
      for (var i = 0; i < _bait.length; i++) {
        if (cls.indexOf(_bait[i]) !== -1 || id.indexOf(_bait[i]) !== -1) return true;
      }
      return false;
    }
    var _origGCS = window.getComputedStyle;
    window.getComputedStyle = function(el, pseudo) {
      var style = _origGCS.call(window, el, pseudo);
      if (_isBait(el)) {
        return new Proxy(style, {
          get: function(target, prop) {
            if (prop === 'display')    return 'block';
            if (prop === 'visibility') return 'visible';
            if (prop === 'height')     return '1px';
            if (prop === 'width')      return '1px';
            if (prop === 'opacity')    return '1';
            var val = target[prop];
            return (typeof val === 'function') ? val.bind(target) : val;
          }
        });
      }
      return style;
    };
    /* Also patch offsetHeight/Width and getBoundingClientRect */
    var _patchProp = function(proto, prop, val) {
      var desc = Object.getOwnPropertyDescriptor(proto, prop);
      Object.defineProperty(proto, prop, {
        get: function() {
          if (_isBait(this)) return val;
          return desc.get.call(this);
        },
        configurable: true
      });
    };
    _patchProp(Element.prototype, 'offsetHeight', 1);
    _patchProp(Element.prototype, 'offsetWidth',  1);
    var _origGBR = Element.prototype.getBoundingClientRect;
    Element.prototype.getBoundingClientRect = function() {
      var rect = _origGBR.call(this);
      if (_isBait(this)) {
        return {
          top: 0, left: 0, right: 1, bottom: 1,
          width: 1, height: 1, x: 0, y: 0,
          toJSON: function() { return this; }
        };
      }
      return rect;
    };
  } catch(e) {}

  /* ════ D. WRAP MutationObserver ════
     Swallows mutations on ad-related elements so sites
     cannot detect that our lateJs hid them. */
  try {
    var _OrigMO = window.MutationObserver;
    window.MutationObserver = function(callback) {
      var _wrapped = function(mutations, observer) {
        var adTerms = ['ad-','ads-','advert','sponsor','popup-ad','popunder',
          'overlay-ad','interstitial','ad-slot','adsbygoogle','adsbox'];
        var filtered = mutations.filter(function(m) {
          var target = m.target;
          if (!target || !target.getAttribute) return true;
          var cls = (target.getAttribute('class') || '').toLowerCase();
          var id  = (target.getAttribute('id')    || '').toLowerCase();
          for (var i = 0; i < adTerms.length; i++) {
            if (cls.indexOf(adTerms[i]) !== -1 || id.indexOf(adTerms[i]) !== -1) return false;
          }
          return true;
        });
        if (filtered.length > 0) { try { callback(filtered, observer); } catch(e) {} }
      };
      return new _OrigMO(_wrapped);
    };
    MutationObserver.prototype = _OrigMO.prototype;
  } catch(e) {}

  /* ════ E. PATCH Performance.getEntries() ════
     Removes ad-domain resource entries so sites cannot
     detect blocked requests via PerformanceResourceTiming. */
  try {
    var _adDP = ['doubleclick','googlesyndication','adnxs',
      'criteo','pubmatic','openx','taboola','popads','exoclick',
      'trafficjunky','adsterra','propellerads','mgid'];
    function _filterP(entries) {
      return entries.filter(function(e) {
        var n = (e.name || '').toLowerCase();
        for (var i = 0; i < _adDP.length; i++) { if (n.indexOf(_adDP[i]) !== -1) return false; }
        return true;
      });
    }
    var _pGE   = performance.getEntries.bind(performance);
    var _pGET  = performance.getEntriesByType.bind(performance);
    var _pGEN  = performance.getEntriesByName.bind(performance);
    performance.getEntries       = function() { return _filterP(_pGE()); };
    performance.getEntriesByType = function(t) { return _filterP(_pGET(t)); };
    performance.getEntriesByName = function(n, t) { return _filterP(_pGEN(n, t)); };
  } catch(e) {}

  /* ════ F. NEUTRALISE ANTI-ADBLOCK LIBRARIES ════
     NOP known detector variables (BlockAdBlock, FuckAdBlock, etc.) */
  try {
    var _fakeABD = {
      onDetected:    function() { return _fakeABD; },
      onNotDetected: function(fn) { try { fn(); } catch(e) {} return _fakeABD; },
      check:         function() { return _fakeABD; }
    };
    var _abNames = ['blockAdBlock','BlockAdBlock','fuckAdBlock','FuckAdBlock',
      'adBlockDetector','adblock','AdBlock','adBlocker','AdBlocker',
      'AdBlockerDetector','antiAdBlock','AntiAdBlock'];
    for (var i = 0; i < _abNames.length; i++) {
      try {
        Object.defineProperty(window, _abNames[i], {
          get: function() { return _fakeABD; },
          set: function() {},
          configurable: true
        });
      } catch(e) {}
    }
    /* Stub googletag (GPT) used by publishers to detect blocked ads */
    if (!window.googletag) {
      window.googletag = {
        cmd: [],
        defineSlot: function() { return { addService: function() { return this; } }; },
        pubads:     function() { return { enableSingleRequest: function(){}, refresh: function(){}, addEventListener: function(){} }; },
        enableServices: function(){},
        display:    function(){}
      };
      window.googletag.cmd.push = function(fn) { try { fn(); } catch(e) {} };
    }
  } catch(e) {}

  /* ════ G. STEALTH navigator.serviceWorker ════
     Prevents sites from using service workers to probe
     adblock state or bypass blockers. */
  try {
    if (navigator.serviceWorker) {
      var _origRegister = navigator.serviceWorker.register.bind(navigator.serviceWorker);
      navigator.serviceWorker.register = function(url, options) {
        if (_isAD(String(url || ''))) {
          return Promise.reject(new Error('ServiceWorker registration blocked by XDM'));
        }
        return _origRegister(url, options);
      };
    }
  } catch(e) {}

})();
""";

  // ─────────────────────────────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────────────────────────────

  /// Whether the given URL is a YouTube page (for targeted YT ad-skip JS).
  static bool isYoutubePage(String url) {
    final lower = url.toLowerCase();
    return lower.contains('youtube.com') ||
        lower.contains('youtu.be') ||
        lower.contains('youtube-nocookie.com');
  }

  /// Whether the given URL is a known movie/streaming site.
  static bool isStreamingSite(String url) {
    final lower = url.toLowerCase();
    const streamingDomains = [
      'fmovies',
      '123movies',
      'solarmovie',
      'putlocker',
      'gomovies',
      'lookmovie',
      'soap2day',
      'yesmovies',
      'moviesjoy',
      'flixtor',
      'popcornflix',
      'tubi',
      'crackle',
      'vudu',
      'peacock',
      'pluto.tv',
      'streamlord',
      'movie4k',
      'hdmovies',
      'watchseries',
    ];
    return streamingDomains.any((d) => lower.contains(d));
  }

  /// Whether the given URL is a known mod-app / APK site.
  static bool isModAppSite(String url) {
    final lower = url.toLowerCase();
    const modDomains = [
      'moddroid',
      'happyapk',
      'apkpure',
      'apkmody',
      'rexdl',
      'an1.com',
      'apkdone',
      'modapk',
      'apkmod',
      'revdl',
      'android1',
      'apkcombo',
      'uptodown',
      'aptoide',
      'getmodsapk',
      'apkfolks',
      'modapkdown',
      'apkmodget',
    ];
    return modDomains.any((d) => lower.contains(d));
  }
}
