import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Centralised ad-blocking engine for the XDM browser.
///
/// Three layers of defence:
///   1. **Domain blocking** – ad-network requests are killed at navigation.
///   2. **CSS injection** – known ad containers are hidden via `display:none`.
///   3. **JS injection** – popups, overlays, video ads, and redirect chains
///      are neutralised at runtime.
///
/// Targets: YouTube, movie/streaming sites, mod-app/APK sites, and generic
/// ad networks.
class AdBlockerService {
  AdBlockerService._();
  static final AdBlockerService instance = AdBlockerService._();

  static const String _prefKey = 'adBlockerEnabled';
  bool _enabled = true;

  bool get isEnabled => _enabled;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefKey) ?? true;
    } catch (e) {
      debugPrint('[AdBlocker] init error: $e');
    }
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
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

    for (final domain in _blockedDomains) {
      if (lower.contains(domain)) return true;
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
  // 2. CSS INJECTION – hide ad containers
  // ─────────────────────────────────────────────────────────────────────

  /// CSS injected on every page load to hide known ad elements.
  String get cssRules => _cssRules;

  static const String _cssRules = '''
/* ═══ GENERIC AD CONTAINERS ═══ */
[class*="ad-container"], [class*="ad-wrapper"], [class*="ad-banner"],
[class*="ad-slot"], [class*="ad-unit"], [class*="ad-frame"],
[class*="ad-box"], [class*="adblock"], [class*="adsbygoogle"],
[class*="ads-container"], [class*="ads-wrapper"], [class*="ads-banner"],
[class*="advert"], [class*="advertisement"], [class*="advertising"],
[class*="sponsor"], [class*="sponsored"],
[class*="popup-ad"], [class*="pop-up"], [class*="popunder"],
[class*="interstitial"], [class*="overlay-ad"],
[class*="floating-ad"], [class*="sticky-ad"],
[class*="banner-ad"], [class*="leaderboard"],
[class*="skyscraper"], [class*="rectangle-ad"],
[class*="native-ad"], [class*="in-feed-ad"],
[id*="ad-container"], [id*="ad-wrapper"], [id*="ad-banner"],
[id*="ad-slot"], [id*="ad-unit"], [id*="adsbygoogle"],
[id*="ads-container"], [id*="advert"], [id*="advertisement"],
[id*="popup"], [id*="popunder"], [id*="interstitial"],
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
[class*="player-overlay"], [class*="video-overlay"],
[class*="preloader"], [class*="pre-roll"],
[class*="preroll"], [class*="midroll"],
[class*="countdown-overlay"], [class*="skip-ad"],
[class*="ad-overlay"], [class*="ad-layer"],
[class*="pop-overlay"], [class*="modal-ad"],
[class*="lightbox-ad"], [class*="full-page-ad"],
[class*="redirect-overlay"], [class*="click-overlay"],
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
[class*="welcome-ad"], [class*="splash-ad"],
{ display: none !important; visibility: hidden !important;
  height: 0 !important; overflow: hidden !important;
  pointer-events: none !important; }
''';

  // ─────────────────────────────────────────────────────────────────────
  // 3. JS INJECTION – runtime ad neutralisation
  // ─────────────────────────────────────────────────────────────────────

  /// JS injected at `onPageStarted` to block popups and redirect chains
  /// before the page even renders.
  String get earlyJs => _earlyJs;

  static const String _earlyJs = '''
(function() {
  if (window.__xdmAdBlockEarly) return;
  window.__xdmAdBlockEarly = true;

  /* ── Block window.open popups ── */
  window.open = function() { return null; };

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

  /* ── Block ad iframes from being created ── */
  var origCreateElement = document.createElement.bind(document);
  document.createElement = function(tag) {
    var el = origCreateElement(tag);
    if (tag.toLowerCase() === 'iframe') {
      var origSetAttr = el.setAttribute.bind(el);
      el.setAttribute = function(name, value) {
        if (name === 'src' && typeof value === 'string') {
          var v = value.toLowerCase();
          if (v.indexOf('recaptcha') !== -1 || v.indexOf('gstatic.com') !== -1) {
            origSetAttr(name, value);
            return;
          }
          var adDomains = ['doubleclick','googlesyndication','adnxs',
            'criteo','pubmatic','openx','taboola','outbrain',
            'popads','popcash','exoclick','juicyads','trafficjunky',
            'hilltopads','clickadu','adsterra','propellerads',
            'onclickads','adskeeper','mgid','revcontent'];
          for (var i = 0; i < adDomains.length; i++) {
            if (v.indexOf(adDomains[i]) !== -1) {
              return; // silently drop
            }
          }
        }
        origSetAttr(name, value);
      };
    }
    return el;
  };
})();
''';

  /// JS injected at `onPageFinished` to clean up DOM-level ads that
  /// survived CSS hiding (dynamic injection, shadow DOM, etc.).
  String get lateJs => _lateJs;

  static const String _lateJs = '''
(function() {
  if (window.__xdmAdBlockLate) return;
  window.__xdmAdBlockLate = true;

  /* ── Remove ad elements by selector ── */
  var selectors = [
    /* generic */
    '[class*="ad-container"]','[class*="ad-wrapper"]','[class*="ad-banner"]',
    '[class*="adsbygoogle"]','[class*="advert"]','[class*="advertisement"]',
    '[class*="sponsor"]','[class*="popup"]','[class*="popunder"]',
    '[class*="interstitial"]','[class*="overlay-ad"]',
    '[id*="ad-container"]','[id*="adsbygoogle"]','[id*="advert"]',
    '[id*="popup"]','[id*="popunder"]',
    /* YouTube */
    'ytd-ad-slot-renderer','ytd-promoted-sparkles-web-renderer',
    '#masthead-ad','#player-ads','.ytp-ad-module',
    '.ytp-ad-overlay-container','.ytp-ad-overlay-slot',
    'ytd-display-ad-renderer','ytd-in-feed-ad-layout-renderer',
    'ytd-promoted-video-renderer','ytd-search-pyv-renderer',
    'ytd-video-masthead-ad-v3-renderer',
    'ytd-companion-slot-renderer',
    /* streaming / movie */
    '[class*="player-overlay"]','[class*="preloader"]',
    '[class*="preroll"]','[class*="midroll"]',
    '[class*="countdown-overlay"]','[class*="ad-overlay"]',
    '[class*="pop-overlay"]','[class*="modal-ad"]',
    '[class*="redirect-overlay"]','[class*="click-overlay"]',
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
        els[j].remove();
      }
    } catch(e) {}
  }

  /* ── Remove fixed/absolute overlays covering the page ── */
  try {
    var all = document.querySelectorAll('div, section, aside');
    for (var k = 0; k < all.length; k++) {
      var el = all[k];
      var st = window.getComputedStyle(el);
      if ((st.position === 'fixed' || st.position === 'absolute') &&
          st.zIndex > 999 &&
          st.display !== 'none' &&
          el.offsetWidth > window.innerWidth * 0.5 &&
          el.offsetHeight > window.innerHeight * 0.3) {
        /* likely a full-page ad overlay */
        var text = (el.textContent || '').toLowerCase();
        if (text.indexOf('ad') !== -1 || text.indexOf('sponsor') !== -1 ||
            text.indexOf('click here') !== -1 || text.indexOf('download now') !== -1 ||
            text.indexOf('install') !== -1 || text.indexOf('subscribe') !== -1 ||
            el.querySelector('iframe') !== null) {
          el.remove();
        }
      }
    }
  } catch(e) {}

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
    document.body.style.overflow = '';
    document.documentElement.style.overflow = '';
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
})();
''';

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
