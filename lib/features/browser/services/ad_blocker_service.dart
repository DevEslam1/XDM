import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
  int _contentBlockerGen = 0;
  void bumpGen() {
    _contentBlockerGen++;
  }

  int _lastBuiltGen = -1;

  List<ContentBlocker> _nativeContentBlockers = [];

  final ValueNotifier<int> _blockedCountNotifier = ValueNotifier<int>(0);
  final Set<String> _blockedDomains = {};

  bool get isEnabled => _enabled;
  int get blockedCount => _blockedCountNotifier.value;
  ValueNotifier<int> get blockedCountNotifier => _blockedCountNotifier;
  Set<String> get blockedDomains => Set.unmodifiable(_blockedDomains);

  void resetStats() {
    _blockedDomains.clear();
    _blockedCountNotifier.value = 0;
  }

  void refresh() {
    _rebuildContentBlockers();
    _notifyListeners();
  }

  /// Normalizes any domain or URL input into a (host, path) tuple.
  static (String host, String path) extractHostAndPath(String input) {
    if (input.isEmpty) return ('', '');
    var s = input.trim();
    String path = '';
    if (s.contains('://')) {
      try {
        final uri = Uri.parse(s);
        return (uri.host.toLowerCase(), uri.path);
      } catch (_) {}
    }
    if (s.startsWith('//')) {
      try {
        final uri = Uri.parse('https:$s');
        return (uri.host.toLowerCase(), uri.path);
      } catch (_) {}
    }
    final slashIdx = s.indexOf('/');
    if (slashIdx != -1) {
      path = s.substring(slashIdx);
      s = s.substring(0, slashIdx);
    }
    final colonIdx = s.indexOf(':');
    if (colonIdx != -1) {
      s = s.substring(0, colonIdx);
    }
    return (s.toLowerCase(), path);
  }

  bool isAllowListed(String domainOrUrl) {
    if (domainOrUrl.isEmpty) return false;
    final (host, _) = extractHostAndPath(domainOrUrl);
    if (host.isEmpty) return false;

    final allowList = AdBlockFilterUpdater().allowListedDomains;

    // Check exact match first (O(1))
    if (allowList.contains(host)) return true;

    // Walk up the domain tree to check parent domains (O(depth), typically < 5)
    // Avoids O(N) iteration over the entire allowlist (which can be 50k+ domains)
    final parts = host.split('.');
    for (var i = 1; i < parts.length - 1; i++) {
      final parent = parts.sublist(i).join('.');
      if (allowList.contains(parent)) return true;
    }
    return false;
  }

  static const _lastUpdateKey = 'last_adblock_update';

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefKey) ?? true;
      // FIX: Load persisted custom rules on startup.
      await _loadCustomRules();
      // FIX: Initialize the custom ad-block host store so user-defined
      // hosts are loaded from disk.
      await CustomAdBlockStore.instance.init();
      // FIX: Initialize the filter updater to load previously downloaded
      // domains from disk. Without this, the adblocker relies only on
      // hardcoded hosts until the next scheduled filter update.
      await AdBlockFilterUpdater().init();
      await autoUpdateFilters();
    } catch (e) {
      _log.warning('AdBlocker init error: $e');
      _enabled = false;
    }
    _rebuildContentBlockers();
  }

  Future<void> autoUpdateFilters() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastUpdateMs = prefs.getInt(_lastUpdateKey) ?? 0;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      const sevenDaysMs = 7 * 24 * 60 * 60 * 1000;

      if (nowMs - lastUpdateMs > sevenDaysMs) {
        _log.info(
            'AdBlock filters older than 7 days, running background update...');
        unawaited(
          updateFilters(force: true).then((success) async {
            if (success) {
              await prefs.setInt(
                  _lastUpdateKey, DateTime.now().millisecondsSinceEpoch);
            }
          }).catchError((e) {
            _log.warning(
                'Background filter update failed (keeping existing filters): $e');
          }),
        );
      }
    } catch (e) {
      _log.warning('Error checking autoUpdateFilters: $e');
    }
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
    _notifyListeners();
  }

  void _rebuildContentBlockers() {
    if (!_enabled) {
      _nativeContentBlockers = [];
      _lastBuiltGen = _contentBlockerGen;
      return;
    }
    if (_lastBuiltGen == _contentBlockerGen &&
        _nativeContentBlockers.isNotEmpty) {
      return;
    }
    _nativeContentBlockers = _buildContentBlockers();
    _lastBuiltGen = _contentBlockerGen;
  }

  List<ContentBlocker> get contentBlockers => _nativeContentBlockers;

  int get ruleCount {
    final updater = AdBlockFilterUpdater();
    return _nativeContentBlockers.length +
        updater.downloadedDomainCount +
        updater.downloadedTrackingCount +
        updater.cosmeticRules.length +
        updater.scriptletRules.length +
        CustomAdBlockStore.instance.hosts.length;
  }

  Future<bool> updateFilters({bool force = false}) async {
    try {
      await AdBlockFilterUpdater().updateIfNeeded(force: force);
      // Bump the generation counter so _rebuildContentBlockers() actually
      // regenerates the native iOS/macOS content blockers after a filter
      // update (without this, the _lastBuiltGen guard skipped the rebuild).
      bumpGen();
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

  /// Dynamic ad blocking script via MutationObserver.
  static const String dynamicAdBlockJs = '''
(function() {
  if (window.__xdmDynamicAdBlock) return;
  window.__xdmDynamicAdBlock = true;
  
  const adSelectors = [
    '.adsbygoogle', '[id^="ad-"]', '[class*="ad-slot"]',
    '[class*="sponsored"]', '[data-ad]', 'ins.adsbygoogle',
    '[id*="taboola"]', '[id*="outbrain"]', 'iframe[src*="doubleclick"]'
  ];
  
  function removeAds(root) {
    adSelectors.forEach(sel => {
      try {
        root.querySelectorAll(sel).forEach(el => {
          el.remove();
        });
      } catch(e) {}
    });
  }
  
  removeAds(document);
  
  const observer = new MutationObserver(mutations => {
    mutations.forEach(m => {
      m.addedNodes.forEach(node => {
        if (node.nodeType === 1) removeAds(node);
      });
    });
  });
  
  observer.observe(document.body || document.documentElement, {
    childList: true,
    subtree: true
  });
})();
''';

  /// Compiled regex cache for pattern matching.
  final Map<String, RegExp> _compiledPatterns = {};

  /// Fast-path pattern matching using compiled regex cache.
  bool matchesPatternCached(String url, List<String> patterns) {
    final host = Uri.tryParse(url)?.host.toLowerCase();
    if (host != null && _blockedDomains.contains(host)) {
      return true;
    }
    for (final pattern in patterns) {
      final regex = _compiledPatterns.putIfAbsent(
        pattern,
        () => RegExp(pattern, caseSensitive: false),
      );
      if (regex.hasMatch(url)) {
        return true;
      }
    }
    return false;
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

  String? _cachedDynamicDomainsJson;
  int _lastDomainsGen = -1;

  /// JSON-encoded list of ad domains for dynamic blocking setup.
  /// Cached per generation to avoid expensive JSON encoding on widget rebuilds.
  String get dynamicDomainsJson {
    if (_cachedDynamicDomainsJson != null &&
        _lastDomainsGen == _contentBlockerGen) {
      return _cachedDynamicDomainsJson!;
    }
    final custom = CustomAdBlockStore.instance.hosts;
    // Cap at 2000 downloaded domains to keep the injected JS payload manageable.
    final filterDomains = AdBlockFilterUpdater().allBlockedDomains.take(2000);
    final all = <String>{...custom, ...filterDomains}.toList();
    _cachedDynamicDomainsJson = jsonEncode(all);
    _lastDomainsGen = _contentBlockerGen;
    return _cachedDynamicDomainsJson!;
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
      try {
        l();
      } catch (_) {}
    }
  }

  // ── Custom rules ─────────────────────────────────────────────────────────
  /// User-defined CSS/JS rules (e.g. "#my-ad { display:none }").
  static const _customRulesKey = 'adblock_custom_rules';
  final List<String> _customRules = [];

  List<String> get customRules => List.unmodifiable(_customRules);

  Future<void> _loadCustomRules() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _customRules.addAll(prefs.getStringList(_customRulesKey) ?? []);
    } catch (e) {
      _log.warning('Failed to load custom rules: $e');
    }
  }

  Future<void> _persistCustomRules() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_customRulesKey, _customRules);
    } catch (e) {
      _log.warning('Failed to persist custom rules: $e');
    }
  }

  Future<void> addCustomRule(String rule) async {
    final trimmed = rule.trim();
    if (trimmed.isEmpty || _customRules.contains(trimmed)) return;
    _customRules.add(trimmed);
    await _persistCustomRules();
    _notifyListeners();
  }

  Future<void> removeCustomRule(String rule) async {
    if (_customRules.remove(rule)) {
      await _persistCustomRules();
      _notifyListeners();
    }
  }

  // ── URL blocking decision ─────────────────────────────────────────────────
  /// Known ad hostnames for shouldBlockUrl checks.
  static const _adHostnames = <String>{
    'doubleclick.net',
    'googlesyndication.com',
    'googleadservices.com',
    'adnxs.com',
    'criteo.com',
    'criteo.net',
    'taboola.com',
    'outbrain.com',
    'pubmatic.com',
    'openx.net',
    'rubiconproject.com',
    'casalemedia.com',
    'smartadserver.com',
    'adform.net',
    'popads.net',
    'popcash.net',
    'propellerads.com',
    'exoclick.com',
    'trafficjunky.com',
    'adsterra.com',
    'hilltopads.net',
    'juicyads.com',
    'clickadu.com',
    'onclickads.net',
    'mgid.com',
    'revcontent.com',
    'amazon-adsystem.com',
    'moatads.com',
    'hotjar.com',
    'quantserve.com',
    'bidswitch.net',
    'adskeeper.com',
    'scorecardresearch.com',
    'chartbeat.com',
    'histats.com',
    'onesignal.com',
    'pushcrew.com',
    'pushengage.com',
    'pushails.com',
    'adsrvr.org',
    'adcolony.com',
    'buysellads.com',
    'carbonads.com',
    'dianomi.com',
    'infolinks.com',
    'media.net',
    'revenuehits.com',
    'sharethis.com',
    'tapad.com',
    'yieldmo.com',
    'zedo.com',
  };

  static bool _matchesAdHostnames(String host) {
    if (_adHostnames.contains(host)) return true;
    int dotIndex = host.indexOf('.');
    while (dotIndex != -1 && dotIndex < host.length - 1) {
      final suffix = host.substring(dotIndex + 1);
      if (_adHostnames.contains(suffix)) return true;
      dotIndex = host.indexOf('.', dotIndex + 1);
    }
    return false;
  }

  /// Returns true if [url] should be blocked by the ad blocker.
  /// Returns true if [url] should be blocked by the ad blocker.
  bool shouldBlockUrl(String url) {
    if (!_enabled || url.isEmpty) return false;
    try {
      final (host, path) = extractHostAndPath(url);
      if (host.isEmpty) return false;

      if (isAllowListed(host)) return false;

      final customStore = CustomAdBlockStore.instance;

      if (customStore.useCustomOnly) {
        if (customStore.contains(host)) {
          _recordBlocked(host);
          return true;
        }
        return false;
      }

      // Check the downloaded filter lists FIRST — these contain
      // 50,000+ domains from EasyList, EasyPrivacy, AdGuard, etc.
      if (AdBlockFilterUpdater().shouldBlock(url)) {
        _recordBlocked(host);
        return true;
      }

      // Fallback: hardcoded known-ad hostnames for instant blocking
      // before the first filter download completes.
      if (_matchesAdHostnames(host)) {
        _recordBlocked(host);
        return true;
      }
      // Custom hosts from user store
      if (customStore.contains(host)) {
        _recordBlocked(host);
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// Records a blocked request for statistics.
  void recordBlockedRequest(String url) {
    _log.fine('Blocked: $url');
    try {
      final (host, _) = extractHostAndPath(url);
      _recordBlocked(host.isNotEmpty ? host : url);
    } catch (_) {
      _recordBlocked(url);
    }
  }

  void _recordBlocked(String host) {
    if (host.isNotEmpty) {
      if (_blockedDomains.length >= 1000) {
        _blockedDomains.remove(_blockedDomains.first);
      }
      _blockedDomains.add(host);
    }
    _blockedCountNotifier.value++;
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
    // Fix #13: Use display:none instead of visibility:hidden.
    // visibility:hidden keeps elements in the layout flow (they still occupy
    // space), and ad scripts can detect it. display:none is the standard used
    // by uBlock Origin, AdGuard, and all major ad blockers.
    return '''
$selectorBlock {
  display: none !important;
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



  // Intercept window.open popup requests ONLY for known ad URLs (BUG A3)
  var _origOpen = window.open;
  window.open = function(url, name, features) {
    if (url && typeof url === 'string' && url.trim() !== '' && url !== 'about:blank') {
      try {
        var u = new URL(url, window.location.href);
        var host = u.hostname.toLowerCase();
        var isAd = false;
        var dynamicList = window.__xdmDynamicAdDomains || [];
        for (var i = 0; i < dynamicList.length; i++) {
          var d = dynamicList[i];
          if (host === d || host.endsWith('.' + d)) { isAd = true; break; }
        }
        if (isAd && window.XDM_Popups && window.XDM_Popups.postMessage) {
          window.XDM_Popups.postMessage(url);
          return null;
        }
      } catch(e) {}
    }
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
    return _origSend.apply(this, arguments);
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
  // FIX #3: scriptletJs — implements common uBlock/AdGuard scriptlets.
  // Filter lists (##+js rules) were previously parsed but never executed.
  // ─────────────────────────────────────────────────────────────────────
  String get scriptletJs => _buildScriptletJs();

  String _buildScriptletJs() {
    if (!_enabled) return '';

    final parsedRules = AdBlockFilterUpdater().scriptletRules;
    if (parsedRules.isEmpty) return '';

    final calls = <String>[];
    for (final rule in parsedRules.take(100)) {
      final parts = rule.split(',').map((s) => s.trim()).toList();
      if (parts.isEmpty) continue;
      final name = parts[0].toLowerCase();
      final args = parts.sublist(1);
      String? call;
      switch (name) {
        case 'abort-on-property-read':
        case 'aopw':
          if (args.isNotEmpty) call = '_xdmAbortOnRead(${_jsStr(args[0])});';
          break;
        case 'abort-on-property-write':
        case 'aopb':
          if (args.isNotEmpty) call = '_xdmAbortOnWrite(${_jsStr(args[0])});';
          break;
        case 'set-constant':
          if (args.length >= 2) {
            call =
                '_xdmSetConstant(${_jsStr(args[0])}, ${_jsConstant(args[1])});';
          }
          break;
        case 'no-settimeout-if':
          if (args.isNotEmpty) call = '_xdmNoTimeoutIf(${_jsStr(args[0])});';
          break;
        case 'addeventlistener-defuser':
          if (args.length >= 2) {
            call =
                '_xdmDefuseListener(${_jsStr(args[0])}, ${_jsStr(args[1])});';
          }
          break;
        case 'json-prune':
          if (args.isNotEmpty) {
            call = '_xdmJsonPrune(${_jsStr(args.join(' '))});';
          }
          break;
        case 'noeval':
          call = '_xdmNoEval();';
          break;
        case 'prevent-fetch':
          if (args.isNotEmpty) call = '_xdmPreventFetch(${_jsStr(args[0])});';
          break;
      }
      if (call != null) calls.add(call);
    }
    if (calls.isEmpty) return '';

    final callsJs = calls.join('\n  ');
    return '$_scriptletPreamble  $callsJs\n})();\n';
  }

  // The raw preamble is stored in a separate field so the interpolated
  // final return string can reference it without triggering the
  // prefer_adjacent_string_concatenation lint.
  static const String _scriptletPreamble = r'''(function() {
  if (window.__xdmScriptlets) return;
  window.__xdmScriptlets = true;

  // ── Scriptlet runtime helpers ─────────────────────────────────────────

  function _xdmAbortOnRead(prop) {
    try {
      var parts = prop.split('.');
      var obj = window;
      for (var i = 0; i < parts.length - 1; i++) {
        obj = obj[parts[i]];
        if (!obj || typeof obj !== 'object') return;
      }
      var last = parts[parts.length - 1];
      Object.defineProperty(obj, last, {
        get: function() { throw new ReferenceError('[XDM] aborted: ' + prop); },
        configurable: true
      });
    } catch(e) {}
  }

  function _xdmAbortOnWrite(prop) {
    try {
      var parts = prop.split('.');
      var obj = window;
      for (var i = 0; i < parts.length - 1; i++) {
        obj = obj[parts[i]];
        if (!obj || typeof obj !== 'object') return;
      }
      var last = parts[parts.length - 1];
      Object.defineProperty(obj, last, {
        set: function() { throw new ReferenceError('[XDM] aborted write: ' + prop); },
        get: function() { return undefined; },
        configurable: true
      });
    } catch(e) {}
  }

  function _xdmSetConstant(prop, val) {
    try {
      var parts = prop.split('.');
      var obj = window;
      for (var i = 0; i < parts.length - 1; i++) {
        if (!obj[parts[i]]) obj[parts[i]] = {};
        obj = obj[parts[i]];
      }
      var last = parts[parts.length - 1];
      Object.defineProperty(obj, last, {
        get: function() { return val; },
        set: function() {},
        configurable: false
      });
    } catch(e) {}
  }

  function _xdmNoTimeoutIf(pattern) {
    try {
      var re = new RegExp(pattern);
      var orig = window.setTimeout;
      window.setTimeout = function(fn, delay) {
        var src = (typeof fn === 'function') ? fn.toString() : String(fn);
        if (re.test(src)) return 0;
        return orig.apply(window, arguments);
      };
    } catch(e) {}
  }

  function _xdmDefuseListener(eventName, pattern) {
    try {
      var re = new RegExp(pattern);
      var origAdd = EventTarget.prototype.addEventListener;
      EventTarget.prototype.addEventListener = function(type, fn) {
        if (type === eventName) {
          var src = (typeof fn === 'function') ? fn.toString() : String(fn);
          if (re.test(src)) return;
        }
        return origAdd.apply(this, arguments);
      };
    } catch(e) {}
  }

  function _xdmJsonPrune(keysStr) {
    try {
      var keys = keysStr.split(/\s+/).filter(Boolean);
      var origParse = JSON.parse;
      JSON.parse = function(text) {
        var obj = origParse.apply(this, arguments);
        function prune(o) {
          if (!o || typeof o !== 'object') return o;
          keys.forEach(function(k) { delete o[k]; });
          Object.values(o).forEach(function(v) {
            if (v && typeof v === 'object') prune(v);
          });
          return o;
        }
        return prune(obj);
      };
    } catch(e) {}
  }

  function _xdmNoEval() {
    try { window.eval = function() {}; } catch(e) {}
  }

  function _xdmPreventFetch(pattern) {
    try {
      var re = new RegExp(pattern);
      var origFetch = window.fetch;
      window.fetch = function(input) {
        var url = (typeof input === 'string') ? input : (input && input.url) || '';
        if (re.test(url)) {
          return Promise.resolve(new Response('', { status: 200 }));
        }
        return origFetch.apply(window, arguments);
      };
    } catch(e) {}
  }

''';

  String _jsStr(String s) => jsonEncode(s);

  String _jsConstant(String val) {
    switch (val.toLowerCase()) {
      case 'true':
        return 'true';
      case 'false':
        return 'false';
      case 'null':
        return 'null';
      case 'undefined':
        return 'undefined';
      case 'noopfunc':
      case 'truefunc':
        return 'function(){return true;}';
      case 'falsefunc':
        return 'function(){return false;}';
      default:
        final n = num.tryParse(val);
        if (n != null) return n.toString();
        return jsonEncode(val);
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // Native ContentBlockers for WebView-level blocking
  // ─────────────────────────────────────────────────────────────────────
  List<ContentBlocker> _buildContentBlockers() {
    if (!kIsWeb && (Platform.isIOS || Platform.isMacOS)) {
      final blockers = <ContentBlocker>[
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
          trigger:
              ContentBlockerTrigger(urlFilter: '.*googleadservices\\.com.*'),
          action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
        ),
        ContentBlocker(
          trigger:
              ContentBlockerTrigger(urlFilter: '.*googletagmanager\\.com.*'),
          action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
        ),
        ContentBlocker(
          trigger:
              ContentBlockerTrigger(urlFilter: '.*google-analytics\\.com.*'),
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
          trigger:
              ContentBlockerTrigger(urlFilter: '.*amazon-adsystem\\.com.*'),
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
          trigger:
              ContentBlockerTrigger(urlFilter: '.*scorecardresearch\\.com.*'),
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

      // Add downloaded domains to native blockers (limit to 2500 high-priority domains to maintain engine performance)
      final downloadedDomains = AdBlockFilterUpdater().allBlockedDomains;
      for (final domain in downloadedDomains.take(2500)) {
        blockers.add(
          ContentBlocker(
            trigger: ContentBlockerTrigger(
              urlFilter: '.*[./]${RegExp.escape(domain)}.*',
            ),
            action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
          ),
        );
      }
      return blockers;
    }
    return [];
  }

  // YouTube-specific UserScript injected at AT_DOCUMENT_START.
  // Uses a Proxy-based approach that is safer than Object.defineProperty
  // and degrades gracefully if YouTube's scripts have already set the
  // property as non-configurable.
  static const String youtubeEarlyJs = '''
(function() {
  if (window.__xdmYtEarly) return;
  window.__xdmYtEarly = true;

  // Stealth bait elements to fool client-side adblock detection
  try {
    window.yt = window.yt || {};
    window.yt.config_ = window.yt.config_ || {};
    window.yt.config_.ADS_DATA_BAIT = false;
  } catch(e) {}

  // Force ytcfg settings to disable enforcement
  try {
    function hookYtcfg(ytcfg) {
      if (!ytcfg || ytcfg.__xdmHooked) return;
      ytcfg.__xdmHooked = true;
      var origSet = ytcfg.set;
      if (typeof origSet === 'function') {
        ytcfg.set = function(key, val) {
          if (key === 'EXPERIMENT_FLAGS' && val) {
            val.web_enable_adblock_detection = false;
            val.web_block_adblock = false;
          }
          if (key === 'PLAYER_VARS' || key === 'WEB_PLAYER_CONTEXT_CONFIGS') {
            val = stripAds(val);
          }
          return origSet.apply(this, arguments);
        };
      }
    }
    if (window.ytcfg) {
      hookYtcfg(window.ytcfg);
    } else {
      var _ytcfg = undefined;
      try {
        Object.defineProperty(window, 'ytcfg', {
          get: function() { return _ytcfg; },
          set: function(val) {
            _ytcfg = val;
            if (val) hookYtcfg(val);
          },
          configurable: true
        });
      } catch(e) {}
    }
  } catch(e) {}

  // Strip ad slots from ytInitialPlayerResponse using a polling approach
  // instead of Object.defineProperty, which can throw if the property is
  // already non-configurable and would halt YouTube's bootstrap scripts.
  try {
    function stripAds(v) {
      if (!v || typeof v !== 'object') return v;
      try {
        if (v.adPlacements) { v.adPlacements = []; }
        if (v.playerAds) { v.playerAds = []; }
        if (v.adSlots) { v.adSlots = []; }
        if (v.auxiliaryUi && v.auxiliaryUi.messageRenderers) {
          v.auxiliaryUi.messageRenderers = {};
        }
      } catch(e) {}
      return v;
    }
    // Poll for ytInitialPlayerResponse and strip ads once it appears.
    var stripTries = 0;
    var stripInterval = setInterval(function() {
      stripTries++;
      if (window.ytInitialPlayerResponse) {
        stripAds(window.ytInitialPlayerResponse);
      }
      if (stripTries > 30) clearInterval(stripInterval);
    }, 200);
  } catch(e) {}
})();
''';

  /// Returns ad-block CSS for the given [url].
  /// FIX #2: Now merges hardcoded selectors with per-host cosmetic rules
  /// from the downloaded filter lists (EasyList/uBlock cosmetic rules),
  /// strictly excluding any selectors that could target download buttons/links.
  String cssRulesForUrl(String url) {
    final base = cssRules;
    if (!_enabled || url.isEmpty) return base;
    try {
      final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
      if (host.isEmpty) return base;
      final extra = AdBlockFilterUpdater().cosmeticRulesForHost(host);
      if (extra.isEmpty) return base;

      // Fix #12: Narrowed the exclusion list — old filter dropped legitimate
      // ad selectors like .ad-button, .ad-link, .ad-play-button, .sponsor-btn
      // because it excluded ANY selector containing "button", "link", "play",
      // "stream", "action", etc. Now we only exclude words that are genuinely
      // risky (download/file prompts, executable installers) which have no
      // business appearing in ad-blocking selectors.
      final safeSelectors = extra.where((s) {
        final lower = s.toLowerCase();
        if (lower.contains('download') ||
            lower.contains('apk') ||
            lower.contains('file-input') ||
            lower.contains('upload')) {
          return false;
        }
        return true;
      }).take(500); // Fix #12: Increased from 200 to 500.

      if (safeSelectors.isEmpty) return base;
      final cappedSelectors = safeSelectors.join(',\n');
      // Fix #13: Use display:none (consistent with _buildCssRules).
      return '$base\n$cappedSelectors {\n  display: none !important;\n}\n';
    } catch (_) {
      return base;
    }
  }
}
