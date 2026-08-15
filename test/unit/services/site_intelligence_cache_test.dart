import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/utils/bounded_lru_cache.dart';
import 'package:dmx/core/services/site_intelligence/site_intelligence_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BoundedLruCache', () {
    test('evicts oldest entry when exceeding maxCapacity', () {
      final cache = BoundedLruCache<String, int>(maxCapacity: 3);
      cache.put('a', 1);
      cache.put('b', 2);
      cache.put('c', 3);

      expect(cache.length, 3);
      expect(cache.get('a'), 1);

      // Accessing 'a' makes 'b' the LRU item
      cache.put('d', 4);

      expect(cache.length, 3);
      expect(cache.get('b'), isNull); // 'b' was evicted
      expect(cache.get('a'), 1);
      expect(cache.get('c'), 3);
      expect(cache.get('d'), 4);
    });

    test('evicts at capacity 500', () {
      final cache = BoundedLruCache<int, int>(maxCapacity: 500);
      for (int i = 0; i < 600; i++) {
        cache.put(i, i);
      }

      expect(cache.length, 500);
      for (int i = 0; i < 100; i++) {
        expect(cache.get(i), isNull);
      }
      for (int i = 100; i < 600; i++) {
        expect(cache.get(i), i);
      }
    });

    test('expires items after TTL', () async {
      final cache = BoundedLruCache<String, String>(
        maxCapacity: 10,
        ttl: const Duration(milliseconds: 50),
      );

      cache.put('key1', 'val1');
      expect(cache.get('key1'), 'val1');

      await Future.delayed(const Duration(milliseconds: 60));
      expect(cache.get('key1'), isNull);
    });
  });

  group('SiteIntelligenceService FastPath Cache', () {
    setUp(() {
      SiteIntelligenceService.clearFastPathCache();
    });

    test('analyzeUrl uses fast path cache and clears properly', () async {
      final service = SiteIntelligenceService();
      const url = 'https://customcdn.example.org/files/archive.zip';

      final res1 = service.analyzeUrl(url);
      expect(res1.contentHint, ContentHint.archiveFile);

      // Second call hits cache
      final res2 = service.analyzeUrl(url);
      expect(res2.contentHint, ContentHint.archiveFile);

      SiteIntelligenceService.clearFastPathCache();
      await service.dispose();
    });

    test('onMemoryPressure purges cache and flushes pending', () async {
      final service = SiteIntelligenceService();
      const url = 'https://customcdn.example.org/files/archive2.zip';
      service.analyzeUrl(url);

      service.onMemoryPressure();
      await service.dispose();
    });
  });
}
