import 'package:dmx/core/utils/constants.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('core/utils/constants', () {
    test('kAvailableThreadOptions exposes ordered thread counts', () {
      expect(kAvailableThreadOptions, isNotEmpty);
      expect(kAvailableThreadOptions.first, 1);
      final sorted = [...kAvailableThreadOptions]..sort();
      expect(kAvailableThreadOptions, equals(sorted));
      expect(kAvailableThreadOptions.contains(16), isTrue);
    });

    test('kAppVersion getter and setAppVersion mutate the global version', () {
      final original = kAppVersion;

      setAppVersion('9.9.9+42');
      expect(kAppVersion, '9.9.9+42');

      // Empty values are ignored.
      setAppVersion('');
      expect(kAppVersion, '9.9.9+42');

      setAppVersion(original);
      expect(kAppVersion, original);
    });

    test('developer metadata constants are populated', () {
      expect(kDeveloperName, isNotEmpty);
      expect(kDeveloperTitle, isNotEmpty);
      expect(kDeveloperEmail, contains('@'));
      expect(kDeveloperGithub, isNotEmpty);
      expect(kDeveloperLinkedin, isNotEmpty);
      expect(kDeveloperPhone, isNotEmpty);
    });

    test('backend base urls are https endpoints', () {
      expect(kDefaultBackendBaseUrl, startsWith('https://'));
      expect(kFallbackBackendBaseUrls, isNotEmpty);
      for (final url in kFallbackBackendBaseUrls) {
        expect(url, startsWith('https://'));
      }
    });
  });
}
