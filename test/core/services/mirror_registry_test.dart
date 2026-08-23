import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/mirror/mirror_registry.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Mirror Registry & Health Store Hardening', () {
    test('MirrorHealthStore coalesces dirty state and flushes', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final repo = MirrorHealthDriftRepository(db);
      final store = MirrorHealthStore(repository: repo);
      await store.init();

      await store.recordFailure('https://mirror1.example.com', statusCode: 503);
      expect(store.getFailureCount('https://mirror1.example.com'), equals(1));

      await store.flushPending(durable: true);
      final rows = await repo.loadAll();
      expect(rows.any((r) => r.url == 'https://mirror1.example.com'), isTrue);

      await store.clear();
      await db.close();
    });

    test('recordFailure increments failures and trips blacklist circuit at 5',
        () async {
      final store = MirrorHealthStore();
      const url = 'https://mirror1.example.com/file.zip';

      expect(store.isBlacklisted(url), isFalse);

      for (int i = 1; i <= 4; i++) {
        await store.recordFailure(url);
        expect(store.isBlacklisted(url), isFalse);
      }

      // 5th failure trips the circuit
      await store.recordFailure(url);
      expect(store.isBlacklisted(url), isTrue);
    });

    test('recordSuccess resets failure count and clears blacklist circuit',
        () async {
      final store = MirrorHealthStore();
      const url = 'https://mirror2.example.com/file.zip';

      for (int i = 0; i < 5; i++) {
        await store.recordFailure(url);
      }
      expect(store.isBlacklisted(url), isTrue);

      await store.recordSuccess(url, speedBps: 5000000);
      expect(store.isBlacklisted(url), isFalse);
      expect(store.getFailureCount(url), equals(0));
    });

    test(
        'getMirrorRanking ranks mirrors by average speed descending and excludes blacklisted',
        () async {
      final store = MirrorHealthStore();
      const urlFast = 'https://fast.example.com/file.zip';
      const urlSlow = 'https://slow.example.com/file.zip';
      const urlDead = 'https://dead.example.com/file.zip';

      await store.recordSuccess(urlFast, speedBps: 10000000); // 10 MB/s
      await store.recordSuccess(urlSlow, speedBps: 2000000); // 2 MB/s
      for (int i = 0; i < 5; i++) {
        await store.recordFailure(urlDead);
      }

      final ranking = store.getMirrorRanking();
      expect(ranking, contains(urlFast));
      expect(ranking, contains(urlSlow));
      expect(ranking, isNot(contains(urlDead)));
      expect(ranking.first, equals(urlFast));
    });

    test('evicts LRU entries when exceeding maxEntries capacity', () async {
      final store = MirrorHealthStore();
      const maxCap = MirrorHealthStore.maxEntries; // 200

      for (int i = 0; i < maxCap + 10; i++) {
        await store.recordSuccess('https://mirror$i.com/file.zip',
            speedBps: 1000.0 * i);
      }

      // Earliest mirrors (e.g. mirror0) should have been evicted
      final ranking = store.getMirrorRanking();
      expect(ranking.length, lessThanOrEqualTo(maxCap));
      expect(ranking, isNot(contains('https://mirror0.com/file.zip')));
    });
  });
}
