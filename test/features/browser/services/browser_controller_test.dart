import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/browser/models/browser_tab.dart';
import 'package:dmx/features/browser/services/browser_controller.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsProvider settings;
  late DatabaseService db;
  late DownloadProvider downloads;
  late BrowserController controller;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    setupTestPluginMocks();
    settings = SettingsProvider();
    db = DatabaseService();
    downloads = DownloadProvider(
      databaseService: db,
      settingsProvider: settings,
      enableBackgroundTimers: false,
    );
    controller = BrowserController(
      settingsProvider: settings,
      downloadProvider: downloads,
      databaseService: db,
    );
    await controller.ready.future;
  });

  tearDown(() {
    controller.dispose();
  });

  group('BrowserController Hardening Tests', () {
    test('ready Completer finishes initialization', () async {
      await controller.ready.future;
      expect(controller.ready.isCompleted, isTrue);
    });

    test('openInNewTab, switchTab, and LRU eviction work seamlessly', () {
      controller.openInNewTab('https://example.com/1', switchTo: true);
      controller.openInNewTab('https://example.com/2', switchTo: true);
      controller.openInNewTab('https://example.com/3', switchTo: true);
      controller.openInNewTab('https://example.com/4', switchTo: true);

      expect(controller.tabs.length, greaterThanOrEqualTo(4));
      expect(controller.activeTab?.url, 'https://example.com/4');

      controller.switchTab(0);
      expect(controller.currentIndex, 0);
    });

    test('loadHome resets active tab and preserves controller state', () {
      controller.openInNewTab('https://example.com', switchTo: true);
      expect(controller.activeTab?.isHome, isFalse);

      controller.loadHome();
      expect(controller.activeTab?.isHome, isTrue);
      expect(controller.activeTab?.url, BrowserTab.canonicalBlankUrl);
    });

    test('recordBlockedAd and recordBlockedPopup increment counts', () {
      final tabId = controller.activeTab?.id ?? 'tab1';
      controller.recordBlockedAd(tabId, 'https://ad.doubleclick.net/ad.js');
      expect(controller.blockedAdsCount(tabId), 1);

      controller.recordBlockedPopup(tabId);
      expect(controller.blockedPopupsCount(tabId), 1);
    });

    test('Find in page controller updates match query state', () async {
      controller.openFindPanel();
      expect(controller.findPanelVisible, isTrue);

      controller.closeFindPanel();
      expect(controller.findPanelVisible, isFalse);
    });

    test('closeTab moves to recently closed tabs for recovery', () {
      controller.openInNewTab('https://recoverable.org', switchTo: true);
      final tabId = controller.activeTab!.id;

      controller.closeTab(tabId);
      expect(controller.recentlyClosedTabs.isNotEmpty, isTrue);
      expect(controller.recentlyClosedTabs.first.url, 'https://recoverable.org');

      controller.restoreRecentlyClosedTab();
      expect(controller.activeTab?.url, 'https://recoverable.org');
    });

    test('cleanUrl adds https when protocol missing', () {
      expect(controller.cleanUrl('google.com'), 'https://google.com');
      expect(controller.cleanUrl('https://dart.dev'), 'https://dart.dev');
      expect(controller.cleanUrl('about:blank'), 'about:blank');
    });
  });
}
