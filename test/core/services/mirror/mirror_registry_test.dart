import 'dart:convert';
import 'dart:io';

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

  group('PersistedMirrorState', () {
    test('toJson/fromJson round-trips and isExpired', () {
      final state = PersistedMirrorState()
        ..failures = 2
        ..lastFailure = 10
        ..lastSuccess = 20
        ..lastStatusCode = 503
        ..blacklistedUntil = DateTime.now()
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch
        ..averageSpeedBps = 1.5
        ..speedSamples = [1.0, 2.0];
      expect(state.isExpired, isTrue);

      final restored = PersistedMirrorState.fromJson(state.toJson());
      expect(restored.failures, 2);
      expect(restored.lastFailure, 10);
      expect(restored.lastSuccess, 20);
      expect(restored.lastStatusCode, 503);
      expect(restored.averageSpeedBps, 1.5);
      expect(restored.speedSamples, [1.0, 2.0]);
    });

    test('fromJson tolerates missing keys and a null speedSamples', () {
      final restored = PersistedMirrorState.fromJson({});
      expect(restored.failures, 0);
      expect(restored.averageSpeedBps, 0);
      expect(restored.speedSamples, isEmpty);
      expect(restored.isExpired, isFalse);
    });
  });

  group('MirrorHealthStore in-memory behavior', () {
    test('recordFailure trips blacklist at 5 and recordSuccess resets it',
        () async {
      final store = MirrorHealthStore();
      addTearDown(store.dispose);
      const url = 'https://mirror.example.com/f';

      for (var i = 0; i < 4; i++) {
        await store.recordFailure(url, statusCode: 503);
      }
      expect(store.isBlacklisted(url), isFalse);
      expect(store.getFailureCount(url), 4);

      await store.recordFailure(url);
      expect(store.isBlacklisted(url), isTrue);

      await store.recordSuccess(url, speedBps: 1024);
      expect(store.isBlacklisted(url), isFalse);
      expect(store.getFailureCount(url), 0);
      expect(store.getPersistedSpeed(url), 1024);
    });

    test('getMirrorRanking sorts by speed and excludes blacklisted', () async {
      final store = MirrorHealthStore();
      addTearDown(store.dispose);
      await store.recordSuccess('https://fast/f', speedBps: 9000);
      await store.recordSuccess('https://slow/f', speedBps: 100);
      for (var i = 0; i < 5; i++) {
        await store.recordFailure('https://dead/f');
      }
      final ranking = store.getMirrorRanking();
      expect(ranking.first, 'https://fast/f');
      expect(ranking, isNot(contains('https://dead/f')));
    });

    test('getMirrorRanking is empty before init', () {
      final store = MirrorHealthStore();
      addTearDown(store.dispose);
      expect(store.getMirrorRanking(), isEmpty);
    });

    test('unknown urls return safe defaults', () async {
      final store = MirrorHealthStore();
      addTearDown(store.dispose);
      await store.init();
      expect(store.isBlacklisted('https://nope/f'), isFalse);
      expect(store.getFailureCount('https://nope/f'), 0);
      expect(store.getPersistedSpeed('https://nope/f'), 0);
    });

    test('recordSpeed uses a rolling average capped at 10 samples', () async {
      final store = MirrorHealthStore();
      addTearDown(store.dispose);
      const url = 'https://speed/f';
      for (var i = 1; i <= 12; i++) {
        await store.recordSpeed(url, i.toDouble());
      }
      // Last 10 samples are 3..12 -> average 7.5
      expect(store.getPersistedSpeed(url), closeTo(7.5, 0.0001));
    });

    test('cleanupStaleEntries is a no-op before init and marks dirty after',
        () async {
      final store = MirrorHealthStore();
      addTearDown(store.dispose);
      await store.cleanupStaleEntries();
      await store.init();
      await store.recordFailure('https://x/f');
      expect(store.isDirtyForTesting, isTrue);
      await store.cleanupStaleEntries();
    });
  });

  group('MirrorHealthStore migration + persistence', () {
    test('migrates legacy SharedPreferences entries into the cache', () async {
      final legacyState = PersistedMirrorState()
        ..failures = 3
        ..lastStatusCode = 404;
      SharedPreferences.setMockInitialValues({
        'mirror_health_urls_index': ['https://legacy/f'],
        'mirror_health_url_https://legacy/f': jsonEncode(legacyState.toJson()),
        'mirror_health_data': jsonEncode({
          'https://blob/f': (PersistedMirrorState()..failures = 1).toJson(),
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      final store = MirrorHealthStore();
      addTearDown(store.dispose);

      await store.init(prefsOverride: prefs);

      expect(store.getFailureCount('https://legacy/f'), 3);
      expect(store.getFailureCount('https://blob/f'), 1);
    });

    test('migration tolerates malformed legacy blobs', () async {
      SharedPreferences.setMockInitialValues({
        'mirror_health_urls_index': ['https://bad/f'],
        'mirror_health_url_https://bad/f': 'not-json',
        'mirror_health_data': 'also-not-json',
      });
      final prefs = await SharedPreferences.getInstance();
      final store = MirrorHealthStore();
      addTearDown(store.dispose);
      await store.init(prefsOverride: prefs);
      expect(store.getFailureCount('https://bad/f'), 0);
    });

    test('flushPending writes to SharedPreferences when no Drift repo',
        () async {
      final store = MirrorHealthStore();
      addTearDown(store.dispose);
      await store.init();
      await store.recordFailure('https://persist/f', statusCode: 500);
      await store.flushPending(durable: true);
      expect(store.isDirtyForTesting, isFalse);

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('mirror_health_data');
      expect(raw, isNotNull);
      expect(raw, contains('https://persist/f'));
    });

    test('persistMirrorRanking / getPersistedMirrorRanking round-trip',
        () async {
      final store = MirrorHealthStore();
      addTearDown(store.dispose);
      await store.persistMirrorRanking(['https://a', 'https://b']);
      final restored = await store.getPersistedMirrorRanking();
      expect(restored, ['https://a', 'https://b']);
    });

    test('getPersistedMirrorRanking returns null when ttl expired', () async {
      SharedPreferences.setMockInitialValues({
        'mirror_ranking_cache': jsonEncode(['https://a']),
        'mirror_ranking_cache_ttl': 1,
      });
      final store = MirrorHealthStore();
      addTearDown(store.dispose);
      expect(await store.getPersistedMirrorRanking(), isNull);
    });

    test('clear resets cache and removes legacy keys', () async {
      final store = MirrorHealthStore();
      addTearDown(store.dispose);
      await store.init();
      await store.recordFailure('https://clear/f');
      await store.clear();
      expect(store.getFailureCount('https://clear/f'), 0);
    });

    test('Drift repository round-trip persists and reloads health rows',
        () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final repo = MirrorHealthDriftRepository(db);
      final store = MirrorHealthStore(repository: repo);
      await store.init();

      await store.recordFailure('https://db/f', statusCode: 502);
      await store.recordSpeed('https://db/f', 1234);
      await store.flushPending(durable: true);

      final rows = await repo.loadAll();
      expect(rows.any((r) => r.url == 'https://db/f'), isTrue);

      final store2 = MirrorHealthStore(repository: repo);
      await store2.init();
      expect(store2.getFailureCount('https://db/f'), 1);

      await store.clear();
      await store2.clear();
      await db.close();
    });
  });

  group('ServerProfile', () {
    test('success/failure metrics and reliability score', () {
      final profile = ServerProfile(host: 'example.com');
      expect(profile.successRate, 1.0);
      expect(profile.avgResponseTimeMs, 0);
      expect(profile.reliabilityScore, 100.0);

      profile.recordSuccess(100);
      profile.recordSuccess(200);
      expect(profile.successCount, 2);
      expect(profile.avgResponseTimeMs, 150);

      profile.recordFailure(500, null);
      expect(profile.failureCount, 1);
      expect(profile.successRate, closeTo(2 / 3, 0.0001));
    });

    test('recordFailure parses numeric and HTTP-date retry-after', () {
      final profile = ServerProfile(host: 'x');
      profile.recordFailure(429, '30');
      expect(profile.wasRateLimited, isTrue);
      expect(profile.lastRetryAfter, const Duration(seconds: 30));

      profile.recordFailure(503, '99999');
      expect(profile.lastRetryAfter, const Duration(seconds: 3600));

      final future =
          HttpDate.format(DateTime.now().add(const Duration(seconds: 100)));
      profile.recordFailure(429, future);
      expect(profile.lastRetryAfter!.inSeconds, inInclusiveRange(1, 3600));

      profile.recordFailure(429, 'garbage');
      // Unchanged from the previous successful parse.
      expect(profile.lastRetryAfter, isNotNull);

      profile.recordFailure(429, 'garbage-date');
      expect(profile.wasRateLimited, isTrue);
    });

    test('isCdn detects CDN hostnames and non-CDN is false', () {
      expect(ServerProfile(host: 'cdn.cloudflare.net').isCdn, isTrue);
      expect(ServerProfile(host: 'example.com').isCdn, isFalse);
    });

    test('recordSuccess caps the response-time queue and prunes', () {
      final profile = ServerProfile(host: 'y');
      for (var i = 0; i < 25; i++) {
        profile.recordSuccess(10);
      }
      profile.pruneStaleMetrics();
      expect(profile.avgResponseTimeMs, 10);
    });
  });

  group('ServerProfileManager', () {
    test('getProfile caches by host and exposes selection record', () {
      final manager = ServerProfileManager();
      addTearDown(manager.dispose);
      final a = manager.getProfile('https://example.com/f');
      final b = manager.getProfile('https://example.com/other');
      expect(identical(a, b), isTrue);

      manager.recordSuccess('https://example.com/f', responseTimeMs: 50);
      final record =
          manager.getProfileForMirrorSelection('https://example.com/f');
      expect(record.successRate, 1.0);
      expect(record.supportsRange, isTrue);
    });

    test('getRetryDelay follows retry-after, cdn, rate-limit, exponential', () {
      final manager = ServerProfileManager();
      addTearDown(manager.dispose);

      manager.recordFailure('https://cdn.example.com/f',
          statusCode: 429, retryAfter: '12');
      expect(manager.getRetryDelay('https://cdn.example.com/f', 3),
          const Duration(seconds: 12));

      manager.recordFailure('https://plain.example.com/f',
          statusCode: 500, retryAfter: null);
      // not rate limited, isCdn false -> exponential
      expect(manager.getRetryDelay('https://plain.example.com/f', 1),
          const Duration(seconds: 10));

      manager.recordFailure('https://ratelimited.example.com/f',
          statusCode: 503, retryAfter: null);
      expect(manager.getRetryDelay('https://ratelimited.example.com/f', 2),
          const Duration(seconds: 60));

      final cdnManager = ServerProfileManager();
      addTearDown(cdnManager.dispose);
      cdnManager.getProfile('https://cdn.akamai.net/f');
      expect(cdnManager.getRetryDelay('https://cdn.akamai.net/f', 100),
          const Duration(seconds: 10));
    });

    test('clear empties profiles and onMemoryPressure removes stale', () {
      final manager = ServerProfileManager();
      addTearDown(manager.dispose);
      manager.recordSuccess('https://a/f', responseTimeMs: 5);
      manager.onMemoryPressure();
      manager.clear();
      expect(
          manager.getProfileForMirrorSelection('https://a/f').successRate, 1.0);
    });
  });

  group('MirrorBenchmarkService', () {
    test('benchmarkAll returns empty for empty input', () async {
      final service = MirrorBenchmarkService();
      addTearDown(service.dispose);
      expect(await service.benchmarkAll([]), isEmpty);
    });

    test('clearCache and onMemoryPressure are safe', () {
      final service = MirrorBenchmarkService();
      addTearDown(service.dispose);
      service.clearCache();
      service.onMemoryPressure();
    });

    test('MirrorBenchmarkResult stores fields', () {
      const result = MirrorBenchmarkResult(
          url: 'u', latencyMs: 5, speedBps: 10, success: true);
      expect(result.url, 'u');
      expect(result.success, isTrue);
    });
  });

  group('MirrorRegistry facade', () {
    test('delegates init and dispose to the health store', () async {
      final store = MirrorHealthStore();
      final registry = MirrorRegistry(healthStore: store);
      await registry.init();
      await registry.dispose();
      expect(store.getMirrorRanking(), isEmpty);
    });
  });
}
