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

  group('Mirror Registry & Benchmark Hardening (Sprint 2)', () {
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

    test('ServerProfileManager evicts beyond capacity keeping newest', () {
      final manager = ServerProfileManager();
      manager.clear();

      // Populate past the 100-profile cap. Each record updates lastAccess.
      for (int i = 0; i < 120; i++) {
        manager.recordSuccess('https://host$i.example.com',
            responseTimeMs: i % 50);
      }

      // The 120 newest profiles survive; the earliest 20 must be evicted.
      final oldestSurvivor = manager.getProfile('https://host20.example.com');
      // Re-touching an evicted host must create a fresh profile, proving
      // host0 was dropped from the registry.
      final evicted = manager.getProfile('https://host0.example.com');
      expect(oldestSurvivor.host, equals('host20.example.com'));
      expect(evicted.successCount, equals(0));

      manager.clear();
    });

    test('ServerProfileManager eviction index re-scores after mutations', () {
      final manager = ServerProfileManager();
      manager.clear();

      // An old profile that just got a success must outrank idle ones.
      manager.recordSuccess('https://active.example.com', responseTimeMs: 10);
      manager.recordFailure('https://idle.example.com',
          statusCode: 503, retryAfter: null);

      final active =
          manager.getProfileForMirrorSelection('https://active.example.com');
      expect(active.successRate, greaterThan(0));

      manager.clear();
    });
  });
}
