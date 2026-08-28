import 'package:dmx/features/browser/data/browser_preferences_repository.dart';
import 'package:dmx/features/browser/services/browser_download_coordinator.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/fake_services.dart';
import '../../../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BrowserDownloadCoordinator Tests [Browser 10/10]', () {
    late DownloadProvider downloadProvider;
    late SettingsProvider settingsProvider;
    late BrowserPreferencesRepository prefsRepo;
    late FakeDatabaseService database;

    setUp(() async {
      setupTestPluginMocks();
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      settingsProvider = createMockSettingsProvider();
      await settingsProvider.load();
      database = FakeDatabaseService();
      downloadProvider = DownloadProvider(
        databaseService: database,
        settingsProvider: settingsProvider,
        enableBackgroundTimers: false,
      );
      prefsRepo = BrowserPreferencesRepository(prefs);
    });

    test(
        'Coordinator initializes mediaSniffer and downloadInterceptor properly',
        () async {
      final coordinator = BrowserDownloadCoordinator(
        downloadProvider: downloadProvider,
        settingsProvider: settingsProvider,
        prefsRepo: prefsRepo,
        getActiveTab: () => null,
        containsTab: (_) => false,
        onStateChanged: () {},
      );

      expect(coordinator.mediaSniffer, isNotNull);
      expect(coordinator.downloadInterceptor, isNotNull);

      // Allow async _init to complete
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(coordinator.isSnifferEnabled, isTrue);

      await coordinator.setSnifferEnabled(false);
      expect(coordinator.isSnifferEnabled, isFalse);

      coordinator.dispose();
    });
  });
}
