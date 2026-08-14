import 'dart:core';

class _CookieCacheEntry {
  final String cookie;
  final DateTime timestamp;
  _CookieCacheEntry(this.cookie, this.timestamp);
}

/// Thread-safe bounded cache for HTTP cookies per origin with TTL.
/// Task 2.1: Injectable singleton service with clear/dispose on background.
class CookieCache {
  static final CookieCache _instance = CookieCache._();
  factory CookieCache() => _instance;
  CookieCache._();

  final Map<String, _CookieCacheEntry> _cache = {};
  static const int _maxEntries = 100;
  static const Duration _ttl = Duration(hours: 1);

  void put(String origin, String cookie) {
    _cache[origin] = _CookieCacheEntry(cookie, DateTime.now());

    // Evict expired
    _cache.removeWhere(
        (_, entry) => DateTime.now().difference(entry.timestamp) > _ttl);

    // Evict oldest if over limit
    if (_cache.length > _maxEntries) {
      final oldest = _cache.entries
          .reduce(
              (a, b) => a.value.timestamp.isBefore(b.value.timestamp) ? a : b)
          .key;
      _cache.remove(oldest);
    }
  }

  String? get(String origin) {
    final entry = _cache[origin];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.timestamp) > _ttl) {
      _cache.remove(origin);
      return null;
    }
    return entry.cookie;
  }

  void clear() {
    _cache.clear();
  }

  void dispose() {
    _cache.clear();
  }
}
