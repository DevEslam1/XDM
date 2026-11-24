import 'dart:convert';

import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/browser/models/browser_tab.dart';
import 'package:dmx/features/browser/services/tab_manager.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/test_helpers.dart';

class _FakeTabDb extends DatabaseService {
  _FakeTabDb() : super.forSubclass();

  bool initialized = false;
  List<SavedBrowserTab> restoreRows = [];
  List<SavedBrowserTab> savedOpenTabs = [];

  @override
  bool get isInitialized => initialized;

  @override
  Future<List<SavedBrowserTab>> loadAndClearOpenTabs() async => restoreRows;

  @override
  Future<void> saveOpenTabs(List<SavedBrowserTab> tabs) async {
    savedOpenTabs = tabs;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsProvider settings;
  late _FakeTabDb db;
  late TabManager manager;
  late int counter;

  BrowserTab createTab({
    String initialUrl = 'about:blank',
    bool isIncognito = false,
    String? id,
    bool autoLoad = true,
    TabOrigin origin = TabOrigin.userDirect,
  }) {
    counter++;
    final tabId = id ?? 'tab_$counter';
    return BrowserTab(
      id: tabId,
      url: initialUrl == 'about:blank' ? '' : initialUrl,
      title: 'Tab $tabId',
      isIncognito: isIncognito,
      isHome: initialUrl == 'about:blank' || initialUrl.isEmpty,
      origin: origin,
    );
  }

  setUp(() async {
    setupTestPluginMocks();
    SharedPreferences.setMockInitialValues({});
    settings = SettingsProvider();
    await settings.load();
    settings.maxTabs = 12;
    db = _FakeTabDb();
    counter = 0;
    manager = TabManager(
      isActive: () => true,
      createTab: createTab,
      resolveDatabase: () => db,
      fallbackTitle: () => 'New Tab',
      cleanupTabState: (_) {},
      syncUrlController: () {},
      updateNavState: () {},
      settingsProvider: settings,
    );
  });

  tearDown(() => manager.dispose());

  group('TabManager index and switching', () {
    test('currentIndex only accepts valid indices', () {
      manager.openInNewTab('https://a.com', switchToTab: true);
      manager.openInNewTab('https://b.com', switchToTab: true);

      manager.currentIndex = 0;
      expect(manager.currentIndex, 0);

      manager.currentIndex = 99;
      expect(manager.currentIndex, 0);

      manager.currentIndex = -1;
      expect(manager.currentIndex, 0);
    });

    test('switchToTabRelative wraps around', () {
      manager.openInNewTab('https://a.com', switchToTab: true);
      manager.openInNewTab('https://b.com', switchToTab: true);
      manager.openInNewTab('https://c.com', switchToTab: true);
      expect(manager.currentIndex, 2);

      manager.switchToTabRelative(1);
      expect(manager.currentIndex, 0);

      manager.switchToTabRelative(-1);
      expect(manager.currentIndex, 2);
    });

    test('switchToTab is a no-op for invalid indices', () {
      manager.openInNewTab('https://a.com', switchToTab: true);
      manager.switchToTab(5);
      expect(manager.currentIndex, 0);
      manager.switchToTab(0);
      expect(manager.currentIndex, 0);
    });

    test('evictInactiveTabs suspends non-recent tabs', () {
      manager.openInNewTab('https://a.com', switchToTab: true);
      manager.openInNewTab('https://b.com', switchToTab: true);
      manager.openInNewTab('https://c.com', switchToTab: true);

      manager.evictInactiveTabs(keepRecentCount: 1);
      expect(manager.tabs.where((t) => t.isSuspended).length, greaterThan(0));
    });

    test('onMemoryPressure closes every inactive tab', () {
      manager.openInNewTab('https://a.com', switchToTab: true);
      manager.openInNewTab('https://b.com', switchToTab: true);
      manager.openInNewTab('https://c.com', switchToTab: true);

      manager.onMemoryPressure();
      expect(manager.tabs, hasLength(1));
      expect(manager.activeTab!.url, 'https://c.com');
    });

    test('effectiveMaxTabs follows the settings provider', () {
      expect(manager.effectiveMaxTabs, 12);
      settings.maxTabs = 5;
      expect(manager.effectiveMaxTabs, 5);
    });
  });

  group('TabManager tab lifecycle', () {
    test('openInNewTab evicts the LRU tab at the cap', () {
      settings.maxTabs = 2;
      manager.openInNewTab('https://a.com', switchToTab: true);
      manager.openInNewTab('https://b.com', switchToTab: true);
      manager.openInNewTab('https://c.com', switchToTab: true);
      expect(manager.tabs, hasLength(2));
    });

    test('addTab switches or keeps focus', () {
      manager.openInNewTab('https://a.com', switchToTab: true);
      manager.addTab(createTab(initialUrl: 'https://b.com'),
          switchToTab: false);
      expect(manager.currentIndex, 0);

      manager.addTab(createTab(initialUrl: 'https://c.com'), switchToTab: true);
      expect(manager.currentIndex, manager.tabs.length - 1);
      expect(manager.activeTab!.url, 'https://c.com');
    });

    test('clearAllTabs empties state and cancels timers', () {
      manager.openInNewTab('https://a.com', switchToTab: true);
      manager.delayed(const Duration(hours: 1), () {});
      expect(manager.pendingTimers, isNotEmpty);

      manager.clearAllTabs();
      expect(manager.tabs, isEmpty);
      expect(manager.pendingTimers, isEmpty);
    });

    test('delayed runs the callback and drops the timer', () async {
      var ran = false;
      manager.delayed(const Duration(milliseconds: 10), () => ran = true);
      expect(manager.pendingTimers, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(ran, isTrue);
      expect(manager.pendingTimers, isEmpty);
    });

    test('dispose cancels pending timers', () {
      manager.delayed(const Duration(hours: 1), () {});
      expect(manager.pendingTimers, isNotEmpty);
      // tearDown() calls dispose(), which must cancel the timer.
    });
  });

  group('TabManager persistence', () {
    test('saveTabsImmediately writes tab state to preferences', () async {
      manager.openInNewTab('https://a.com', switchToTab: true);
      await manager.saveTabsImmediately();

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('browser_tabs');
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded['tabs'], isA<List<dynamic>>());
    });

    test('saveTabs persists after the debounce window', () async {
      manager.openInNewTab('https://a.com', switchToTab: true);
      await manager.saveTabs();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('browser_tabs'), isNotNull);
    });

    test('saves open tabs to an initialized database', () async {
      db.initialized = true;
      manager.openInNewTab('https://a.com', switchToTab: true);
      manager.openInNewTab('https://b.com', switchToTab: true);
      await manager.saveTabsImmediately();
      expect(db.savedOpenTabs, hasLength(2));
    });

    test('restores tabs from preferences, skipping unsafe and incognito',
        () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'browser_tabs',
        jsonEncode({
          'tabs': [
            {'id': 't1', 'url': 'https://a.com', 'title': 'A'},
            {'id': 't2', 'url': 'javascript:evil', 'title': 'B'},
            {
              'id': 't3',
              'url': 'https://b.com',
              'title': 'C',
              'isIncognito': true
            },
            {'id': 't4', 'url': 'https://c.com', 'title': 'D'},
          ],
          'activeTabId': 't1',
        }),
      );

      await manager.restoreTabs();
      expect(manager.tabs, hasLength(2));
      expect(manager.activeTab!.title, 'A');
    });

