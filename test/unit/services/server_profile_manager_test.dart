import 'package:dmx/core/services/mirror/mirror_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ServerProfileManager', () {
    late ServerProfileManager manager;

    setUp(() {
      manager = ServerProfileManager();
      manager.clear();
    });

    tearDown(() async {
      await manager.dispose();
    });

    test('identifies CDN hosts correctly', () {
      final cdnProfile =
          manager.getProfile('https://files.cloudflare.com/app.apk');
      expect(cdnProfile.isCdn, isTrue);

      final normalProfile =
          manager.getProfile('https://my-server.org/file.zip');
      expect(normalProfile.isCdn, isFalse);
    });

    test('CDN hosts get shorter retry delays', () {
      final delay = manager.getRetryDelay('https://cdn.example.com/file', 1);
      expect(delay.inSeconds, lessThanOrEqualTo(10));
    });

    test('rate limited servers get longer retry delays', () {
      manager.recordFailure(
        'https://api.example.com/file',
        statusCode: 429,
        retryAfter: null,
      );

      final delay = manager.getRetryDelay('https://api.example.com/file', 1);
      expect(delay.inSeconds, greaterThanOrEqualTo(30));
    });

    test('Retry-After header is respected', () {
      manager.recordFailure(
        'https://custom.example.com/file',
        statusCode: 429,
        retryAfter: '45',
      );

      final delay = manager.getRetryDelay('https://custom.example.com/file', 1);
      expect(delay.inSeconds, equals(45));
    });

    test('onMemoryPressure clears profiles older than 1 hour', () {
      final freshProfile = manager.getProfile('https://fresh.example.com/file');
      freshProfile.lastAccess = DateTime.now();

      final oldProfile = manager.getProfile('https://old.example.com/file');
      oldProfile.lastAccess = DateTime.now().subtract(const Duration(hours: 2));

      manager.onMemoryPressure();

      // Old profile was evicted on memory pressure; fetching it creates a fresh profile
      final reloadedProfile =
          manager.getProfile('https://old.example.com/file');
      expect(
        reloadedProfile.lastAccess.difference(DateTime.now()).inSeconds.abs(),
        lessThan(5),
      );
    });
  });
}
