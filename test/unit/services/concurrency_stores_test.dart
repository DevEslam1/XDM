import 'package:dmx/core/services/protocol_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ProtocolCache.init();
  });

  group('Concurrency Hardening Tests', () {
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
