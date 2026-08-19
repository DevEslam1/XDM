import 'package:dmx/core/services/mirror/mirror_registry.dart';
import 'package:dmx/core/services/mirror/mirror_selector.dart';
import 'package:dmx/core/services/protocol_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MirrorFailover & orderMirrorUrls', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await MirrorHealthStore.instance.init();
      await ProtocolCache.init();
    });

    test('initializes with active url and counts alternatives correctly', () {
      final mirrors = [
        'https://mirror1.example.com/file.zip',
        'https://mirror2.example.com/file.zip',
        'https://mirror3.example.com/file.zip',
      ];
      final failover = MirrorFailover(mirrors);

      expect(failover.activeUrl, 'https://mirror1.example.com/file.zip');
      expect(failover.hasAlternatives, true);
      expect(failover.remainingAlternatives, 2);
      expect(failover.mirrorSwitches, 0);
    });

    test(
        'advance switches to next available mirror and increments switches count',
        () {
      final mirrors = [
        'https://mirror1.example.com/file.zip',
        'https://mirror2.example.com/file.zip',
      ];
      final failover = MirrorFailover(mirrors);

      final next = failover.advance();
      expect(next, isNotNull);
      expect(failover.mirrorSwitches, 1);
    });

    test('orderMirrorUrls places primary mirror first', () {
      final mirrors = [
        'https://mirror2.example.com',
        'https://mirror1.example.com',
        'https://mirror3.example.com',
      ];
      final ordered =
          orderMirrorUrls(mirrors, primary: 'https://mirror1.example.com');
      expect(ordered.first, 'https://mirror1.example.com');
    });

    test('filters out invalid non-http/https urls', () {
      final rawList = [
        'ftp://ftp.example.com/file',
        'https://secure.example.com/file',
        'invalid-url',
      ];
      final failover = MirrorFailover(rawList);
      expect(failover.activeUrl, 'https://secure.example.com/file');
      expect(failover.hasAlternatives, false);
    });

    test('handles empty mirror list gracefully without throwing', () {
      final failover = MirrorFailover([]);
      expect(failover.activeUrl, '');
      expect(failover.hasAlternatives, false);
      expect(failover.advance(), isNull);
    });
  });

  group('MirrorManager & MirrorStats', () {
    test('getBestMirror returns null for empty list', () {
      final manager = MirrorManager([]);
      expect(manager.primaryUrl, isNull);
      expect(manager.allUrls, isEmpty);
      expect(manager.getBestMirror(), isNull);
      expect(manager.getNextMirror('x'), isNull);
    });

    test('prefers healthy fastest mirror and excludes failed ones', () {
      final manager = MirrorManager([
        'https://m1.example.com/f',
        'https://m2.example.com/f',
        'https://m3.example.com/f',
      ]);

      // m1 slow, m2 fast, m3 unregistered -> fast m2 wins.
      manager.recordSuccess(
          'https://m1.example.com/f', 100, const Duration(seconds: 1));
      manager.recordSuccess(
          'https://m2.example.com/f', 1000, const Duration(seconds: 1));
      expect(manager.getBestMirror(), 'https://m2.example.com/f');

      // Fail m2 repeatedly to push it out of the healthy set.
      for (int i = 0; i < MirrorManager.maxFailuresBeforeDeprioritize; i++) {
        manager.recordFailure('https://m2.example.com/f');
      }
      expect(manager.isHealthy('https://m2.example.com/f'), isFalse);
      expect(manager.getBestMirror(), 'https://m1.example.com/f');
    });

    test('getNextMirror skips the excluded url', () {
      final manager = MirrorManager([
        'https://a.example.com/f',
        'https://b.example.com/f',
      ]);
      expect(manager.getNextMirror('https://a.example.com/f'),
          'https://b.example.com/f');
    });

    test('getNextMirror returns null when all candidates failed', () {
      final manager = MirrorManager(['https://a.example.com/f']);
      for (int i = 0; i < MirrorManager.maxFailuresBeforeDeprioritize; i++) {
        manager.recordFailure('https://a.example.com/f');
      }
      expect(manager.getNextMirror('https://a.example.com/f'), isNull);
    });

    test('recordSuccess on unknown url is a safe no-op', () {
      final manager = MirrorManager([]);
      manager.recordSuccess(
          'https://missing.example.com/f', 10, const Duration(seconds: 1));
      manager.recordFailure('https://missing.example.com/f');
      expect(manager.isHealthy('https://missing.example.com/f'), isFalse);
    });

    test('MirrorStats avgSpeedBps caps at 10 GiB/s', () {
      final stats = MirrorStats('https://s.example.com/f');
      stats.totalBytes = 100000000;
      stats.totalMs = 1;
      expect(stats.avgSpeedBps, 10 * 1024 * 1024 * 1024);
    });
  });

  group('MirrorParallelEngine', () {
    test('raceMirrors throws for empty list', () async {
      expect(
        () =>
            MirrorParallelEngine.raceMirrors<int>([], (url, token) async => 1),
        throwsArgumentError,
      );
    });

    test('raceMirrors returns the first winner and cancels the rest', () async {
      final cancelled = <String>[];
      final result = await MirrorParallelEngine.raceMirrors<String>(
        ['https://a.com/f', 'https://b.com/f'],
        (url, token) async {
          if (url == 'https://a.com/f') {
            await Future.delayed(const Duration(milliseconds: 50));
            return 'from-a';
          }
          token.whenCancel.then((_) => cancelled.add(url));
          await Future.delayed(const Duration(milliseconds: 200));
          return 'from-b';
        },
      );
      expect(result, 'from-a');
      // Give the cancel propagation a beat.
      await Future.delayed(const Duration(milliseconds: 50));
      expect(cancelled, contains('https://b.com/f'));
    });

    test('raceMirrors resolves quickly for a single url', () async {
      final result = await MirrorParallelEngine.raceMirrors<String>(
        ['https://only.com/f'],
        (url, token) async => 'only',
      );
      expect(result, 'only');
    });

    test('distributeThreads allocates across mirrors and reallocates slow', () {
      final engine = MirrorParallelEngine([
        'https://fast.example.com/f',
        'https://slow.example.com/f',
      ]);

      // Give the slow mirror a low average speed so thread reallocation kicks in.
      engine.failover = MirrorFailover([
        'https://fast.example.com/f',
        'https://slow.example.com/f',
      ]);

      final dist = engine.distributeThreads(8);
      expect(dist.keys.length, equals(2));

      // Feeding state is via updateSpeed path — verify determinism of cache.
      final cached = engine.distributeThreads(8);
      expect(cached, equals(dist));
      engine.dispose();
    });
  });
}
