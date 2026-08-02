
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logging/logging.dart';

/// Detects cross-domain automatic redirects and manages user preferences
/// for opening them in a new tab versus the current tab.
class RedirectGuard {
  RedirectGuard._();
  static final RedirectGuard instance = RedirectGuard._();

  static const String _prefKeyAlwaysNewTab = 'redirect_guard_always_new_tab_domains';
  static const String _prefKeyEnabled = 'redirect_guard_enabled';

  final Set<String> _alwaysNewTabDomains = {};
  final Set<String> _userInitiatedUrls = {};
  bool _enabled = true;

  bool get isEnabled => _enabled;

  /// Safe domains that should never be intercepted as suspicious redirects
  static const Set<String> _safeDomains = {
    'google.com',
    'youtube.com',
    'youtu.be',
    'googleapis.com',
    'gstatic.com',
    'facebook.com',
    'instagram.com',
    'twitter.com',
    'x.com',
    'github.com',
    'reddit.com',
    'wikipedia.org',
    'apple.com',
    'microsoft.com',
    'amazon.com',
    'cloudflare.com',
  };

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefKeyEnabled) ?? true;
      final savedDomains = prefs.getStringList(_prefKeyAlwaysNewTab) ?? [];
      _alwaysNewTabDomains.clear();
      _alwaysNewTabDomains.addAll(savedDomains);
    } catch (e) {
      debugPrint('[RedirectGuard] Init error: $e');
    }
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKeyEnabled, value);
    } catch (e) {
      debugPrint('[RedirectGuard] Failed to save enabled state: $e');
    }
  }

  /// Mark a URL as user-initiated (e.g. entered via address bar, bookmark tap)
  void markUserInitiated(String url) {
    if (url.isEmpty) return;
    _userInitiatedUrls.add(url);
    if (_userInitiatedUrls.length > 100) {
      _userInitiatedUrls.remove(_userInitiatedUrls.first);
    }
  }

  /// Returns true and clears the mark if the URL was user-initiated
  bool consumeUserInitiated(String url) {
    return _userInitiatedUrls.remove(url);
  }

  /// Checks if [domain] is set to always open in a new tab by the user
  bool isAlwaysNewTab(String targetUrl) {
    final domain = extractDomain(targetUrl);
    if (domain.isEmpty) return false;
    return _alwaysNewTabDomains.contains(domain);
  }

  /// Adds a domain to the persistent "always open in new tab" set
  Future<void> addAlwaysNewTabDomain(String targetUrl) async {
    final domain = extractDomain(targetUrl);
    if (domain.isEmpty) return;
    _alwaysNewTabDomains.add(domain);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefKeyAlwaysNewTab, _alwaysNewTabDomains.toList());
    } catch (e) {
      debugPrint('[RedirectGuard] Failed to save domain whitelist: $e');
    }
  }

  /// Removes a domain from the "always open in new tab" set
  Future<void> removeAlwaysNewTabDomain(String targetUrl) async {
    final domain = extractDomain(targetUrl);
    if (domain.isEmpty) return;
    _alwaysNewTabDomains.remove(domain);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefKeyAlwaysNewTab, _alwaysNewTabDomains.toList());
    } catch (e) {
      debugPrint('[RedirectGuard] Failed to remove domain whitelist: $e');
    }
  }

  /// Evaluates whether a navigation from [currentTabUrl] to [targetUrl]
  /// is an automatic cross-domain redirect that warrants user action.
  bool isSuspiciousRedirect({
    required String currentTabUrl,
    required String targetUrl,
  }) {
    if (!_enabled) return false;
    if (targetUrl.isEmpty || targetUrl == 'about:blank') return false;
    if (consumeUserInitiated(targetUrl)) return false;

    final currentDomain = extractDomain(currentTabUrl);
    final targetDomain = extractDomain(targetUrl);

    // If current tab is home/blank or domains match, not a cross-domain redirect
    if (currentDomain.isEmpty || targetDomain.isEmpty || currentDomain == targetDomain) {
      return false;
    }

    // Ignore safe domains
    if (_safeDomains.any((d) => targetDomain == d || targetDomain.endsWith('.$d'))) {
      return false;
    }

    return true;
  }

  /// Known multi-part TLDs that need 3-part domain extraction
  static const Set<String> _multiPartTlds = {
    'co.uk', 'org.uk', 'me.uk', 'net.uk',
    'com.au', 'net.au', 'org.au',
    'co.jp', 'or.jp', 'ne.jp',
    'co.in', 'net.in', 'org.in',
    'com.br', 'net.br', 'org.br',
    'com.eg', 'net.eg', 'org.eg',
    'co.za', 'org.za', 'net.za',
    'com.tr', 'org.tr', 'net.tr',
    'com.mx', 'org.mx',
    'co.kr', 'or.kr',
    'com.sa', 'net.sa',
    'com.ar', 'com.co',
  };

  /// Utility method to extract root domain (e.g. `example.com` from `sub.example.com`)
  static String extractDomain(String url) {
    if (url.isEmpty) return '';
    try {
      final normalized = url.startsWith('http://') || url.startsWith('https://')
          ? url
          : 'https://$url';
      final uri = Uri.tryParse(normalized);
      if (uri == null || uri.host.isEmpty) return '';
      var host = uri.host.toLowerCase();
      if (host.startsWith('www.')) host = host.substring(4);
      final parts = host.split('.');
      if (parts.length <= 2) return host;
      final lastTwo = '${parts[parts.length - 2]}.${parts[parts.length - 1]}';
      if (_multiPartTlds.contains(lastTwo) && parts.length > 2) {
        return '${parts[parts.length - 3]}.$lastTwo';
      }
      return lastTwo;
    } catch (e, st) {
      Logger('redirect_guard').warning('[redirect_guard] operation failed', e, st);
      return '';
    }
  }
}