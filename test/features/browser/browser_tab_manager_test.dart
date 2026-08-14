import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/browser/services/tab_manager.dart';
import 'package:dmx/features/browser/models/browser_tab.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TabManager Unit Tests', () {
    late TabManager tabManager;
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
      tabCounter = 0;
      tabManager = TabManager(
        isActive: () => true,
        createTab: dummyCreateTab,
        resolveDatabase: () => throw UnimplementedError(),
        fallbackTitle: () => 'New Tab',
        cleanupTabState: (_) {},
        syncUrlController: () {},
        updateNavState: () {},
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

    test('closeTab falls back to LRU history or adjacent index atomically', () {
      tabManager.openInNewTab('https://tab1.com', switchToTab: true);
      tabManager.openInNewTab('https://tab2.com', switchToTab: true);
      tabManager.openInNewTab('https://tab3.com', switchToTab: true);

      expect(tabManager.currentIndex, equals(2));
      final closedTabId = tabManager.activeTab!.id;

      tabManager.closeTab(closedTabId);
      expect(tabManager.tabs.length, equals(2));
      expect(tabManager.activeTab!.url, equals('https://tab2.com'));
    });

    test('evictStaleAdTabs cleans up stale ad tabs without evicting active tab',
        () {
      tabManager.openInNewTab('https://main.com', switchToTab: true);
      for (int i = 0; i < 5; i++) {
        tabManager.openInNewTab(
          'https://ad$i.com',
          switchToTab: false,
          origin: TabOrigin.adOrPopup,
        );
      }

      tabManager.evictStaleAdTabs();
      expect(tabManager.activeTab!.url, equals('https://main.com'));
      final adTabs =
          tabManager.tabs.where((t) => t.origin == TabOrigin.adOrPopup).length;
      expect(adTabs, lessThanOrEqualTo(3));
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
  });
}
