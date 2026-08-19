import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/mirror/mirror_registry.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MirrorHealthStore Flush Batching Under High Load (P0-04)', () {
    late AppDatabase db;
    late MirrorHealthDriftRepository repo;
    late MirrorHealthStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = MirrorHealthDriftRepository(db);
      store = MirrorHealthStore(repository: repo);
      await store.init();
      await store.clear();
    });

    tearDown(() async {
      await store.dispose();
      await db.close();
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

      // Verify Drift repository contains 50 records
      final rows = await repo.loadAll();
      expect(rows.length, equals(50));

      // Simulate a fresh cold startup reload
      final newStore = MirrorHealthStore(repository: repo);
      await newStore.init();

      expect(newStore.getMirrorRanking().length, equals(50));

      await newStore.dispose();
    });
  });
}
