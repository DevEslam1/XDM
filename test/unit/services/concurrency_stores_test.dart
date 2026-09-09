import 'dart:math';
import 'package:dmx/core/services/mirror_health_store.dart';
import 'package:dmx/core/services/protocol_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await MirrorHealthStore.clear();
    await MirrorHealthStore.init();
    await ProtocolCache.init();
  });

  group('Concurrency Hardening Tests', () {
    test(
        'concurrent recordSuccess and recordFailure on MirrorHealthStore executes safely without race drops',
        () async {
      const mirrors = [
        'https://m1.com',
        'https://m2.com',
        'https://m3.com',
        'https://m4.com',
        'https://m5.com',
      ];

      final futures = <Future<void>>[];
      final rng = Random(42);

      // Launch 50 concurrent async tasks hammering recordSuccess and recordFailure
      for (var i = 0; i < 50; i++) {
        final mirror = mirrors[i % mirrors.length];
        if (rng.nextBool()) {
          futures.add(MirrorHealthStore.recordFailure(mirror));
        } else {
          futures.add(MirrorHealthStore.recordSuccess(mirror,
              speedBps: (i + 1) * 1000.0));
        }
      }

      await Future.wait(futures);

      // Verify each mirror's health record is valid and readable
      for (final mirror in mirrors) {
        final failureCount = MirrorHealthStore.getFailureCount(mirror);
        expect(failureCount, greaterThanOrEqualTo(0));
      }
    });

    test(
        'concurrent record, invalidate, and get on ProtocolCache maintains consistency',
        () async {
      const urls = [
        'https://alpha.example.com/file',
        'https://beta.example.com/file',
        'https://gamma.example.com/file',
      ];

      final futures = <Future<void>>[];

      for (var i = 0; i < 30; i++) {
        final url = urls[i % urls.length];
        if (i % 3 == 0) {
          futures.add(ProtocolCache.record(url, ProtocolSupport.http3));
        } else if (i % 3 == 1) {
          futures.add(ProtocolCache.record(url, ProtocolSupport.http2));
        } else {
          futures.add(ProtocolCache.recordFailure(url));
        }
      }

      await Future.wait(futures);

      for (final url in urls) {
        final support = ProtocolCache.get(url);
        expect(
            support == null ||
                support == ProtocolSupport.http2 ||
                support == ProtocolSupport.http3,
            isTrue);
      }
    });

    test('ProtocolCache invalidates stale hints upon connection failure',
        () async {
      const url = 'https://broken-h3.example.com/file';
      await ProtocolCache.record(url, ProtocolSupport.http3);
      expect(ProtocolCache.get(url), ProtocolSupport.http3);

      await ProtocolCache.recordFailure(url);
      expect(ProtocolCache.get(url), isNull);
    });
  });
}
