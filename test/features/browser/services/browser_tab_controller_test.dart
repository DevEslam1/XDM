import 'package:dmx/features/browser/models/browser_tab.dart';
import 'package:dmx/features/browser/services/browser_tab_controller.dart';
import 'package:dmx/features/browser/services/tab_manager.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BrowserTabController Unit Tests', () {
    late TabManager tabManager;
    late BrowserTabController controller;
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

      controller = BrowserTabController(
        tabManager: tabManager,
        settingsProvider: settings,
      );
    });

    tearDown(() {
      controller.dispose();
    });

    test('openInNewTab adds tabs and updates active index when switchTo is true', () {
      controller.openInNewTab('https://example.com/1', switchTo: true);
      expect(controller.tabs.length, equals(1));
      expect(controller.currentIndex, equals(0));
      expect(controller.activeTab?.url, equals('https://example.com/1'));

      controller.openInNewTab('https://example.com/2', switchTo: true);
      expect(controller.tabs.length, equals(2));
      expect(controller.currentIndex, equals(1));
      expect(controller.activeTab?.url, equals('https://example.com/2'));
    });

    test('switchTab changes the active tab and records lastVisitedAt', () {
      controller.openInNewTab('https://example.com/1', switchTo: true);
      controller.openInNewTab('https://example.com/2', switchTo: true);

      controller.switchTab(0);
      expect(controller.currentIndex, equals(0));
      expect(controller.activeTab?.url, equals('https://example.com/1'));
    });

    test('closeTab moves non-incognito non-home tabs to recentlyClosedTabs', () {
      controller.openInNewTab('https://example.com/article', switchTo: true);
      final tabId = controller.activeTab!.id;

      controller.closeTab(tabId);

      expect(controller.recentlyClosedTabs.length, equals(1));
      expect(controller.recentlyClosedTabs.first.url, equals('https://example.com/article'));
    });

    test('restoreRecentlyClosedTab re-opens the most recent closed tab', () {
      controller.openInNewTab('https://example.com/first', switchTo: true);
      final tabId = controller.activeTab!.id;

      controller.closeTab(tabId);
      expect(controller.recentlyClosedTabs.isNotEmpty, isTrue);

      controller.restoreRecentlyClosedTab();
      expect(controller.tabs.any((t) => t.url == 'https://example.com/first'), isTrue);
      expect(controller.recentlyClosedTabs.isEmpty, isTrue);
    });

    test('closeOtherTabs closes all tabs except specified tabId', () {
      controller.openInNewTab('https://example.com/1', switchTo: true);
      final keepId = controller.activeTab!.id;
      controller.openInNewTab('https://example.com/2', switchTo: true);
      controller.openInNewTab('https://example.com/3', switchTo: true);

      expect(controller.tabs.length, equals(3));

      controller.closeOtherTabs(keepId);
      expect(controller.tabs.length, equals(1));
      expect(controller.tabs.first.id, equals(keepId));
    });

    test('duplicateTab creates a clone of the specified tab', () {
      controller.openInNewTab('https://example.com/source', switchTo: true);
      final tab = controller.activeTab!;

      controller.duplicateTab(tab);
      expect(controller.tabs.length, equals(2));
      expect(controller.tabs.last.url, equals('https://example.com/source'));
    });

    test('suspendTab and resumeTab toggle tab isSuspended flag', () {
      controller.openInNewTab('https://example.com/1', switchTo: true);
      controller.openInNewTab('https://example.com/2', switchTo: true);

      final firstTab = controller.tabs[0];
      controller.suspendTab(firstTab);
      expect(firstTab.isSuspended, isTrue);

      controller.resumeTab(firstTab);
      expect(firstTab.isSuspended, isFalse);
    });
  });
}
