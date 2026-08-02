import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dmx/features/browser/services/site_settings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SiteSettingsStore', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      SiteSettingsStore.clearCache();
    });

    test('getForHost returns default SiteSettings for unconfigured host', () async {
      final settings = await SiteSettingsStore.getForHost('example.com');
      expect(settings.desktopMode, isNull);
      expect(settings.adBlockEnabled, isNull);
    });

    test('updateForHost persists and retrieves settings', () async {
      const host = 'github.com';
      const settings = SiteSettings(
        desktopMode: true,
        adBlockEnabled: false,
        zoomLevel: 1.2,
      );

      await SiteSettingsStore.updateForHost(host, settings);
      final retrieved = await SiteSettingsStore.getForHost(host);

      expect(retrieved.desktopMode, isTrue);
      expect(retrieved.adBlockEnabled, isFalse);
      expect(retrieved.zoomLevel, equals(1.2));
    });
  });
}
