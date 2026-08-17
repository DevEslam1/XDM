import 'package:dmx/features/browser/models/browser_tab.dart';
import 'package:dmx/features/browser/services/tab_manager.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Browser Tab Memory Eviction Test (FIX-17 / FIX-35)', () {
    late TabManager tabManager;
    late SettingsProvider settings;
    final List<BrowserTab> createdTabs = [];

    setUp(() {
      setupTestPluginMocks();
      SharedPreferences.setMockInitialValues({});
      settings = SettingsProvider();
      createdTabs.clear();
      tabManager = TabManager(
        isActive: () => true,
        createTab: ({
          String initialUrl = '',
          bool isIncognito = false,
          String? id,
          bool autoLoad = true,
          TabOrigin origin = TabOrigin.userDirect,
        }) {
          final tabId = id ?? 'tab_${createdTabs.length + 1}';
          final tab = BrowserTab(
            id: tabId,
            url: initialUrl,
            title: 'Tab $tabId',
            isIncognito: isIncognito,
            origin: origin,
            isHome: false,
          );
          createdTabs.add(tab);
          return tab;
        },
        resolveDatabase: () => throw UnimplementedError(),
        fallbackTitle: () => 'New Tab',
        cleanupTabState: (_) {},
        syncUrlController: () {},
        updateNavState: () {},
        settingsProvider: settings,
      );
    });

    test('evictInactiveTabs suspends tabs beyond keepRecentCount', () {
      // Add 5 tabs
      tabManager.openInNewTab('https://example.com/1', switchToTab: true);
      tabManager.openInNewTab('https://example.com/2', switchToTab: true);
      tabManager.openInNewTab('https://example.com/3', switchToTab: true);
      tabManager.openInNewTab('https://example.com/4', switchToTab: true);
      tabManager.openInNewTab('https://example.com/5', switchToTab: true);

      expect(tabManager.tabs.length, equals(5));
      expect(tabManager.currentIndex, equals(4)); // On tab 5

      // Tab 5 is active. Tab 4, 3 are in recent history. Tabs 1 and 2 should be eligible for eviction.
      tabManager.evictInactiveTabs(keepRecentCount: 3);

      final tabs = tabManager.tabs;
      // Active tab (tab 5) should not be suspended
      expect(tabs[4].isSuspended, isFalse);

      // Verify that at least some background tabs are marked suspended
      final suspendedCount = tabs.where((t) => t.isSuspended).length;
      expect(suspendedCount, greaterThanOrEqualTo(2));
    });
  });
}