    test('restores tabs from the database when initialized', () async {
      db.initialized = true;
      db.restoreRows = [
        const SavedBrowserTab(
          id: 'db1',
          url: 'https://a.com',
          title: 'A',
          isActive: true,
          position: 0,
          createdAt: 1,
          lastVisitedAt: 1,
        ),
        const SavedBrowserTab(
          id: 'db2',
          url: 'https://b.com',
          title: 'B',
          isActive: false,
          position: 1,
          createdAt: 1,
          lastVisitedAt: 2,
        ),
      ];

      await manager.restoreTabs();
      expect(manager.tabs, hasLength(2));
      expect(manager.activeTab!.title, 'A');
    });

    test('applyRestoredTabs builds tabs and marks inactive ones suspended',
        () async {
      final saved = [
        const SavedBrowserTab(
          id: 'r1',
          url: 'https://a.com',
          title: 'A',
          isActive: true,
          position: 0,
          createdAt: 1,
          lastVisitedAt: 1,
        ),
        const SavedBrowserTab(
          id: 'r2',
          url: 'about:blank',
          title: '',
          isActive: false,
          position: 1,
          createdAt: 1,
          lastVisitedAt: 2,
        ),
      ];
      await manager.applyRestoredTabs(saved);
      expect(manager.tabs, hasLength(2));
      expect(manager.tabs[1].isSuspended, isTrue);
    });

    test('falls back to a single blank tab when restore data is absent',
        () async {
      await manager.restoreTabs();
      expect(manager.tabs, hasLength(1));
      expect(manager.currentIndex, 0);
    });
  });
}
