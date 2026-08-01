import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/database/app_database.dart';
import '../../../core/services/database_service.dart';
import '../models/browser_tab.dart';

/// Signature matching the screen's `_createNewTab` factory — building a tab
/// (WebViewController + NavigationDelegate) stays on the screen.
typedef CreateTabCallback =
    BrowserTab Function({String initialUrl, bool isIncognito, String? id});

/// Owns the open-tab list, the active index, tab persistence/restore, and
/// the screen's pending-timer bookkeeping (REFACTOR B extraction from
/// `_BrowserScreenState`).
///
/// It is a plain Dart class: UI concerns (setState, URL bar sync, nav state)
/// are reached through the host callbacks passed to the constructor.
class TabManager {
  TabManager({
    required this.isActive,
    required this.setHostState,
    required this.createTab,
    required this.resolveDatabase,
    required this.fallbackTitle,
    required this.cleanupTabState,
    required this.syncUrlController,
    required this.updateNavState,
  });

  /// Whether the host screen is still mounted.
  final bool Function() isActive;

  /// Runs [fn] inside the host's setState.
  final void Function(VoidCallback fn) setHostState;

  /// Builds a fully wired tab (kept on the screen — see [CreateTabCallback]).
  final CreateTabCallback createTab;

  /// Lazily resolves the database service (Provider lookup on the screen).
  final DatabaseService Function() resolveDatabase;

  /// Localized title for restored blank tabs.
  final String Function() fallbackTitle;

  /// Clears per-tab detection state (delegated to the media sniffer).
  final void Function(String tabId) cleanupTabState;

  /// Syncs the address bar with the active tab after a restore.
  final VoidCallback syncUrlController;

  /// Refreshes back/forward navigation state.
  final VoidCallback updateNavState;

  final List<BrowserTab> tabs = [];
  int currentIndex = 0;

  /// In-flight page load timers registered by the screen.
  final List<Timer> pendingTimers = [];
  final Set<String> _disposedTabIds = {};

  BrowserTab? get activeTab => (currentIndex >= 0 && currentIndex < tabs.length)
      ? tabs[currentIndex]
      : null;

  void delayed(Duration duration, VoidCallback callback) {
    late Timer timer;
    timer = Timer(duration, () {
      pendingTimers.remove(timer);
      callback();
    });
    pendingTimers.add(timer);
  }

  void dispose() {
    for (final timer in pendingTimers) {
      timer.cancel();
    }
    pendingTimers.clear();
    _disposedTabIds.clear();
  }

  Future<void> saveTabs() async {
    try {
      // Only persist normal (non-incognito) tabs.
      final normalTabs = tabs.where((t) => !t.isIncognito).toList();

      final tabsData = normalTabs
          .map(
            (tab) => {
              'url': tab.url,
              'title': tab.title,
              'isIncognito': false, // always false for persisted tabs
            },
          )
          .toList();

      // Determine the active tab ID, but only if it's a normal tab.
      final active = activeTab;
      final String? activeTabId;
      if (active != null && !active.isIncognito) {
        activeTabId = active.id;
      } else if (normalTabs.isNotEmpty) {
        activeTabId = normalTabs.last.id;
      } else {
        activeTabId = null;
      }

      final data = {
        'tabs': tabsData,
        'activeTabId': activeTabId,
        'savedAt': DateTime.now().toIso8601String(),
      };

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('browser_tabs', jsonEncode(data));
    } catch (e) {
      debugPrint('Failed to save tabs: $e');
    }
  }

