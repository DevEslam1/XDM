import 'package:dmx/core/services/engine/server_identity_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ServerIdentityCache', () {
    test('put/containsKey/remove/clear lifecycle', () async {
      final cache = ServerIdentityCache(maxCapacity: 4);
      addTearDown(cache.dispose);

      expect(cache.containsKey('a'), isFalse);
      cache.put('a', true);
      expect(cache.containsKey('a'), isTrue);
      cache.remove('a');
      expect(cache.containsKey('a'), isFalse);

      cache.put('b', true);
      cache.put('c', true);
      cache.clear();
      expect(cache.containsKey('b'), isFalse);
      expect(cache.containsKey('c'), isFalse);
    });

    test('removeStale evicts entries older than the ttl', () async {
      final cache = ServerIdentityCache();
      addTearDown(cache.dispose);
      cache.put('old', true);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      cache.removeStale(Duration.zero);
      expect(cache.containsKey('old'), isFalse);
      cache.put('fresh', true);
      cache.removeStale(const Duration(hours: 1));
      expect(cache.containsKey('fresh'), isTrue);
    });

    test('invalidateForUrl removes matching host and full-url prefixes',
        () async {
      final cache = ServerIdentityCache();
      addTearDown(cache.dispose);
      const url = 'https://example.com/file.zip';
      cache.put('example.com|etag|1', true);
      cache.put('$url|etag|1', true);
      cache.put('other.com|etag|1', true);

      cache.invalidateForUrl(url);

      expect(cache.containsKey('example.com|etag|1'), isFalse);
      expect(cache.containsKey('$url|etag|1'), isFalse);
      expect(cache.containsKey('other.com|etag|1'), isTrue);
    });

    test('invalidateForUrl clears everything for an unparsable url', () async {
      final cache = ServerIdentityCache();
      addTearDown(cache.dispose);
      cache.put('a|1', true);
      cache.put('b|1', true);
      cache.invalidateForUrl('not a url');
      expect(cache.containsKey('a|1'), isFalse);
      expect(cache.containsKey('b|1'), isFalse);
    });

    test('onMemoryPressure clears the cache', () async {
      final cache = ServerIdentityCache();
      addTearDown(cache.dispose);
      cache.put('a', true);
      cache.onMemoryPressure();
      expect(cache.containsKey('a'), isFalse);
    });

    test('dispose clears and is idempotent', () async {
      final cache = ServerIdentityCache();
      cache.put('a', true);
      await cache.dispose();
      expect(cache.containsKey('a'), isFalse);
    });
  });
}
