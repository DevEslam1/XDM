import 'package:dmx/features/browser/services/site_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SiteSettingsStore', () {
    late SiteSettingsStore store;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      SiteSettingsStore.clearCache();
      store = SiteSettingsStore();
    });

    test('getForHost returns default SiteSettings for unconfigured host',
        () async {
      final settings = await store.getForHost('example.com');
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

      await store.updateForHost(host, settings);
      final retrieved = await store.getForHost(host);

      expect(retrieved.desktopMode, isTrue);
      expect(retrieved.adBlockEnabled, isFalse);
      expect(retrieved.zoomLevel, equals(1.2));
    });
  });
}
