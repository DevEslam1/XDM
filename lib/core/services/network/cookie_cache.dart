import 'dart:core';
import 'dart:io';
import '../service_registry.dart';

class _CookieCacheEntry {
  final String cookie;
  final DateTime timestamp;
  final DateTime expiry;

  _CookieCacheEntry({
    required this.cookie,
    required this.timestamp,
    required this.expiry,
  });

  bool get isExpired => DateTime.now().isAfter(expiry);
}

/// Thread-safe bounded cache for HTTP cookies per origin with TTL.
/// Task 2.1: Injectable singleton service with clear/dispose on background.
class CookieCache implements DisposableService, MemoryPressureListener {
  CookieCache() {
    ServiceRegistry.register(this);
    ServiceRegistry.registerMemoryPressureListener(this);
  }

  final Map<String, _CookieCacheEntry> _cache = {};
  static const int _maxEntries = 100;
  static const Duration _defaultTtl = Duration(hours: 1);

  static DateTime computeExpiry(String cookie) {
    final now = DateTime.now();

    // Check Max-Age
    final maxAgeMatch = RegExp(r'(?:^|;\s*)Max-Age=(\d+)', caseSensitive: false)
        .firstMatch(cookie);
    if (maxAgeMatch != null) {
      final seconds = int.tryParse(maxAgeMatch.group(1)!);
      if (seconds != null) {
        return now.add(Duration(seconds: seconds));
      }
    }

    // Check Expires
    final expiresMatch =
        RegExp(r'(?:^|;\s*)Expires=([^;]+)', caseSensitive: false)
            .firstMatch(cookie);
    if (expiresMatch != null) {
      try {
        final expiresStr = expiresMatch.group(1)!.trim();
        final parsed = HttpDate.parse(expiresStr);
        return parsed;
      } catch (_) {
        // Fallback on parse failure
      }
    }

    return now.add(_defaultTtl);
  }

  void put(String origin, String cookie) {
    final now = DateTime.now();
    final expiry = computeExpiry(cookie);

    _cache[origin] = _CookieCacheEntry(
      cookie: cookie,
      timestamp: now,
      expiry: expiry,
    );

    // Evict expired
    _cache.removeWhere((_, entry) => entry.isExpired);

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
    if (entry.isExpired) {
      _cache.remove(origin);
      return null;
    }
    return entry.cookie;
  }

  void clear() {
    _cache.clear();
  }

  @override
  void onMemoryPressure() {
    clear();
  }

  @override
  Future<void> dispose() async {
    ServiceRegistry.unregister(this);
    ServiceRegistry.unregisterMemoryPressureListener(this);
    clear();
  }
}
