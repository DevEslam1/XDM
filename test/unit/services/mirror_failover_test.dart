import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dmx/core/services/mirror_failover.dart';
import 'package:dmx/core/services/mirror_health_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await MirrorHealthStore.init();
  });

  group('MirrorHealthStore', () {
    test('blacklists a mirror after 5 failures with 6h TTL', () async {
      final url = 'https://mirror-a.com/file';
      for (var i = 0; i < 5; i++) {
        await MirrorHealthStore.recordFailure(url, statusCode: 500);
      }
      expect(MirrorHealthStore.isBlacklisted(url), isTrue);
      expect(MirrorHealthStore.getFailureCount(url), 5);
    });

    test('success resets failures and clears blacklist', () async {
      final url = 'https://mirror-b.com/file';
      for (var i = 0; i < 5; i++) {
        await MirrorHealthStore.recordFailure(url);
      }
      expect(MirrorHealthStore.isBlacklisted(url), isTrue);

      await MirrorHealthStore.recordSuccess(url, speedBps: 1000000);
      expect(MirrorHealthStore.isBlacklisted(url), isFalse);
      expect(MirrorHealthStore.getFailureCount(url), 0);
      expect(MirrorHealthStore.getPersistedSpeed(url), 1000000);
    });

    test('health data persists across restarts', () async {
      await MirrorHealthStore.recordFailure('https://m1.com/x');
      await MirrorHealthStore.recordFailure('https://m1.com/x');
      await MirrorHealthStore.recordSuccess('https://m2.com/x', speedBps: 42);

      // Re-init simulates an app restart (same SharedPreferences backing).
      await MirrorHealthStore.init();
      expect(MirrorHealthStore.getFailureCount('https://m1.com/x'), 2);
      expect(MirrorHealthStore.getPersistedSpeed('https://m2.com/x'), 42);
    });

    test('clear removes all persisted data', () async {
      await MirrorHealthStore.recordFailure('https://m1.com/x');
      await MirrorHealthStore.clear();
      expect(MirrorHealthStore.getFailureCount('https://m1.com/x'), 0);
    });
  });

  group('orderMirrorUrls', () {
    test('primary first, then speed-ranked, blacklisted last', () async {
      final slow = 'https://slow.com/file';
      final fast = 'https://fast.com/file';
      final black = 'https://black.com/file';
      final primary = 'https://primary.com/file';

      await MirrorHealthStore.recordSuccess(slow, speedBps: 100);
      await MirrorHealthStore.recordSuccess(fast, speedBps: 900000);
      for (var i = 0; i < 5; i++) {
        await MirrorHealthStore.recordFailure(black);
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
      final black = 'https://black.com';
      for (var i = 0; i < 5; i++) {
        await MirrorHealthStore.recordFailure(black);
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
      expect(MirrorHealthStore.getFailureCount('https://m1.com'), 1);
      expect(MirrorHealthStore.getFailureCount('https://m2.com'), 1);
    });
  });
}
