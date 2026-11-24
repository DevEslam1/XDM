import 'dart:convert';

import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/mirror/mirror_registry.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PowerMonitor.screenOff = false;
    PowerMonitor.isAppForegrounded = true;
  });

  tearDown(() {
    PowerMonitor.screenOff = false;
    PowerMonitor.isAppForegrounded = true;
  });

  group('MirrorHealthDriftRepository', () {
    test('upsert/delete/deleteAll/clear round-trip', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final repo = MirrorHealthDriftRepository(db);
      const entry = DbMirrorHealth(
        url: 'https://a/f',
        failures: 1,
        lastFailure: 0,
        lastSuccess: 0,
        lastStatusCode: 0,
        blacklistedUntil: 0,
        averageSpeedBps: 0,
        speedSamples: '[]',
      );
      await repo.upsert(entry);
      expect((await repo.loadAll()).any((r) => r.url == 'https://a/f'), isTrue);

      await repo.delete('https://a/f');
      expect(await repo.loadAll(), isEmpty);

      await repo.upsert(entry);
      await repo.deleteAll(['https://a/f']);
      expect(await repo.loadAll(), isEmpty);

      await repo.upsert(entry);
      await repo.clear();
      expect(await repo.loadAll(), isEmpty);
      await db.close();
    });
  });

  group('MirrorHealthStore persistence edge cases', () {
    test('migrates legacy prefs into a Drift repo and removes the blob',
        () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final repo = MirrorHealthDriftRepository(db);
      SharedPreferences.setMockInitialValues({
        'mirror_health_urls_index': ['https://legacy/f'],
        'mirror_health_url_https://legacy/f':
            jsonEncode((PersistedMirrorState()..failures = 2).toJson()),
        'mirror_health_data': jsonEncode({
          'https://blob/f': (PersistedMirrorState()..failures = 3).toJson(),
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      final store = MirrorHealthStore(repository: repo);
      await store.init(prefsOverride: prefs);

      expect(store.getFailureCount('https://legacy/f'), 2);
      expect(store.getFailureCount('https://blob/f'), 3);
      expect(prefs.getString('mirror_health_data'), isNull);
      expect((await repo.loadAll()).length, greaterThanOrEqualTo(2));

      await store.clear();
      await db.close();
    });

    test('expired legacy entries are cleaned up on init', () async {
      final expired = PersistedMirrorState()
        ..failures = 5
        ..blacklistedUntil = DateTime.now()
            .subtract(const Duration(hours: 1))
            .millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({
        'mirror_health_urls_index': ['https://expired/f'],
        'mirror_health_url_https://expired/f': jsonEncode(expired.toJson()),
      });
      final prefs = await SharedPreferences.getInstance();
      final store = MirrorHealthStore();
      addTearDown(store.dispose);
      await store.init(prefsOverride: prefs);
      expect(store.getFailureCount('https://expired/f'), 0);
    });

    test('a malformed speedSamples column is tolerated', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final repo = MirrorHealthDriftRepository(db);
      await repo.upsert(const DbMirrorHealth(
        url: 'https://bad/f',
        failures: 1,
        lastFailure: 0,
        lastSuccess: 0,
        lastStatusCode: 0,
        blacklistedUntil: 0,
        averageSpeedBps: 0,
        speedSamples: 'not-json',
      ));
      final store = MirrorHealthStore(repository: repo);
      await store.init();
      expect(store.getFailureCount('https://bad/f'), 1);
      await store.clear();
      await db.close();
    });

    test('getPersistedMirrorRanking tolerates invalid JSON', () async {
      SharedPreferences.setMockInitialValues({
        'mirror_ranking_cache': 'not-json',
        'mirror_ranking_cache_ttl':
            DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      });
      final store = MirrorHealthStore();
      addTearDown(store.dispose);
      expect(await store.getPersistedMirrorRanking(), isNull);
    });

    test('evicts LRU entries and flushes removals to the repo', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final repo = MirrorHealthDriftRepository(db);
      final store = MirrorHealthStore(repository: repo);
      await store.init();

      for (var i = 0; i < MirrorHealthStore.maxEntries + 10; i++) {
        await store.recordSuccess('https://m$i/f', speedBps: i.toDouble());
      }
      expect(store.getMirrorRanking().length,
          lessThanOrEqualTo(MirrorHealthStore.maxEntries));

      await store.flushPending(durable: true);
      await store.clear();
      await db.close();
    });

    test('a non-durable flush is rescheduled inside the min interval',
        () async {
      final store = MirrorHealthStore();
      addTearDown(store.dispose);
      await store.init();
      await store.recordFailure('https://r/f');
      await store.flushPending();
      await store.recordFailure('https://r/f');
      await store.flushPending();
      expect(store.getFailureCount('https://r/f'), 2);
    });

    test('a non-durable flush is skipped while the screen is off', () async {
      PowerMonitor.screenOff = true;
      final store = MirrorHealthStore();
      addTearDown(store.dispose);
      await store.init();
      await store.recordFailure('https://off/f');
      await store.flushPending();
      expect(store.isDirtyForTesting, isTrue);
    });

    test('the coalescing flush timer fires after the interval', () async {
      final store = MirrorHealthStore();
      await store.init();
      fakeAsync((async) {
        store.recordFailure('https://timer/f');
        async.elapse(const Duration(minutes: 6));
        async.flushMicrotasks();
      });
      await store.dispose();
    });

    test('static convenience wrappers delegate to the singleton', () async {
      await MirrorHealthStore.staticInit();
      await MirrorHealthStore.staticRecordFailure('https://s/f',
          statusCode: 500);
      await MirrorHealthStore.staticRecordSuccess('https://s/f', speedBps: 42);
      await MirrorHealthStore.staticRecordSpeed('https://s/f', 42);
      expect(MirrorHealthStore.staticIsBlacklisted('https://s/f'), isFalse);
      expect(MirrorHealthStore.staticGetFailureCount('https://s/f'), 0);
      expect(MirrorHealthStore.staticGetPersistedSpeed('https://s/f'), 42);
      expect(
          MirrorHealthStore.staticGetMirrorRanking(), contains('https://s/f'));
      await MirrorHealthStore.staticClear();
    });
  });

  group('ServerProfile expiry + manager eviction', () {
    test('a profile older than its ttl is expired', () {
      final profile = ServerProfile(host: 'x')
        ..lastAccess = DateTime.now().subtract(const Duration(days: 8));
      expect(profile.isExpired, isTrue);
    });

    test('the singleton manager evicts expired and over-cap profiles', () {
      final manager = ServerProfileManager.instance;
      manager.clear();
      for (var i = 0; i < 110; i++) {
        manager.getProfile('https://h$i.example.com/f');
      }
      final stale = manager.getProfile('https://stale.example.com/f')
        ..lastAccess = DateTime.now().subtract(const Duration(days: 8));
      expect(stale.isExpired, isTrue);

      manager.getProfile('https://trigger.example.com/f');
      manager.onMemoryPressure();
      manager.clear();
    });

    test('onMemoryPressure drops profiles older than an hour', () {
      final manager = ServerProfileManager();
      addTearDown(manager.dispose);
      final old = manager.getProfile('https://old.example.com/f')
        ..lastAccess = DateTime.now().subtract(const Duration(hours: 2));
      manager.getProfile('https://fresh.example.com/f');
      manager.onMemoryPressure();
      expect(old, isNotNull);
    });
  });
}
