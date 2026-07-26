import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class AdBlocker {
  static final Set<String> _blockedDomains = {};
  static final List<RegExp> _blockedPatterns = [];
  static bool _initialized = false;

  static const List<String> _allowedDomains = [
    'google.com',
    'www.google.com',
    'accounts.google.com',
    'gstatic.com',
    'www.gstatic.com',
    'googleapis.com',
    'googleusercontent.com',
    'google-analytics.com',
    'drive.google.com',
    'docs.google.com',
    'play.google.com',
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'music.youtube.com',
    'youtu.be',
    'googlevideo.com',
    'ytimg.com',
    'yt3.ggpht.com',
  ];

  static const List<String> _allowedUrlPatterns = [
    '/youtubei/v1/',
    '/player?',
    '/watch?v=',
    '/embed/',
    'accounts.google.com',
    'gstatic.com',
    'googleapis.com',
  ];

  // Well-known, high-quality, mobile-optimized hosts lists
  static const List<String> hostsSources = [
    'https://adaway.org/hosts.txt',
    'https://v.firebog.net/hosts/AdguardDNS.txt',
    'https://v.firebog.net/hosts/Easyprivacy.txt',
  ];

  static const List<String> _allowedDomainSuffixes = [
    '.google.com',
    '.gstatic.com',
    '.googleapis.com',
    '.googleusercontent.com',
    '.googlevideo.com',
    '.ytimg.com',
    '.ggpht.com',
    '.youtube.com',
  ];

  // Check if URL belongs to YouTube or its CDNs — always allowed
  static bool _isAllowedUrl(String url) {
    final host = _extractHost(url);
    if (host.isEmpty) return false;
    for (final domain in _allowedDomains) {
      if (host == domain || host.endsWith('.$domain')) return true;
    }
    for (final suffix in _allowedDomainSuffixes) {
      if (host == suffix.substring(1) || host.endsWith(suffix)) return true;
    }
    final lower = url.toLowerCase();
    for (final pattern in _allowedUrlPatterns) {
      if (lower.contains(pattern)) return true;
    }
    return false;
  }

  static const List<String> _fallbackDomains = [
    'doubleclick.net',
    'googlesyndication.com',
    'googleadservices.com',
    'adservice.google.com',
    'adnxs.com',
    'adsrvr.org',
    'amazon-adsystem.com',
    'criteo.com',
    'criteo.net',
    'outbrain.com',
    'taboola.com',
    'pubmatic.com',
    'rubiconproject.com',
    'openx.net',
    'indexexchange.com',
    'adsafeprotected.com',
    'moatads.com',
    'scorecardresearch.com',
    'quantserve.com',
    'zedo.com',
    'yieldmo.com',
    'adform.net',
    'adcolony.com',
    'admob.com',
    'adsymptotic.com',
    'airpush.com',
    'applovin.com',
    'chartbeat.com',
    'google-analytics.com',
    'googletagmanager.com',
    'googletagservices.com',
    'hotjar.com',
    'mixpanel.com',
    'newrelic.com',
    'segment.io',
    'sentry.io',
    'sharethrough.com',
    'smartadserver.com',
    'snap.licdn.com',
    'static.ads-twitter.com',
    'tracking.facebook.com',
    'connect.facebook.net',
  ];

  static const List<String> _adUrlPatterns = [
    '/ads/',
    '/adsbygoogle',
    '/banner',
    '/popup',
    'affiliate',
    'tracker.php',
    'tracking.php',
    'click.php',
  ];

  static Future<void>? _initFuture;
  static bool _isUpdating = false;
  static Timer? _periodicTimer;

  /// Asynchronously loads local hosts from cache file or triggers background download.
  /// Pass [forceUpdate] = true on the very first app launch to always download
  /// fresh filters even if a cache file exists from a previous install.
  static Future<void> initialize({bool forceUpdate = false}) {
    _initFuture ??= _initializeInternal(forceUpdate: forceUpdate);
    return _initFuture!;
  }

  /// Allows the app to cancel the periodic timer on shutdown.
  static void dispose() {
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }

  static Future<void> _initializeInternal({bool forceUpdate = false}) async {
    if (_initialized) return;
    _invalidateCache();

    // Load defaults immediately as fallback
    _blockedDomains.addAll(_fallbackDomains);

    try {
      final file = await _getHostsFile();

      // On first-ever app launch (forceUpdate) OR when no cached file exists,
      // download fresh filters immediately. updateHosts() populates both the
      // in-memory sets and the cache file, so we skip the redundant cache load.
      if (forceUpdate || !await file.exists()) {
        debugPrint('AdBlocker: ${forceUpdate ? "First-launch — forcing" : "No cache found — starting"} filter download...');
        try {
          await updateHosts();
        } catch (e) {
          debugPrint('AdBlocker initial download failed (will retry via autoUpdateHosts): $e');
        }
      }

      // If the download above succeeded, _blockedDomains already has fresh data
      // and loading from cache would be redundant. Only load from cache when
      // we still only have fallback domains.
      if (_blockedDomains.length <= _fallbackDomains.length && await file.exists()) {
        final filePath = file.path;
        final result = await compute(_loadAndParseHostsFile, filePath);
        final domains = result['domains'] as Set<String>;
        final patterns = (result['patterns'] as List).cast<String>();
        _blockedDomains.addAll(domains);
        _blockedPatterns.addAll(patterns.map((p) => RegExp(p)));
        debugPrint('AdBlocker loaded ${domains.length} custom domains and ${patterns.length} regex patterns from local cache.');
      }
    } catch (e) {
      debugPrint('AdBlocker initialization error: $e');
    } finally {
      _initialized = true;
    }

    // Automatically check for stale cache (>24h) and update in background.
    // This ensures filters stay fresh without requiring manual action or
    // waiting for the user to open the browser tab.
    // ignore: unawaited_futures
    autoUpdateHosts();

    // Periodic check every hour so filters stay fresh even in long sessions.
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(const Duration(hours: 1), (_) {
      // ignore: unawaited_futures
      autoUpdateHosts();
    });
  }

  static Map<String, dynamic> _loadAndParseHostsFile(String filePath) {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return {'domains': <String>{}, 'patterns': <String>[]};
      final content = file.readAsStringSync();
      final result = _parseHostsWithPatterns(content);
      _precomputeParentDomains(result['domains'] as Set<String>);
      return result;
    } catch (_) {
      return {'domains': <String>{}, 'patterns': <String>[]};
    }
  }

  /// Downloads fresh lists, parses domains, updates memory list, and caches to disk
  static Future<void> updateHosts() async {
    if (_isUpdating) return;
    _isUpdating = true;
    try {
      final dio = Dio();
      final Set<String> newDomains = {};
      final List<String> newPatterns = [];

      for (final source in hostsSources) {
        try {
          final response = await dio.get<String>(
            source,
            options: Options(
              responseType: ResponseType.plain,
              validateStatus: (_) => true,
            ),
          );
          if (response.data != null) {
            final result = _parseHostsWithPatterns(response.data!);
            final domains = result['domains'] as Set<String>;
            final patterns = (result['patterns'] as List).cast<String>();
            newDomains.addAll(domains);
            newPatterns.addAll(patterns);
            debugPrint('AdBlocker: Downloaded ${domains.length} domains and ${patterns.length} patterns from $source');
          }
        } catch (e) {
          debugPrint('AdBlocker: Error downloading hosts from $source: $e');
        }
      }

      dio.close();

      if (newDomains.isNotEmpty) {
        _invalidateCache();
        _precomputeParentDomains(newDomains);
        final updated = <String>{..._fallbackDomains, ...newDomains};
        _blockedDomains
          ..clear()
          ..addAll(updated);
        _blockedPatterns
          ..clear()
          ..addAll(newPatterns.map((p) => RegExp(p)));

        try {
          final file = await _getHostsFile();
          final lines = <String>[
            ...newDomains,
            ...newPatterns.map((p) => '/$p/'),
          ];
          await file.writeAsString(lines.join('\n'));
          debugPrint('AdBlocker: Successfully saved ${_blockedDomains.length} total domains and ${_blockedPatterns.length} patterns.');
        } catch (e) {
          debugPrint('AdBlocker: Error caching hosts to file: $e');
        }
      }
    } finally {
      _isUpdating = false;
    }
  }

  /// Automatically updates hosts if the cached file is older than 24 hours
  static Future<void> autoUpdateHosts({bool force = false}) async {
    try {
      final file = await _getHostsFile();
      if (!await file.exists()) {
        debugPrint('AdBlocker: No cached hosts file found. Updating...');
        await updateHosts();
        return;
      }
      if (force) {
        debugPrint('AdBlocker: Force update requested. Updating...');
        await updateHosts();
        return;
      }
      final lastModified = await file.lastModified();
      final difference = DateTime.now().difference(lastModified);
      if (difference.inHours >= 24) {
        debugPrint('AdBlocker: Cached hosts list is older than 24 hours ($difference). Auto-updating...');
        await updateHosts();
      } else {
        debugPrint('AdBlocker: Cached hosts list is fresh ($difference old). Skipping auto-update.');
      }
    } catch (e) {
      debugPrint('AdBlocker: Error in auto-updating hosts: $e');
      await updateHosts();
    }
  }

  static Map<String, dynamic> _parseHostsWithPatterns(String content) {
    final Set<String> domains = {};
    final List<String> patterns = [];
    final lines = content.split('\n');

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('!') || line.startsWith('//')) {
        continue;
      }

      // Handle adblock-style regex rules: /pattern/
      if (line.startsWith('/') && line.endsWith('/') && line.length > 2) {
        try {
          RegExp(line.substring(1, line.length - 1));
          patterns.add(line.substring(1, line.length - 1));
        } catch (_) {}
        continue;
      }

      // Handle standard hosts layout (e.g. "0.0.0.0 ads.doubleclick.net") or raw domains
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        final domain = parts[1].trim();
        if (_isValidDomain(domain)) {
          domains.add(domain.toLowerCase());
        }
      } else if (parts.length == 1) {
        final domain = parts[0].trim();
        if (_isValidDomain(domain)) {
          domains.add(domain.toLowerCase());
        }
      }
    }
    return {'domains': domains, 'patterns': patterns};
  }

  /// Pre-computes parent domains so runtime lookup is O(1) per URL.
  /// For example, if "sub.example.com" is blocked, also adds "example.com".
  static void _precomputeParentDomains(Set<String> domains) {
    final parents = <String>{};
    for (final domain in domains) {
      var parts = domain.split('.');
      while (parts.length >= 3) {
        parts.removeAt(0);
        parents.add(parts.join('.'));
      }
    }
    domains.addAll(parents);
  }

  static bool _isValidDomain(String domain) {
    if (domain.isEmpty || domain.contains('#') || domain == 'localhost' || domain == '127.0.0.1' || domain == '0.0.0.0') {
      return false;
    }
    return RegExp(r'^[a-zA-Z0-9][-a-zA-Z0-9.]*\.[a-zA-Z]{2,}$').hasMatch(domain);
  }

  static Future<File> _getHostsFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/adblock_hosts.txt');
  }

  /// Extracts the host and runs a domain suffix lookup (e.g. sub.domain.com -> domain.com)
  /// NOTE: [initialize] should be awaited before calling this. If not yet
  /// initialized, the check is skipped rather than mutating state.
  static bool shouldBlock(String url) {
    if (!_initialized) {
      // Use a local check against fallback domains only (no mutation)
      final host = _extractHost(url.toLowerCase());
      if (host.isEmpty) return false;
      for (final domain in _fallbackDomains) {
        if (host == domain || host.endsWith('.$domain')) return true;
      }
      return false;
    }

    // 0. Always allow YouTube domains and API paths
    if (_isAllowedUrl(url)) return false;

    final lower = url.toLowerCase();

    // Check specific path-based blocks
    if (lower.contains('twitter.com/i/adsct') || lower.contains('facebook.com/tr')) {
      return true;
    }

    // 1. Fast match against common URL patterns
    for (final pattern in _adUrlPatterns) {
      if (lower.contains(pattern)) return true;
    }

    // Specific check for /ad/ /ads/ to avoid false positives (e.g. /admin/, /advice/)
    if (RegExp(r'([/.])ads?([/._?=-]|\d)').hasMatch(lower)) {
      return true;
    }

    // 2. Regex pattern check (for adblock-style patterns)
    for (final pattern in _blockedPatterns) {
      if (pattern.hasMatch(lower)) return true;
    }

    // 3. Extract host domain
    final host = _extractHost(lower);
    if (host.isEmpty) return false;

    // 4. O(1) direct domain lookup (parent domains are pre-computed)
    if (_blockedDomains.contains(host)) return true;

    // 5. Fallback: parent domain scan (for entries not yet pre-computed)
    var parts = host.split('.');
    while (parts.length >= 3) {
      parts.removeAt(0);
      if (_blockedDomains.contains(parts.join('.'))) return true;
    }

    return false;
  }

  static String _extractHost(String url) {
    var cleanUrl = url.trim().toLowerCase();
    if (cleanUrl.startsWith('//')) {
      cleanUrl = 'https:$cleanUrl';
    } else if (!cleanUrl.startsWith('http://') && !cleanUrl.startsWith('https://')) {
      cleanUrl = 'https://$cleanUrl';
    }
    try {
      final uri = Uri.tryParse(cleanUrl);
      if (uri != null && uri.host.isNotEmpty) {
        return uri.host;
      }
    } catch (_) {}

    try {
      var host = cleanUrl.replaceFirst(RegExp(r'^https?://'), '');
      final slashIndex = host.indexOf('/');
      if (slashIndex != -1) {
        host = host.substring(0, slashIndex);
      }
      final colonIndex = host.indexOf(':');
      if (colonIndex != -1) {
        host = host.substring(0, colonIndex);
      }
      return host;
    } catch (_) {}

    return '';
  }

  static String? _cachedAdBlockScript;

  /// Invalidates the cached script so the next access rebuilds it.
  static void _invalidateCache() {
    _cachedAdBlockScript = null;
  }

  /// Adblocking and Anti-Adblock bypass JavaScript script to inject into pages
  static String get adBlockJavaScript {
    if (_cachedAdBlockScript != null) return _cachedAdBlockScript!;
    final domainsJson = jsonEncode(_blockedDomains.toList());
    _cachedAdBlockScript = '''
(function() {
  if (window.__xdmAdBlockerInjected) return;
  window.__xdmAdBlockerInjected = true;

  const blockedDomains = new Set($domainsJson);

  // 1. Mock common tracking and advertising variables to bypass anti-adblock detectors
  try {
    window.adsbygoogle = window.adsbygoogle || [];
    window.adsbygoogle.push = function(a) {
      try { if (a && a.onload) a.onload(); } catch(e){}
    };
    window.adsbygoogle.loaded = true;
    window.adsbygoogle.cmd = window.adsbygoogle.cmd || [];
    
    window.ga = window.ga || function() {};
    window.gtag = window.gtag || function() {};
    window.google_ad_client = window.google_ad_client || "ca-pub-dummy";
    window.fbq = window.fbq || function() {};
  } catch(e) {}

  // 2. Intercept visual checking of hidden ad placeholders to fool detectors
  try {
    const originalGetComputedStyle = window.getComputedStyle;
    window.getComputedStyle = function(el, pseudoElt) {
      const style = originalGetComputedStyle.apply(this, arguments);
      if (el && (el.classList.contains('ad') || el.classList.contains('ad-box') || el.classList.contains('pub_300x250') || el.id.includes('ad-'))) {
        return new Proxy(style, {
          get(target, prop) {
            if (prop === 'display') return 'block';
            if (prop === 'visibility') return 'visible';
            if (prop === 'opacity') return '1';
            if (prop === 'height') return '250px';
            if (prop === 'width') return '300px';
            return target[prop];
          }
        });
      }
      return style;
    };
  } catch(e) {}

  // 3. Synchronous check for blocking script injections instantly
  const ytPattern = /google\\.com|gstatic\\.com|googleapis\\.com|googleusercontent\\.com|youtube\\.com|youtu\\.be|googlevideo\\.com|ytimg\\.com|ggpht\\.com/i;
  const adPattern = /([/.])ads?([/._?=-]|\\d)|adsbygoogle|banner|popup|affiliate|tracker\\.php|tracking\\.php|click\\.php/i;

  function shouldBlockDomainSync(url) {
    if (!url) return false;
    let cleanUrl = url.trim().toLowerCase();
    if (cleanUrl.startsWith('//')) {
      cleanUrl = 'https:' + cleanUrl;
    } else if (!cleanUrl.startsWith('http://') && !cleanUrl.startsWith('https://')) {
      cleanUrl = 'https://' + cleanUrl;
    }
    
    let host = '';
    try {
      const uri = new URL(cleanUrl);
      host = uri.hostname;
    } catch (e) {
      host = cleanUrl.replace(/^https?:\\/\\//, '');
      const slashIndex = host.indexOf('/');
      if (slashIndex !== -1) host = host.substring(0, slashIndex);
      const colonIndex = host.indexOf(':');
      if (colonIndex !== -1) host = host.substring(0, colonIndex);
    }
    
    if (!host) return false;
    
    const parts = host.split('.');
    while (parts.length >= 2) {
      const domainToCheck = parts.join('.');
      if (blockedDomains.has(domainToCheck)) {
        return true;
      }
      parts.shift();
    }
    return false;
  }

  function shouldBlockSync(url) {
    if (!url) return false;
    if (ytPattern.test(url)) return false;
    
    const lower = url.toLowerCase();
    if (lower.includes('twitter.com/i/adsct') || lower.includes('facebook.com/tr')) {
      return true;
    }
    
    if (adPattern.test(lower)) return true;
    return shouldBlockDomainSync(lower);
  }

  // 4. Asynchronous helper to communicate with Dart for verification
  function checkBlockedAsync(url) {
    return new Promise((resolve) => {
      if (!url || url.startsWith('blob:') || url.startsWith('data:') || url.startsWith('file:')) {
        resolve(false);
        return;
      }
      // Check locally first to avoid channel round-trip latency
      if (shouldBlockSync(url)) {
        resolve(true);
        return;
      }

      // If not blocked locally, resolve false immediately to prevent any latency
      resolve(false);
    });
  }

  // 5. Intercept Fetch API calls (skip on YouTube to preserve native [native code] integrity)
  if (!ytHost) {
    try {
      const originalFetch = window.fetch;
      window.fetch = async function(input, init) {
        const url = typeof input === 'string' ? input : (input instanceof Request ? input.url : '');
        if (url) {
          const isBlocked = await checkBlockedAsync(url);
          if (isBlocked) {
            console.log('[AdBlocker] Blocked fetch to: ' + url);
            return Promise.reject(new TypeError('Failed to fetch (blocked by AdBlocker)'));
          }
        }
        return originalFetch.apply(this, arguments);
      };
    } catch(e) {}

    // 6. Intercept XMLHttpRequest (XHR) calls (skip on YouTube)
    try {
      const originalOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url) {
        this.__url = url;
        return originalOpen.apply(this, arguments);
      };

      const originalSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = async function(body) {
        if (this.__url) {
          const isBlocked = await checkBlockedAsync(this.__url);
          if (isBlocked) {
            console.log('[AdBlocker] Blocked XHR to: ' + this.__url);
            Object.defineProperty(this, 'readyState', { value: 4, writable: true });
            Object.defineProperty(this, 'status', { value: 0, writable: true });
            Object.defineProperty(this, 'statusText', { value: 'Blocked by AdBlocker', writable: true });
            this.dispatchEvent(new Event('error'));
            return;
          }
        }
        return originalSend.apply(this, arguments);
      };
    } catch(e) {}

    // 7. Intercept Script Tag Creation synchronously to block ad script loads
    try {
      const originalCreateElement = document.createElement;
      document.createElement = function(tagName) {
        const el = originalCreateElement.apply(this, arguments);
        if (tagName && tagName.toLowerCase() === 'script') {
          const descriptor = Object.getOwnPropertyDescriptor(HTMLScriptElement.prototype, 'src');
          Object.defineProperty(el, 'src', {
            set: function(val) {
              if (shouldBlockSync(val)) {
                console.log('[AdBlocker] Blocked script injection synchronously: ' + val);
                val = 'data:text/javascript,console.log("script ad blocked")';
              }
              if (descriptor && descriptor.set) {
                descriptor.set.call(this, val);
              } else {
                this.setAttribute('src', val);
              }
            },
            get: function() {
              if (descriptor && descriptor.get) {
                return descriptor.get.call(this);
              }
              return this.getAttribute('src') || '';
            },
            configurable: true
          });
        }
        return el;
      };
    } catch(e) {}
  }

  // 8. Inject CSS selector hiding stylesheet (exclude player modules on YouTube to prevent anti-adblock detection)
  try {
    const style = document.createElement('style');
    if (ytHost) {
      style.innerHTML = `
        iframe[src*="doubleclick.net"], iframe[src*="googleads"], .ad-box, .ad-banner, .pub_300x250, div[id^="google_ads_iframe"],
        ytd-promoted-sparkles-web-renderer, ytd-display-ad-renderer, ytd-statement-banner-renderer, ytd-in-feed-ad-layout-renderer, ytd-banner-promo-renderer {
          display: none !important;
          height: 0 !important;
          width: 0 !important;
        }
      `;
    } else {
      style.innerHTML = `
        iframe[src*="doubleclick.net"], iframe[src*="googleads"], .ad-box, .ad-banner, .pub_300x250, div[id^="google_ads_iframe"],
        .video-ads, .ytp-ad-module, .ytp-ad-overlay-container, ytd-promoted-sparkles-web-renderer, ytd-display-ad-renderer, ytd-statement-banner-renderer, ytd-in-feed-ad-layout-renderer, ytd-banner-promo-renderer {
          display: none !important;
          height: 0 !important;
          width: 0 !important;
        }
      `;
    }
    document.head.appendChild(style);
  } catch(e) {}

  // 9. Dedicated YouTube Ad Skipping Engine (safe 16x speedup & auto-click, restores 1.0x speed & audio when ad ends)
  try {
    if (ytHost) {
      let isAdMuted = false;
      setInterval(() => {
        try {
          const video = document.querySelector('video');
          const adContainer = document.querySelector('.ad-showing, .ad-interrupting, .video-ads');
          const adText = document.querySelector('.ytp-ad-text, .ytp-ad-preview-text, .ytp-ad-skip-button, .ytp-ad-skip-button-modern');
          
          if (video) {
            if (adContainer && adText) {
              try {
                if (!isAdMuted) {
                  video.muted = true;
                  isAdMuted = true;
                }
                video.playbackRate = 16.0;
              } catch (err) {}
            } else if (isAdMuted || video.playbackRate > 2.0) {
              try {
                video.playbackRate = 1.0;
                video.muted = false;
                isAdMuted = false;
              } catch (err) {}
            }
          }

          // Click 'Skip Ad' button as soon as it appears
          const skipButtons = document.querySelectorAll('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-skip-button-slot, .yt-spec-button-shape-next');
          skipButtons.forEach(btn => {
            if (btn && typeof btn.click === 'function') {
              btn.click();
            }
          });

          // Dismiss overlay banner ads
          const closeOverlayButtons = document.querySelectorAll('.ytp-ad-overlay-close-button');
          closeOverlayButtons.forEach(btn => {
            if (btn && typeof btn.click === 'function') {
              btn.click();
            }
          });
        } catch (err) {}
      }, 300);
    }
  } catch(e) {}
})();
''';
    return _cachedAdBlockScript!;
  }
}
