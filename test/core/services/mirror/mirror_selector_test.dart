import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/mirror/mirror_registry.dart';
import 'package:dmx/core/services/mirror/mirror_selector.dart';
import 'package:dmx/core/services/protocol_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await MirrorHealthStore.instance.init();
    await ProtocolCache.init();
  });

  group('MirrorManager & MirrorStats', () {
    test('primaryUrl/allUrls/getBestMirror/getNextMirror on empty list', () {
      final manager = MirrorManager([]);
      expect(manager.primaryUrl, isNull);
      expect(manager.allUrls, isEmpty);
      expect(manager.getBestMirror(), isNull);
      expect(manager.getNextMirror('x'), isNull);
    });

    test('prefers healthy fastest mirror and deprioritizes failures', () {
      final manager = MirrorManager([
        'https://m1/f',
        'https://m2/f',
        'https://m3/f',
      ]);
      manager.recordSuccess('https://m1/f', 100, const Duration(seconds: 1));
      manager.recordSuccess('https://m2/f', 1000, const Duration(seconds: 1));
      expect(manager.getBestMirror(), 'https://m2/f');
      for (var i = 0; i < MirrorManager.maxFailuresBeforeDeprioritize; i++) {
        manager.recordFailure('https://m2/f');
      }
      expect(manager.isHealthy('https://m2/f'), isFalse);
      expect(manager.getBestMirror(), 'https://m1/f');
    });

    test('unknown-url record calls are safe no-ops', () {
      final manager = MirrorManager(['https://only/f']);
      manager.recordSuccess('https://missing/f', 1, Duration.zero);
      manager.recordFailure('https://missing/f');
      expect(manager.isHealthy('https://missing/f'), isFalse);
    });

    test('MirrorStats caps avg speed and computes health score', () {
      final stats = MirrorStats('https://s/f');
      expect(stats.avgSpeedBps, 0);
      stats.totalBytes = 1000;
      stats.totalMs = 1000;
      expect(stats.avgSpeedBps, 1000);

      stats.failures = MirrorManager.maxFailuresBeforeDeprioritize;
      expect(stats.healthScore, 0.0);

      stats.failures = 0;
      stats.successCount = 1;
      stats.avgLatencyMs = 100;
      expect(stats.healthScore, greaterThan(0.0));

      final capped = MirrorStats('https://c/f')
        ..totalBytes = 100000000
        ..totalMs = 1;
      expect(capped.avgSpeedBps, 10 * 1024 * 1024 * 1024);
    });
  });

  group('MirrorParallelEngine.raceMirrors', () {
    test('throws for empty urls', () {
      expect(
        () => MirrorParallelEngine.raceMirrors<int>([], (u, t) async => 1),
        throwsArgumentError,
      );
    });

    test('single url resolves', () async {
      final result = await MirrorParallelEngine.raceMirrors<String>(
          ['https://only/f'], (u, t) async => 'only');
      expect(result, 'only');
    });

    test('single url applies timeout', () async {
      await expectLater(
        MirrorParallelEngine.raceMirrors<int>(
          ['https://only/f'],
          (u, t) async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            return 1;
          },
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('single url propagates a synchronous fetch error', () async {
      await expectLater(
        MirrorParallelEngine.raceMirrors<int>(
          ['https://only/f'],
          (u, t) => throw StateError('sync'),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('multi url returns the first winner', () async {
      final result = await MirrorParallelEngine.raceMirrors<String>(
        ['https://a/f', 'https://b/f'],
        (u, t) async {
          if (u == 'https://a/f') {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            return 'a';
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return 'b';
        },
      );
      expect(result, 'a');
    });

    test('all mirrors failing throws MirrorRaceException', () async {
      await expectLater(
        MirrorParallelEngine.raceMirrors<int>(
          ['https://a/f', 'https://b/f'],
          (u, t) async => throw StateError('fail'),
        ),
        throwsA(isA<MirrorRaceException>()),
      );
    });

    test('timeout cancels the race', () async {
      await expectLater(
        MirrorParallelEngine.raceMirrors<int>(
          ['https://a/f', 'https://b/f'],
          (u, t) async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            return 1;
          },
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('an already-cancelled parent token rejects immediately', () async {
      final parent = CancelToken()..cancel('parent-cancel');
      await expectLater(
        MirrorParallelEngine.raceMirrors<int>(
          ['https://a/f', 'https://b/f'],
          (u, t) async => 1,
          parentCancelToken: parent,
        ),
        throwsA(isA<DioException>()),
      );
    });

    test('cancelling the parent mid-race fails the race', () async {
      final parent = CancelToken();
      final future = MirrorParallelEngine.raceMirrors<int>(
        ['https://a/f', 'https://b/f'],
        (u, t) async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return 1;
        },
        parentCancelToken: parent,
      );
      parent.cancel('mid');
      await expectLater(future, throwsA(isA<DioException>()));
    });
  });

  group('MirrorParallelEngine distribution + speed', () {
    test('distributeThreads returns empty for no urls or zero threads', () {
      final empty = MirrorParallelEngine([]);
      addTearDown(empty.dispose);
      expect(empty.distributeThreads(8), isEmpty);
      final engine = MirrorParallelEngine(['https://a/f']);
      addTearDown(engine.dispose);
      expect(engine.distributeThreads(0), isEmpty);
    });

    test('distributeThreads spreads threads and caches the result', () {
      final engine =
          MirrorParallelEngine(['https://a/f', 'https://b/f', 'https://c/f']);
      addTearDown(engine.dispose);
      final dist = engine.distributeThreads(8);
      expect(dist.keys.length, 3);
      final total = dist.values.fold<int>(0, (s, v) => s + v.length);
      expect(total, 8);
      expect(engine.distributeThreads(8), equals(dist));
      expect(engine.mirrorUrls, hasLength(3));
    });

    test('reallocates threads away from a slow mirror', () {
      final failover = MirrorFailover(['https://fast/f', 'https://slow/f']);
      final engine = MirrorParallelEngine(
        ['https://fast/f', 'https://slow/f'],
        failover: failover,
      );
      addTearDown(engine.dispose);

      engine.reportMirrorSpeed('https://fast/f', 1000000);
      engine.reportMirrorSpeed('https://slow/f', 1000);

      final dist = engine.distributeThreads(8);
      expect(dist.containsKey('https://fast/f'), isTrue);
      expect(dist['https://fast/f']!.length, 8);
      expect(dist.containsKey('https://slow/f'), isFalse);
    });

    test('reportMirrorSpeed keeps at most maxMirrorStates entries', () {
      final engine = MirrorParallelEngine(['https://a/f']);
      addTearDown(engine.dispose);
      for (var i = 0; i < 60; i++) {
        engine.reportMirrorSpeed('https://m$i/f', i.toDouble());
      }
      expect(engine.distributeThreads(4), isNotEmpty);
    });
  });

  group('MirrorFailover', () {
    test('empty list is handled', () {
      final failover = MirrorFailover([]);
      expect(failover.activeUrl, '');
      expect(failover.hasAlternatives, isFalse);
      expect(failover.advance(), isNull);
      expect(failover.advance('https://x'), isNull);
    });

    test('filters invalid schemes and tracks alternatives', () {
      final failover = MirrorFailover([
        'ftp://bad/f',
        'https://good/f',
        'invalid',
      ]);
      expect(failover.activeUrl, 'https://good/f');
      expect(failover.hasAlternatives, isFalse);
      expect(failover.remainingAlternatives, 0);
    });

    test('advance moves to an alternative and counts switches', () {
      final failover = MirrorFailover([
        'https://m1/f',
        'https://m2/f',
      ]);
      final next = failover.advance();
      expect(next, isNotNull);
      expect(failover.mirrorSwitches, 1);
    });

    test('advance de-races when the failed url is not the active one', () {
      final failover = MirrorFailover(['https://m1/f', 'https://m2/f']);
      expect(failover.advance('https://not-active/f'), 'https://m1/f');
      expect(failover.mirrorSwitches, 0);
    });

    test('advanceAsync serializes and returns a mirror', () async {
      final failover = MirrorFailover(['https://m1/f', 'https://m2/f']);
      final next = await failover.advanceAsync();
      expect(next, isNotNull);
    });

    test('reportSuccess records a success for the active url', () async {
      final failover = MirrorFailover(['https://m1/f']);
      await failover.reportSuccess(speedBps: 500);
      expect(MirrorHealthStore.instance.getPersistedSpeed('https://m1/f'), 500);
    });

    test('reportSuccess is a no-op for an empty list', () async {
      final failover = MirrorFailover([]);
      await failover.reportSuccess();
    });

    test('reportSlowMirror switches when the slow mirror is active', () {
      final failover = MirrorFailover(['https://slow/f', 'https://fast/f']);
      failover.reportSlowMirror('https://slow/f', 'https://fast/f');
      expect(failover.activeUrl, 'https://fast/f');
      expect(failover.mirrorSwitches, 1);
    });

    test('run succeeds on the first candidate', () async {
      final failover = MirrorFailover(['https://ok/f']);
      var calls = 0;
      final url = await failover.run((u) async => calls++);
      expect(url, 'https://ok/f');
      expect(calls, 1);
    });

    test('run returns null on a non-retryable 4xx client error', () async {
      final failover = MirrorFailover(['https://bad/f']);
      final url = await failover.run((u) async {
        throw DioException(
          requestOptions: RequestOptions(path: u),
          response: Response(
            requestOptions: RequestOptions(path: u),
            statusCode: 404,
          ),
        );
      });
      expect(url, isNull);
    });

    test('run retries then returns null when all attempts fail', () async {
      final failover = MirrorFailover(['https://bad/f']);
      final url = await failover.run((u) async => throw StateError('nope'));
      expect(url, isNull);
    });
  });

  group('orderMirrorUrls', () {
    test('places primary first and drops non-http urls', () {
      final ordered = orderMirrorUrls(
        ['ftp://bad/f', 'https://m2/f', 'https://m1/f'],
        primary: 'https://m1/f',
      );
      expect(ordered.first, 'https://m1/f');
      expect(ordered, isNot(contains('ftp://bad/f')));
    });

    test('ranks faster mirrors ahead of slower ones', () async {
      await MirrorHealthStore.instance
          .recordSuccess('https://fast/f', speedBps: 10000);
      await MirrorHealthStore.instance
          .recordSuccess('https://slow/f', speedBps: 100);
      final ordered = orderMirrorUrls(['https://slow/f', 'https://fast/f']);
      expect(ordered.first, 'https://fast/f');
    });
  });

  group('MirrorSelector facade', () {
    test('exposes manager/failover and delegates dispose + race', () async {
      final selector = MirrorSelector(['https://a/f', 'https://b/f']);
      expect(selector.manager.allUrls, hasLength(2));
      final result = await MirrorSelector.raceMirrors<String>(
          ['https://only/f'], (u, t) async => 'x');
      expect(result, 'x');
      await selector.dispose();
    });
  });
}
