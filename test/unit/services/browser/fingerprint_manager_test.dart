import 'package:dmx/features/browser/services/fingerprint_manager.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FingerprintManager Unit Tests [Browser 10/10]', () {
    late FingerprintManager fingerprintManager;
    late SettingsProvider settings;

    setUp(() async {
      settings = createMockSettingsProvider();
      await settings.load();
      settings.desktopMode = false;
      settings.customUserAgent = '';
      fingerprintManager = FingerprintManager();
    });

    test('resolveUserAgent returns mobile UA by default', () {
      final ua = fingerprintManager.resolveUserAgent(
        isIncognito: false,
        settings: settings,
      );
      expect(ua, equals(FingerprintManager.mobileUserAgent));
    });

    test('resolveUserAgent returns desktop UA when desktopMode is enabled', () {
      settings.desktopMode = true;
      final ua = fingerprintManager.resolveUserAgent(
        isIncognito: false,
        settings: settings,
      );
      expect(ua, equals(FingerprintManager.desktopUserAgent));
    });

    test('resolveUserAgent returns incognito UA when in incognito mode', () {
      settings.desktopMode = false;
      final ua = fingerprintManager.resolveUserAgent(
        isIncognito: true,
        settings: settings,
      );
      expect(ua, equals(FingerprintManager.incognitoUserAgent));
    });

    test('resolveUserAgent respects custom user agent setting', () {
      settings.desktopMode = false;
      settings.customUserAgent = 'CustomBrowser/1.0';
      final ua = fingerprintManager.resolveUserAgent(
        isIncognito: false,
        settings: settings,
      );
      expect(ua, equals('CustomBrowser/1.0'));
    });

    test(
        'fingerprintHideJs contains WebGL, Canvas poisoning and Webdriver protection',
        () {
      const js = FingerprintManager.fingerprintHideJs;
      expect(js.contains('webdriver'), isTrue);
      expect(js.contains('getImageData'), isTrue);
      expect(js.contains('UNMASKED_VENDOR_WEBGL'), isTrue);
      expect(js.contains('UNMASKED_RENDERER_WEBGL'), isTrue);
    });
  });
}
