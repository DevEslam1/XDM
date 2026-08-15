import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/mirror/mirror_registry.dart';
import 'package:dmx/core/services/mirror/mirror_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await MirrorHealthStore.instance.clear();
    await MirrorHealthStore.instance.init();
  });

  group('MirrorHealthStore', () {
    test('blacklists a mirror after 5 failures with 6h TTL', () async {
      const url = 'https://mirror-a.com/file';
      for (var i = 0; i < 5; i++) {
        await MirrorHealthStore.instance.recordFailure(url, statusCode: 500);
      }
      expect(MirrorHealthStore.instance.isBlacklisted(url), isTrue);
      expect(MirrorHealthStore.instance.getFailureCount(url), 5);
    });

    test('success resets failures and clears blacklist', () async {
      const url = 'https://mirror-b.com/file';
      for (var i = 0; i < 5; i++) {
        await MirrorHealthStore.instance.recordFailure(url);
      }
      expect(MirrorHealthStore.instance.isBlacklisted(url), isTrue);

      await MirrorHealthStore.instance.recordSuccess(url, speedBps: 1000000);
      expect(MirrorHealthStore.instance.isBlacklisted(url), isFalse);
      expect(MirrorHealthStore.instance.getFailureCount(url), 0);
      expect(MirrorHealthStore.instance.getPersistedSpeed(url), 1000000);
    });

    test('health data persists across restarts', () async {
      await MirrorHealthStore.instance.recordFailure('https://m1.com/x');
      await MirrorHealthStore.instance.recordFailure('https://m1.com/x');
      await MirrorHealthStore.instance.recordSuccess('https://m2.com/x', speedBps: 42);

      // Writes are coalesced; a durable flush persists them to prefs.
      await MirrorHealthStore.instance.flushPending(durable: true);

      // Re-init simulates an app restart (same SharedPreferences backing).
      await MirrorHealthStore.instance.init();
      expect(MirrorHealthStore.instance.getFailureCount('https://m1.com/x'), 2);
      expect(MirrorHealthStore.instance.getPersistedSpeed('https://m2.com/x'), 42);
    });

    test('clear removes all persisted data', () async {
      await MirrorHealthStore.instance.recordFailure('https://m1.com/x');
      await MirrorHealthStore.instance.clear();
      expect(MirrorHealthStore.instance.getFailureCount('https://m1.com/x'), 0);
    });
  });

  group('orderMirrorUrls', () {
    test('primary first, then speed-ranked, blacklisted last', () async {
      const slow = 'https://slow.com/file';
      const fast = 'https://fast.com/file';
      const black = 'https://black.com/file';
      const primary = 'https://primary.com/file';

      await MirrorHealthStore.instance.recordSuccess(slow, speedBps: 100);
      await MirrorHealthStore.instance.recordSuccess(fast, speedBps: 900000);
      for (var i = 0; i < 5; i++) {
        await MirrorHealthStore.instance.recordFailure(black);
      }

      final ordered = orderMirrorUrls(
        [slow, fast, black, primary],
        primary: primary,
      );
      expect(ordered.first, primary);
      expect(ordered.indexOf(fast), lessThan(ordered.indexOf(slow)));
      expect(ordered.last, black);
    });
  });

  group('MirrorFailover', () {
    test('3 mirrors, 1 fails -> auto-switches to next', () async {
      final failover = MirrorFailover([
        'https://m1.com',
        'https://m2.com',
        'https://m3.com',
      ]);
      final attempted = <String>[];

      final succeeded = await failover.run((url) async {
        attempted.add(url);
        if (url == 'https://m1.com') {
          throw DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.connectionError,
          );
        }
      });

      expect(succeeded, 'https://m2.com');
      expect(attempted, ['https://m1.com', 'https://m2.com']);
      expect(failover.mirrorSwitches, 1);
    });

    test('blacklisted mirror is skipped', () async {
      const black = 'https://black.com';
      for (var i = 0; i < 5; i++) {
        await MirrorHealthStore.instance.recordFailure(black);
      }

      final failover = MirrorFailover([
        black,
        'https://good.com',
      ]);
      final attempted = <String>[];

      final succeeded = await failover.run((url) async {
        attempted.add(url);
      });

      expect(succeeded, 'https://good.com');
      expect(attempted, ['https://good.com']);
    });

    test('4xx error -> no mirror retry', () async {
      final failover = MirrorFailover([
        'https://m1.com',
        'https://m2.com',
      ]);
      final attempted = <String>[];

      final succeeded = await failover.run((url) async {
        attempted.add(url);
        throw DioException(
          requestOptions: RequestOptions(path: url),
          type: DioExceptionType.badResponse,
          response: Response(
            requestOptions: RequestOptions(path: url),
            statusCode: 403,
          ),
        );
      });

      expect(succeeded, isNull);
      expect(attempted, ['https://m1.com']);
    });

    test('all mirrors fail -> returns null and records failures', () async {
      final failover = MirrorFailover(['https://m1.com', 'https://m2.com']);

      final succeeded = await failover.run((url) async {
        throw const SocketException('unreachable');
      });

      expect(succeeded, isNull);
      expect(MirrorHealthStore.instance.getFailureCount('https://m1.com'), 1);
      expect(MirrorHealthStore.instance.getFailureCount('https://m2.com'), 1);
    });
  });
}
