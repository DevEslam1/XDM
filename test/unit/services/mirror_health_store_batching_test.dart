import 'package:dmx/core/services/mirror/mirror_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MirrorHealthStore Flush Batching Under High Load (P0-04)', () {
    final store = MirrorHealthStore.instance;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await store.init();
      await store.clear();
    });

    tearDown(() async {
      await store.dispose();
    });

    test('batches 1000 rapid updates incrementally via per-URL keys', () async {
      // Perform 1,000 rapid mutations across 50 distinct mirror URLs
      for (int i = 0; i < 1000; i++) {
        final mirrorId = i % 50;
        final url = 'https://mirror$mirrorId.example.com/asset';
        if (i % 3 == 0) {
          await store.recordFailure(url, statusCode: 500);
        } else {
          await store.recordSuccess(url, speedBps: 1000.0 + i);
        }
      }

      // Memory cache is fully updated
      expect(store.isDirtyForTesting, isTrue);
      expect(store.dirtyUrlsForTesting.length, equals(50));

      // Flush durably
      await store.flushPending(durable: true);
      expect(store.isDirtyForTesting, isFalse);
      expect(store.dirtyUrlsForTesting, isEmpty);

      // Verify SharedPrefs contains per-URL keys and index
      final prefs = await SharedPreferences.getInstance();
      final urlIndex = prefs.getStringList('mirror_health_urls_index');
      expect(urlIndex, isNotNull);
      expect(urlIndex!.length, equals(50));

      for (int i = 0; i < 50; i++) {
        final key = 'mirror_health_url_https://mirror$i.example.com/asset';
        expect(prefs.containsKey(key), isTrue);
      }

      // Simulate a fresh cold startup reload
      final newStore = MirrorHealthStore();
      await newStore.init();

      expect(newStore.getPersistedSpeed('https://mirror0.example.com/asset'), isNonZero);
      expect(newStore.getMirrorRanking().length, equals(50));

      await newStore.dispose();
    });
  });
}
