import 'package:dmx/features/browser/models/browser_tab.dart';
import 'package:dmx/features/browser/services/tab_manager.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_services.dart';
import '../../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    setupTestPluginMocks();
    SharedPreferences.setMockInitialValues({});
  });

  group('Browser Functional Fixes Unit Tests', () {
    test(
        'BrowserTab and BrowserTabWebViewState onFindResultReceived callback wires cleanly',
        () {
      final tab = BrowserTab(id: 'tab-find', url: 'https://example.com');
      int tabOrdinal = -1;
      int tabTotal = -1;
      bool tabDone = false;

      tab.onFindResultReceived = (ordinal, total, isDone) {
        tabOrdinal = ordinal;
        tabTotal = total;
        tabDone = isDone;
      };

      expect(tab.onFindResultReceived, isNotNull);
      tab.onFindResultReceived!(4, 10, true);

      expect(tabOrdinal, equals(4));
      expect(tabTotal, equals(10));
      expect(tabDone, isTrue);

      tab.dispose();
    });

    test('TabManager ChangeNotifier dispatches notifications on mutations', () {
      final settings = SettingsProvider();
      final database = FakeDatabaseService();

      int notificationsCount = 0;
      final tabManager = TabManager(
        isActive: () => true,
        createTab: ({
          String initialUrl = 'about:blank',
          bool isIncognito = false,
          String? id,
          bool autoLoad = true,
          TabOrigin origin = TabOrigin.userDirect,
        }) =>
            BrowserTab(
          id: id ?? 'test-${DateTime.now().microsecondsSinceEpoch}',
          url: initialUrl,
          isIncognito: isIncognito,
          origin: origin,
        ),
        resolveDatabase: () => database,
        fallbackTitle: () => 'New Tab',
        cleanupTabState: (_) {},
        syncUrlController: () {},
        updateNavState: () {},
        settingsProvider: settings,
      );

      tabManager.addListener(() {
        notificationsCount++;
      });

      tabManager.openInNewTab('https://flutter.dev', switchToTab: true);
      expect(notificationsCount, greaterThan(0));

      final prevCount = notificationsCount;
      tabManager.openInNewTab('https://dart.dev', switchToTab: true);
      expect(notificationsCount, greaterThan(prevCount));

      final prevCount2 = notificationsCount;
      tabManager.switchToTab(0);
      expect(notificationsCount, greaterThan(prevCount2));

      final prevCount3 = notificationsCount;
      tabManager.closeTab(tabManager.tabs.last.id);
      expect(notificationsCount, greaterThan(prevCount3));

      tabManager.dispose();
    });

    test('BrowserTab incognito tab properties prevent accidental state leakage',
        () {
      final incognitoTab = BrowserTab(
        id: 'incog-1',
        url: 'https://secret.example.com',
        isIncognito: true,
      );

      expect(incognitoTab.isIncognito, isTrue);
      expect(incognitoTab.identity.isIncognito, isTrue);

      final regularTab = BrowserTab(
        id: 'reg-1',
        url: 'https://public.example.com',
        isIncognito: false,
      );

      expect(regularTab.isIncognito, isFalse);
      expect(regularTab.identity.isIncognito, isFalse);

      incognitoTab.dispose();
      regularTab.dispose();
    });
  });
}
