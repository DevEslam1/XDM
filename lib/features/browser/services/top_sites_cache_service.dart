import 'package:synchronized/synchronized.dart';

/// Thread-safe singleton cache service for top-visited sites on the browser dashboard.
class TopSitesCacheService {
  static final TopSitesCacheService instance = TopSitesCacheService._();
  TopSitesCacheService._();

  final Lock _lock = Lock();
  List<Map<String, String>> _cache = [];
  DateTime _cacheTime = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration defaultTtl = Duration(minutes: 5);

  /// Retrieves cached top sites or fetches fresh data via [loader] under lock.
  Future<List<Map<String, String>>> getTopSites({
    required Future<List<Map<String, String>>> Function() loader,
    Duration ttl = defaultTtl,
  }) async {
    return _lock.synchronized(() async {
      final now = DateTime.now();
      if (_cache.isNotEmpty && now.difference(_cacheTime) < ttl) {
        return List<Map<String, String>>.from(_cache);
      }

      final fresh = await loader();
      _cache = List<Map<String, String>>.from(fresh);
      _cacheTime = now;
      return List<Map<String, String>>.from(_cache);
    });
  }

  /// Explicitly invalidates the cache so subsequent loads fetch fresh DB history.
  void invalidate() {
    _cache = [];
    _cacheTime = DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// Synchronously returns unexpired cached items, or empty list if expired.
  List<Map<String, String>> get cachedSites {
    if (_cache.isNotEmpty &&
        DateTime.now().difference(_cacheTime) < defaultTtl) {
      return List<Map<String, String>>.from(_cache);
    }
    return const [];
  }
}
