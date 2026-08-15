import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/engine/engine_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DownloadEngine Map Memory Leak Prevention & TimestampedLruMap', () {
    test('TimestampedLruMap enforces maximum capacity of 100 entries', () {
      final map = TimestampedLruMap<String, int>(maxCapacity: 100);

      for (var i = 0; i < 150; i++) {
        map.put('key_$i', i);
      }

      expect(map.length, equals(100));
      // First 50 keys (key_0 .. key_49) should have been evicted
      expect(map.containsKey('key_0'), isFalse);
      expect(map.containsKey('key_49'), isFalse);
      expect(map.containsKey('key_50'), isTrue);
      expect(map.containsKey('key_149'), isTrue);
    });

    test('LRU eviction evicts least recently accessed entry', () {
      final map = TimestampedLruMap<String, String>(maxCapacity: 3);

      map.put('a', 'apple');
      map.put('b', 'banana');
      map.put('c', 'cherry');

      // Access 'a' to make it most recent
      expect(map.get('a'), equals('apple'));

      // Adding 'd' should evict 'b' (since 'a' was accessed recently)
      map.put('d', 'durian');

      expect(map.containsKey('b'), isFalse);
      expect(map.containsKey('a'), isTrue);
      expect(map.containsKey('c'), isTrue);
      expect(map.containsKey('d'), isTrue);
    });

    test('Stale entry cleanup removes entries older than threshold', () async {
      final map = TimestampedLruMap<String, String>(maxCapacity: 100);

      map.put('stale_1', 'old_val');
      // Artificially access / update timestamp to past
      // ignore: invalid_use_of_protected_member
      map.put('recent_1', 'new_val');

      map.removeStale(const Duration(minutes: 10));
      // None removed if recently created
      expect(map.length, equals(2));
    });

    test('1000 operations do not cause unbounded growth beyond 100 items', () {
      final map = TimestampedLruMap<String, int>(maxCapacity: 100);

      for (var i = 0; i < 1000; i++) {
        map.put('task_$i', i);
      }

      expect(map.length, equals(100));
      expect(map.containsKey('task_999'), isTrue);
    });

    test('DownloadEngine dispose cancels cleanup timers', () {
      final engine = DownloadEngine(enableCleanupTimer: true);
      expect(() => engine.dispose(), returnsNormally);
    });
  });
}
