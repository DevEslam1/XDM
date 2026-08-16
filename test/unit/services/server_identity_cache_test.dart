import 'package:dmx/core/services/engine/server_identity_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ServerIdentityCache Tests', () {
    late ServerIdentityCache cache;

    setUp(() {
      cache = ServerIdentityCache(maxCapacity: 5);
    });

    tearDown(() async {
      await cache.dispose();
    });

    test('put and containsKey work correctly', () {
      cache.put('host1|etag1|lm1|1000', true);
      expect(cache.containsKey('host1|etag1|lm1|1000'), isTrue);
      expect(cache.containsKey('unknown_key'), isFalse);
    });

    test('invalidateForUrl removes keys matching url prefix', () {
      cache.put('https://example.com/file.zip|etag1|lm1|1000', true);
      cache.put('https://other.com/file.zip|etag2|lm2|2000', true);

      cache.invalidateForUrl('https://example.com/file.zip');

      expect(cache.containsKey('https://example.com/file.zip|etag1|lm1|1000'),
          isFalse);
      expect(cache.containsKey('https://other.com/file.zip|etag2|lm2|2000'),
          isTrue);
    });

    test('onMemoryPressure clears cache completely', () {
      cache.put('key1', true);
      cache.put('key2', true);

      cache.onMemoryPressure();

      expect(cache.containsKey('key1'), isFalse);
      expect(cache.containsKey('key2'), isFalse);
    });

    test('two jobs for same URL within 10 minutes only probe server once', () {
      final identityCache = ServerIdentityCache(maxCapacity: 100);
      const urlKey =
          'https://example.com/movie.mp4|etag-123|Tue, 15 Nov 2026|52428800';

      int probeCount = 0;
      void verifyServerIdentity(String key) {
        identityCache.removeStale(const Duration(minutes: 10));
        if (identityCache.containsKey(key)) {
          return;
        }
        probeCount++;
        identityCache.put(key, true);
      }

      // First job runs probe
      verifyServerIdentity(urlKey);
      expect(probeCount, equals(1));
      expect(identityCache.containsKey(urlKey), isTrue);

      // Second job within 10 minutes hits cache and skips probe
      verifyServerIdentity(urlKey);
      expect(probeCount, equals(1));
    });
  });
}
