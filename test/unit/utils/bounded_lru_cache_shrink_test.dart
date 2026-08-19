import 'package:dmx/core/utils/bounded_lru_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BoundedLruCache.shrinkForBackground', () {
    test('shrinks cache to 1/4 capacity under memory pressure or backgrounding',
        () {
      final cache = BoundedLruCache<String, int>(maxCapacity: 20);
      for (int i = 0; i < 20; i++) {
        cache.put('key_$i', i);
      }
      expect(cache.length, 20);

      cache.shrinkForBackground();

      // maxCapacity ~/ 4 = 5
      expect(cache.length, 5);
      // Ensure most recent entries are preserved
      expect(cache.get('key_19'), 19);
      expect(cache.get('key_18'), 18);
    });
  });
}
