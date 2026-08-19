import '../service_registry.dart';
import 'engine_utils.dart';

/// Thread-safe bounded cache for verified server identities (ETag / Last-Modified / totalSize).
/// Implements [DisposableService] and [MemoryPressureListener] for lifecycle and memory hygiene.
class ServerIdentityCache implements DisposableService, MemoryPressureListener {
  ServerIdentityCache({int maxCapacity = 100})
      : _cache = TimestampedLruMap<String, bool>(maxCapacity: maxCapacity) {
    ServiceRegistry.register(this);
    ServiceRegistry.registerMemoryPressureListener(this);
  }

  static final ServerIdentityCache instance = ServerIdentityCache();

  final TimestampedLruMap<String, bool> _cache;

  bool containsKey(String key) => _cache.containsKey(key);

  void put(String key, bool value) => _cache.put(key, value);

  void remove(String key) => _cache.remove(key);

  void removeStale(Duration ttl) => _cache.removeStale(ttl);

  void invalidateForUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) {
      clear();
      return;
    }
    final host = uri.host;
    for (final key in List<String>.from(_cache.keys)) {
      if (key.startsWith('$host|') || key.startsWith('$url|')) {
        _cache.remove(key);
      }
    }
  }

  void clear() {
    for (final key in List<String>.from(_cache.keys)) {
      _cache.remove(key);
    }
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
