import 'dart:collection';

class _CacheEntry<V> {
  final V value;
  final DateTime createdAt;
  DateTime lastAccessed;

  _CacheEntry(this.value, DateTime now)
      : createdAt = now,
        lastAccessed = now;
}

/// A generic, bounded Least-Recently-Used (LRU) cache with optional time-to-live (TTL).
class BoundedLruCache<K, V> {
  BoundedLruCache({
    this.maxCapacity = 500,
    this.ttl,
  }) : assert(maxCapacity > 0, 'maxCapacity must be greater than 0');

  final int maxCapacity;
  final Duration? ttl;
  final LinkedHashMap<K, _CacheEntry<V>> _map = LinkedHashMap();

  int get length => _map.length;

  bool get isEmpty => _map.isEmpty;

  bool get isNotEmpty => _map.isNotEmpty;

  List<K> get keys => _map.keys.toList();

  V? get(K key) {
    final entry = _map.remove(key);
    if (entry == null) return null;

    final now = DateTime.now();
    if (ttl != null && now.difference(entry.createdAt) > ttl!) {
      return null;
    }

    entry.lastAccessed = now;
    _map[key] = entry;
    return entry.value;
  }

  void put(K key, V value) {
    _map.remove(key);
    if (_map.length >= maxCapacity) {
      _map.remove(_map.keys.first);
    }
    _map[key] = _CacheEntry(value, DateTime.now());
  }

  V? operator [](K key) => get(key);

  void operator []=(K key, V value) => put(key, value);

  bool containsKey(K key) {
    if (!_map.containsKey(key)) return false;
    final entry = _map[key];
    if (entry == null) return false;
    if (ttl != null && DateTime.now().difference(entry.createdAt) > ttl!) {
      _map.remove(key);
      return false;
    }
    return true;
  }

  V? remove(K key) {
    final entry = _map.remove(key);
    return entry?.value;
  }

  void clear() {
    _map.clear();
  }

  void removeStale() {
    if (ttl == null) return;
    final now = DateTime.now();
    _map.removeWhere((key, entry) => now.difference(entry.createdAt) > ttl!);
  }
}
