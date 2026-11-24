import 'package:dmx/core/utils/bounded_lru_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BoundedLruCache', () {
    test('rejects non-positive maxCapacity', () {
      expect(
        () => BoundedLruCache<String, int>(maxCapacity: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('put/get and operator access report and expose contents', () {
      final cache = BoundedLruCache<String, int>(maxCapacity: 3);
      expect(cache.maxCapacity, 3);
      expect(cache.ttl, isNull);
      expect(cache.isEmpty, isTrue);
      expect(cache.isNotEmpty, isFalse);

      cache.put('a', 1);
      cache['b'] = 2;

      expect(cache.length, 2);
      expect(cache.isNotEmpty, isTrue);
      expect(cache.get('a'), 1);
      expect(cache['b'], 2);
      expect(cache.get('missing'), isNull);
      expect(cache.containsKey('a'), isTrue);
      expect(cache.containsKey('missing'), isFalse);
      expect(cache.keys, containsAll(<String>['a', 'b']));
    });

    test('evicts the least-recently-used entry at capacity', () {
      final cache = BoundedLruCache<String, int>(maxCapacity: 2);
      cache.put('a', 1);
      cache.put('b', 2);
      // Touch 'a' so 'b' becomes the LRU entry.
      expect(cache.get('a'), 1);

      cache.put('c', 3);

      expect(cache.length, 2);
      expect(cache.get('b'), isNull);
      expect(cache.get('a'), 1);
      expect(cache.get('c'), 3);
    });

    test('put on an existing key refreshes without growing', () {
      final cache = BoundedLruCache<String, int>(maxCapacity: 2);
      cache.put('a', 1);
      cache.put('b', 2);
      cache.put('a', 10);
      expect(cache.length, 2);
      expect(cache.get('a'), 10);
    });

    test('ttl expiry evicts on get and containsKey', () async {
      final cache = BoundedLruCache<String, int>(
        maxCapacity: 5,
        ttl: const Duration(milliseconds: 10),
      );
      cache.put('a', 1);
      expect(cache.get('a'), 1);

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(cache.get('a'), isNull);

      cache.put('b', 2);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(cache.containsKey('b'), isFalse);
      expect(cache.length, 0);
    });

    test('remove, removeStale, and clear manage contents', () async {
      final cache = BoundedLruCache<String, int>(
        maxCapacity: 5,
        ttl: const Duration(milliseconds: 10),
      );
      cache.put('a', 1);
      cache.put('b', 2);

      expect(cache.remove('a'), 1);
      expect(cache.remove('missing'), isNull);

      await Future<void>.delayed(const Duration(milliseconds: 30));
      cache.removeStale();
      expect(cache.length, 0);

      cache.put('c', 3);
      cache.clear();
      expect(cache.isEmpty, isTrue);
    });

    test('removeStale is a no-op when no ttl is configured', () {
      final cache = BoundedLruCache<String, int>(maxCapacity: 2);
      cache.put('a', 1);
      cache.removeStale();
      expect(cache.length, 1);
    });

    test('shrinkForBackground keeps the newest entries', () {
      final cache = BoundedLruCache<String, int>(maxCapacity: 8);
      for (var i = 0; i < 8; i++) {
        cache.put('k$i', i);
      }
      expect(cache.length, 8);

      cache.shrinkForBackground();

      expect(cache.length, 2); // maxCapacity ~/ 4
      expect(cache.get('k7'), 7);
      expect(cache.get('k6'), 6);
      expect(cache.get('k0'), isNull);
    });
  });
}
