import 'package:dmx/core/services/engines/server_profile_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ServerProfileManager', () {
    setUp(() {
      ServerProfileManager.clear();
    });

    test('identifies CDN hosts correctly', () {
      final cdnProfile = ServerProfileManager.getProfile(
          'https://files.cloudflare.com/app.apk');
      expect(cdnProfile.isCdn, isTrue);

      final normalProfile =
          ServerProfileManager.getProfile('https://my-server.org/file.zip');
      expect(normalProfile.isCdn, isFalse);
    });

    test('CDN hosts get shorter retry delays', () {
      final delay =
          ServerProfileManager.getRetryDelay('https://cdn.example.com/file', 1);
      expect(delay.inSeconds, lessThanOrEqualTo(10));
    });

    test('rate limited servers get longer retry delays', () {
      ServerProfileManager.recordFailure(
        'https://api.example.com/file',
        statusCode: 429,
        retryAfter: null,
      );

      final delay =
          ServerProfileManager.getRetryDelay('https://api.example.com/file', 1);
      expect(delay.inSeconds, greaterThanOrEqualTo(30));
    });

    test('Retry-After header is respected', () {
      ServerProfileManager.recordFailure(
        'https://custom.example.com/file',
        statusCode: 429,
        retryAfter: '45',
      );

      final delay = ServerProfileManager.getRetryDelay(
          'https://custom.example.com/file', 1);
      expect(delay.inSeconds, equals(45));
    });
  });
}
