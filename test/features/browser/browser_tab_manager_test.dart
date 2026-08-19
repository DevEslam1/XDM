import 'package:dmx/features/browser/models/browser_tab.dart';
import 'package:dmx/features/browser/services/tab_manager.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TabManager Unit Tests', () {
    late TabManager tabManager;
    late SettingsProvider settings;
    int tabCounter = 0;

    BrowserTab dummyCreateTab({
      String initialUrl = 'about:blank',
      bool isIncognito = false,
      String? id,
      bool autoLoad = true,
      TabOrigin origin = TabOrigin.userDirect,
    }) {
      tabCounter++;
      final tabId = id ?? 'tab_$tabCounter';
      return BrowserTab(
        id: tabId,
        url: initialUrl == 'about:blank' ? '' : initialUrl,
        title: 'Tab $tabId',
        isIncognito: isIncognito,
        isHome: initialUrl == 'about:blank' || initialUrl.isEmpty,
        origin: origin,
      );
    }

    setUp(() {
      setupTestPluginMocks();
      SharedPreferences.setMockInitialValues({});
      settings = SettingsProvider();
      tabCounter = 0;
      tabManager = TabManager(
        isActive: () => true,
        createTab: dummyCreateTab,
        resolveDatabase: () => throw UnimplementedError(),
        fallbackTitle: () => 'New Tab',
        cleanupTabState: (_) {},
        syncUrlController: () {},
        updateNavState: () {},
        settingsProvider: settings,
      );
    });

    test('Initial tab manager opens single tab on restore fallback', () async {
      await tabManager.restoreTabs();
      expect(tabManager.tabs.length, equals(1));
      expect(tabManager.currentIndex, equals(0));
      expect(tabManager.activeTab, isNotNull);
    });

    test(
        'openInNewTab with switchToTab false loads in background without stealing focus',
        () {
      tabManager.openInNewTab('https://example.com', switchToTab: true);
      expect(tabManager.currentIndex, equals(0));
      expect(tabManager.tabs.length, equals(1));

      tabManager.openInNewTab('https://ad.com',
          switchToTab: false, origin: TabOrigin.adOrPopup);
      expect(tabManager.tabs.length, equals(2));
      expect(tabManager.currentIndex, equals(0));
      expect(tabManager.activeTab!.url, equals('https://example.com'));
    });

    test('max unvisited ad/popup tabs are capped at 3', () {
      tabManager.openInNewTab('https://main.com', switchToTab: true);

      // Open 4 ad tabs sequentially in background
      tabManager.openInNewTab('https://ad1.com',
          switchToTab: false, origin: TabOrigin.adOrPopup);
      tabManager.openInNewTab('https://ad2.com',
          switchToTab: false, origin: TabOrigin.adOrPopup);
      tabManager.openInNewTab('https://ad3.com',
          switchToTab: false, origin: TabOrigin.adOrPopup);
      tabManager.openInNewTab('https://ad4.com',
          switchToTab: false, origin: TabOrigin.adOrPopup);

      // Main tab should still be active
      expect(tabManager.activeTab!.url, equals('https://main.com'));
      final adTabs = tabManager.tabs
          .where((t) => t.origin == TabOrigin.adOrPopup)
          .toList();
      expect(adTabs.length, lessThanOrEqualTo(3));
    });

    test(
        'incognito tabs are isolated, cleaned up on close, and never persisted (B-03/B-04)',
        () {
      bool cleanedUp = false;
      final customManager = TabManager(
        isActive: () => true,
        createTab: dummyCreateTab,
        resolveDatabase: () => throw UnimplementedError(),
        fallbackTitle: () => 'New Tab',
        cleanupTabState: (tabId) {
          cleanedUp = true;
        },
        syncUrlController: () {},
        updateNavState: () {},
        settingsProvider: settings,
      );

      // Open a normal tab and an incognito tab
      customManager.openInNewTab('https://normal.com', isIncognito: false);
      customManager.openInNewTab('https://private.com', isIncognito: true);

      expect(customManager.tabs.length, equals(2));
      expect(customManager.tabs[1].isIncognito, isTrue);

      // Close the incognito tab
      final incognitoId = customManager.tabs[1].id;
      customManager.closeTab(incognitoId);

      expect(cleanedUp, isTrue);
      expect(customManager.tabs.length, equals(1));
      expect(customManager.tabs.first.isIncognito, isFalse);
    });

    test('evictInactiveTabs caps active non-suspended tabs to 3 LRU tabs', () {
      for (int i = 0; i < 6; i++) {
        tabManager.openInNewTab('https://site$i.com', switchToTab: true);
      }
      expect(tabManager.tabs.length, equals(6));
      expect(tabManager.currentIndex, equals(5));

      // Invoke eviction
      tabManager.evictInactiveTabs(keepRecentCount: 3);

      final nonSuspended =
          tabManager.tabs.where((t) => !t.isSuspended).toList();
      expect(nonSuspended.length, lessThanOrEqualTo(3));

      // Oldest tabs must be marked suspended
      expect(tabManager.tabs[0].isSuspended, isTrue);
      expect(tabManager.tabs[1].isSuspended, isTrue);
      expect(tabManager.tabs[2].isSuspended, isTrue);
      // Active tab (site5) must remain active
      expect(tabManager.activeTab!.isSuspended, isFalse);
    });

    test('Max tabs cap evicts least recently visited inactive tab', () {
      final max = tabManager.effectiveMaxTabs;
      for (int i = 0; i < max; i++) {
        tabManager.openInNewTab('https://tab$i.com', switchToTab: true);
      }
      expect(tabManager.tabs.length, equals(max));

      // Opening next tab must evict the LRU inactive tab (tab0)
      tabManager.openInNewTab('https://tab$max.com', switchToTab: true);
      expect(tabManager.tabs.length, equals(max));
      expect(
          tabManager.tabs.any((t) => t.url == 'https://tab$max.com'), isTrue);
      expect(tabManager.tabs.any((t) => t.url == 'https://tab0.com'), isFalse);
    });

    test('onMemoryPressure closes all inactive tabs', () {
      for (int i = 0; i < 5; i++) {
        tabManager.openInNewTab('https://site$i.com', switchToTab: true);
      }
      expect(tabManager.tabs.length, equals(5));
      expect(tabManager.activeTab?.url, equals('https://site4.com'));

      tabManager.onMemoryPressure();

      expect(tabManager.tabs.length, equals(1));
      expect(tabManager.activeTab?.url, equals('https://site4.com'));
    });
  });
}
