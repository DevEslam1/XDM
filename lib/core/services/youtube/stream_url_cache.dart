/// In-memory stream URL cache with TTL expiration.
///
/// YouTube stream URLs expire after ~6 hours. This cache avoids redundant
/// network calls for the same video within a short window (default 5 min).
library;

import 'innertube_constants.dart';
import 'innertube_models.dart';

class _CacheEntry {
  final List<InnerTubeStream> streams;
  final DateTime timestamp;

  _CacheEntry(this.streams) : timestamp = DateTime.now();

  bool get isExpired => DateTime.now().difference(timestamp) > streamCacheTtl;
}

/// Simple in-memory cache for InnerTube stream manifests.
///
/// Thread-safety note: Dart is single-threaded per isolate, so no locks
/// are needed for the main isolate. If used across isolates, each isolate
/// should have its own instance.
class StreamUrlCache {
  final Map<String, _CacheEntry> _cache = {};

  /// Maximum number of entries before eviction (LRU-ish: oldest first).
  final int maxEntries;

  StreamUrlCache({this.maxEntries = 50});

  /// Stores streams for a video ID.
  void put(String videoId, List<InnerTubeStream> streams) {
    // Evict oldest if at capacity
    if (_cache.length >= maxEntries && !_cache.containsKey(videoId)) {
      final oldestKey = _cache.entries
          .reduce(
            (a, b) => a.value.timestamp.isBefore(b.value.timestamp) ? a : b,
          )
          .key;
      _cache.remove(oldestKey);
    }
    _cache[videoId] = _CacheEntry(streams);
  }

  /// Returns cached streams if fresh (within TTL), or null.
  List<InnerTubeStream>? get(String videoId) {
    final entry = _cache[videoId];
    if (entry == null) return null;
    if (entry.isExpired) {
      _cache.remove(videoId);
      return null;
    }
    return entry.streams;
  }

  /// Removes a specific video's cached streams (forces fresh fetch).
  void invalidate(String videoId) {
    _cache.remove(videoId);
  }

  /// Clears all cached entries.
  void clear() {
    _cache.clear();
  }

  /// Number of currently cached entries (including possibly expired).
  int get length => _cache.length;

  /// Removes all expired entries. Call periodically if memory is a concern.
  void prune() {
    _cache.removeWhere((_, entry) => entry.isExpired);
  }
}
