import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class AdBlocker {
  static final Set<String> _blockedDomains = {};
  static bool _initialized = false;

  static const List<String> _allowedDomains = [
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
  ];

  // Well-known, high-quality, mobile-optimized hosts lists
  static const List<String> hostsSources = [
    'https://adaway.org/hosts.txt',
    'https://v.firebog.net/hosts/AdguardDNS.txt',
    'https://v.firebog.net/hosts/Easyprivacy.txt',
  ];

  static const List<String> _allowedDomainSuffixes = [
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
    'twitter.com/i/adsct',
    'connect.facebook.net',
    'facebook.com/tr',
  ];

  static const List<String> _adUrlPatterns = [
    '/ads/',
    '/ad/',
    '/adsbygoogle',
    '/banner',
    '/popup',
    'affiliate',
    'tracker.php',
    'tracking.php',
    'click.php',
    'redirect?',
    'goto?',
  ];

  /// Asynchronously loads local hosts from cache file or triggers background download
  static Future<void> initialize() async {
    if (_initialized) return;

    // Load defaults immediately as fallback
    _blockedDomains.addAll(_fallbackDomains);

    try {
      final file = await _getHostsFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final domains = _parseHostsContent(content);
        _blockedDomains.addAll(domains);
        debugPrint('AdBlocker loaded ${domains.length} custom domains from local cache.');
      } else {
        // Trigger non-blocking background download
        updateHosts();
      }
    } catch (e) {
      debugPrint('AdBlocker initialization error: $e');
    }

    _initialized = true;
  }

  /// Downloads fresh lists, parses domains, updates memory list, and caches to disk
  static Future<void> updateHosts() async {
    final dio = Dio();
    final Set<String> newDomains = {};

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
          final parsed = _parseHostsContent(response.data!);
          newDomains.addAll(parsed);
          debugPrint('AdBlocker: Downloaded ${parsed.length} domains from $source');
        }
      } catch (e) {
        debugPrint('AdBlocker: Error downloading hosts from $source: $e');
      }
    }

    if (newDomains.isNotEmpty) {
      final updated = <String>{..._fallbackDomains, ...newDomains};
      _blockedDomains
        ..clear()
        ..addAll(updated);

      try {
        final file = await _getHostsFile();
        await file.writeAsString(newDomains.join('\n'));
        debugPrint('AdBlocker: Successfully saved ${_blockedDomains.length} total domains.');
      } catch (e) {
        debugPrint('AdBlocker: Error caching hosts to file: $e');
      }
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
        updateHosts();
      } else {
        debugPrint('AdBlocker: Cached hosts list is fresh ($difference old). Skipping auto-update.');
      }
    } catch (e) {
      debugPrint('AdBlocker: Error in auto-updating hosts: $e');
      updateHosts();
    }
  }

  static Set<String> _parseHostsContent(String content) {
    final Set<String> domains = {};
    final lines = content.split('\n');

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('!') || line.startsWith('//')) {
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
    return domains;
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
  static bool shouldBlock(String url) {
    if (!_initialized) {
      _blockedDomains.addAll(_fallbackDomains);
      _initialized = true;
    }

    // 0. Always allow YouTube domains and API paths
    if (_isAllowedUrl(url)) return false;

    final lower = url.toLowerCase();

    // 1. Fast match against common URL patterns
    for (final pattern in _adUrlPatterns) {
      if (lower.contains(pattern)) return true;
    }

    // 2. Extract host domain
    final host = _extractHost(lower);
    if (host.isEmpty) return false;

    // 3. Domain suffix lookup check
    var parts = host.split('.');
    while (parts.length >= 2) {
      final domainToCheck = parts.join('.');
      if (_blockedDomains.contains(domainToCheck)) {
        return true;
      }
      parts.removeAt(0);
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

  /// Adblocking and Anti-Adblock bypass JavaScript script to inject into pages
  static String get adBlockJavaScript => r'''
(function() {
  if (window.__xdmAdBlockerInjected) return;
  window.__xdmAdBlockerInjected = true;

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
  const ytPattern = /youtube\.com|youtu\.be|googlevideo\.com|ytimg\.com|ggpht\.com/i;
  const adPattern = /adservice|doubleclick|googlesyndication|googleadservices|adnxs|adsystem|outbrain|taboola|criteo|pubmatic|rubiconproject|openx|adform|yieldmo|adcolony|admob|airpush|applovin|pagead|analytics|gtag/i;
  function isAdUrlSync(url) {
    if (!url) return false;
    if (ytPattern.test(url)) return false;
    return adPattern.test(url);
  }

  // 4. Asynchronous helper to communicate with Dart for full verification
  function checkBlockedAsync(url) {
    return new Promise((resolve) => {
      if (!url || url.startsWith('blob:') || url.startsWith('data:') || url.startsWith('file:')) {
        resolve(false);
        return;
      }
      // Always allow YouTube URLs
      if (ytPattern.test(url)) {
        resolve(false);
        return;
      }
      const requestId = Math.random().toString(36).substring(2);
      window._adBlockPromiseResolvers = window._adBlockPromiseResolvers || {};
      window._adBlockPromiseResolvers[requestId] = resolve;
      
      if (window.AdBlockerChannel) {
        window.AdBlockerChannel.postMessage(JSON.stringify({ id: requestId, url: url }));
      } else {
        resolve(false);
      }
    });
  }

  // 5. Intercept Fetch API calls
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

  // 6. Intercept XMLHttpRequest (XHR) calls
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
      if (tagName.toLowerCase() === 'script') {
        const descriptor = Object.getOwnPropertyDescriptor(HTMLScriptElement.prototype, 'src');
        Object.defineProperty(el, 'src', {
          set: function(val) {
            if (isAdUrlSync(val)) {
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

  // 8. Inject CSS selector hiding stylesheet
  try {
    const style = document.createElement('style');
    style.innerHTML = 'iframe[src*="doubleclick.net"], iframe[src*="googleads"], .ad-box, .ad-banner, .pub_300x250, div[id^="google_ads_iframe"] { display: none !important; height: 0 !important; width: 0 !important; }';
    document.head.appendChild(style);
  } catch(e) {}
})();
''';
}
