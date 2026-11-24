
import 'package:dio/dio.dart';
import 'package:dmx/core/services/mirror/mirror_registry.dart';
import 'package:dmx/core/services/mirror/mirror_selector.dart';
import 'package:dmx/core/services/protocol_cache.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await MirrorHealthStore.instance.init();
    await ProtocolCache.init();
  });

  group('MirrorRaceException', () {
    test('toString includes errors when present', () {
      expect(const MirrorRaceException('boom').toString(),
          'MirrorRaceException: boom');
      expect(const MirrorRaceException('boom', [1, 2]).toString(),
          contains('2 errors'));
    });
  });

  group('MirrorManager extras', () {
    test('getNextMirror returns null when no healthy candidate remains', () {
      final manager = MirrorManager(['https://a/f', 'https://b/f']);
      for (var i = 0; i < MirrorManager.maxFailuresBeforeDeprioritize; i++) {
        manager.recordFailure('https://b/f');
      }
      expect(manager.getNextMirror('https://a/f'), isNull);
    });

    test('getNextMirror returns a healthy alternative', () {
      final manager =
          MirrorManager(['https://a/f', 'https://b/f', 'https://c/f']);
      expect(manager.getNextMirror('https://a/f'), isNotNull);
    });

    test('recordSuccess updates the rolling latency average', () {
      final manager = MirrorManager(['https://a/f']);
      manager.recordSuccess(
          'https://a/f', 100, const Duration(milliseconds: 100));
      manager.recordSuccess(
          'https://a/f', 200, const Duration(milliseconds: 300));
      expect(manager.isHealthy('https://a/f'), isTrue);
    });
  });

  group('raceMirrors extras', () {
    test('single url honors a parent cancel token', () async {
      final parent = CancelToken();
      final result = await MirrorParallelEngine.raceMirrors<int>(
        ['https://only/f'],
        (u, t) async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return 1;
        },
        parentCancelToken: parent,
      );
      expect(result, 1);
    });

    test('multi url propagates a synchronous fetch throw', () async {
      var calls = 0;
      await expectLater(
        MirrorParallelEngine.raceMirrors<int>(
          ['https://a/f', 'https://b/f'],
          (u, t) {
            calls++;
            throw StateError('sync');
          },
        ),
        throwsA(isA<MirrorRaceException>()),
      );
      expect(calls, greaterThan(0));
    });
  });

  group('MirrorParallelEngine debounce', () {
    test('reportMirrorSpeed schedules a cache invalidation', () {
      fakeAsync((async) {
        final engine = MirrorParallelEngine(['https://a/f', 'https://b/f']);
        engine.reportMirrorSpeed('https://a/f', 500);
        async.elapse(const Duration(seconds: 3));
        expect(engine.distributeThreads(2), isNotEmpty);
        engine.dispose();
      });
    });
  });

  group('MirrorFailover extras', () {
    test('protocolHint starts null', () {
      final failover = MirrorFailover(['https://a/f', 'https://b/f']);
      expect(failover.protocolHint, isNull);
    });

    test('a single-mirror failover de-races a repeated failure', () {
      final failover = MirrorFailover(['https://only/f']);
      expect(failover.advance('https://only/f'), isNull);
      expect(failover.advance('https://only/f'), 'https://only/f');
    });

    test('a rapid second advance with no failed url is de-raced', () {
      final failover = MirrorFailover(['https://a/f', 'https://b/f']);
      final first = failover.advance();
      final second = failover.advance();
      expect(first, isNotNull);
      expect(second, failover.activeUrl);
    });

    test('run falls through to the next candidate on failure', () async {
      await MirrorHealthStore.instance
          .recordSuccess('https://bad/f', speedBps: 100000);
      await MirrorHealthStore.instance
          .recordSuccess('https://good/f', speedBps: 1);
      final failover = MirrorFailover(['https://bad/f', 'https://good/f']);
      final url = await failover.run((u) async {
        if (u == 'https://bad/f') throw StateError('nope');
      });
      expect(url, 'https://good/f');
    });
  });
}