  Future<void> restoreTabs() async {
    if (!isActive()) return;
    // Try Drift first (new persistence path from _quitBrowser)
    try {
      final db = resolveDatabase();
      if (db.isInitialized) {
        final saved = await db.loadOpenTabs();
        if (saved.isNotEmpty && isActive()) {
          await db.clearOpenTabs();
          if (!isActive()) return;
          await applyRestoredTabs(saved);
          return;
        }
      }
    } catch (e) {
      debugPrint(
        '[Browser] Drift restore failed, trying SharedPreferences: $e',
      );
    }
    // Fall back to SharedPreferences (legacy persistence)
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? tabsJson = prefs.getString('browser_tabs');
      if (tabsJson != null && tabsJson.isNotEmpty && isActive()) {
        final restoredTitle = fallbackTitle();
        final Map<String, dynamic> decodedData = jsonDecode(tabsJson);
        final List<dynamic> decoded =
            decodedData['tabs'] as List<dynamic>? ?? [];
        final String? activeTabId = decodedData['activeTabId'] as String?;
        final List<BrowserTab> loadedTabs = [];
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            final url = item['url'] as String? ?? 'about:blank';
            final title = item['title'] as String? ?? restoredTitle;
            final id = item['id'] as String?;
            final isIncognito = item['isIncognito'] as bool? ?? false;
            if (isIncognito) continue; // Skip any incognito tabs (defensive)
            final uri = Uri.tryParse(url);
            if (uri != null &&
                url != 'about:blank' &&
                url.isNotEmpty &&
                uri.scheme != 'http' &&
                uri.scheme != 'https') {
              debugPrint('[Browser] Skipping unsafe restored URL: $url');
              continue;
            }
            final tab = createTab(initialUrl: url, isIncognito: false, id: id);
            tab.title = title;
            loadedTabs.add(tab);
          }
        }
        if (loadedTabs.isNotEmpty && isActive()) {
          int activeIdx = 0;
          if (activeTabId != null) {
            final idx = loadedTabs.indexWhere((t) => t.id == activeTabId);
            if (idx != -1) activeIdx = idx;
          }
          setHostState(() {
            for (final oldTab in tabs) {
              if (_disposedTabIds.contains(oldTab.id)) continue;
              _disposedTabIds.add(oldTab.id);
              cleanupTabState(oldTab.id);
            }
            tabs
              ..clear()
              ..addAll(loadedTabs);
            currentIndex = activeIdx;
            syncUrlController();
          });
          updateNavState();
          // Load saved URLs after platform views initialize
          loadRestoredTabs();
          return;
        }
      }
    } catch (e) {
      debugPrint('[Browser] SharedPreferences restore failed: $e');
    }
    // Nothing to restore — create a single blank tab
    if (!isActive()) return;
    final fallback = createTab();
    setHostState(() {
      tabs
        ..clear()
        ..add(fallback);
      currentIndex = 0;
    });
  }

  Future<void> applyRestoredTabs(List<SavedBrowserTab> saved) async {
    for (final tab in tabs) {
      if (_disposedTabIds.contains(tab.id)) continue;
      _disposedTabIds.add(tab.id);
      try {
        tab.progressNotifier.dispose();
      } catch (_) {}
    }
    var activeIdx = 0;
    final newTabs = <BrowserTab>[];
    for (var i = 0; i < saved.length; i++) {
      final row = saved[i];
      final isBlank = row.url.isEmpty || row.url == 'about:blank';
      final tab = createTab(initialUrl: isBlank ? 'about:blank' : row.url);
      if (row.title.isNotEmpty) tab.title = row.title;
      newTabs.add(tab);
      if (row.isActive) activeIdx = i;
    }
    if (!isActive()) return;
    setHostState(() {
      tabs
        ..clear()
        ..addAll(newTabs);
      currentIndex = activeIdx.clamp(0, tabs.length - 1);
      if (tabs.isNotEmpty) {
        syncUrlController();
      }
    });
    loadRestoredTabs();
  }

  void loadRestoredTabs() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (!isActive()) return;
        final active = activeTab;
        if (active != null && active.url.isNotEmpty && !active.isHome) {
          try {
            active.controller.loadRequest(Uri.parse(active.url));
          } catch (e) {
            debugPrint('[Browser] Restored active tab load error: $e');
          }
        }
      });
    });
  }
}
