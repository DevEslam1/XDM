import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';

import '../../../core/services/database/app_database.dart';
import '../../../core/services/database_service.dart';
import '../models/browser_tab.dart';
import 'page_intent_classifier.dart';

/// Signature matching the screen's `_createNewTab` factory.
typedef CreateTabCallback = BrowserTab Function(
    {String initialUrl, bool isIncognito, String? id, bool autoLoad, TabOrigin origin});

/// Refactored ChangeNotifier owning open tabs, active index, background tab loading,
/// atomic state mutations, and tab persistence.
class TabManager extends ChangeNotifier {
  static final _log = Logger('TabManager');

  TabManager({
    required this.isActive,
    required this.createTab,
    required this.resolveDatabase,
    required this.fallbackTitle,
    required this.cleanupTabState,
    required this.syncUrlController,
    required this.updateNavState,
  });

  /// Whether the host screen is still mounted.
  final bool Function() isActive;

  /// Builds a fully wired tab (kept on the screen — see [CreateTabCallback]).
  final CreateTabCallback createTab;

  /// Lazily resolves the database service.
  final DatabaseService Function() resolveDatabase;

  /// Localized title for restored blank tabs.
  final String Function() fallbackTitle;

  /// Clears per-tab detection state.
  final void Function(String tabId) cleanupTabState;

  /// Syncs the address bar with the active tab after a switch or restore.
  final VoidCallback syncUrlController;

  /// Refreshes back/forward navigation state.
  final VoidCallback updateNavState;

  final List<BrowserTab> _tabs = [];
  int _currentIndex = 0;
  final List<String> _tabIdHistory = [];

  /// Maximum allowed background ad/popup tabs before auto-eviction.
  final int _maxUnvisitedAdTabs = 3;

  /// In-flight page load timers registered by the screen.
  final List<Timer> pendingTimers = [];
  final Set<String> _disposedTabIds = {};

  void _recordDisposedTabId(String id) {
    _disposedTabIds.add(id);
    if (_disposedTabIds.length > 300) {
      _disposedTabIds.remove(_disposedTabIds.first);
    }
  }

  List<BrowserTab> get tabs => List.unmodifiable(_tabs);
  int get currentIndex => _currentIndex;
  set currentIndex(int value) {
    if (value >= 0 && value < _tabs.length) {
      _currentIndex = value;
      notifyListeners();
    }
  }

  BrowserTab? get activeTab =>
      (_currentIndex >= 0 && _currentIndex < _tabs.length)
          ? _tabs[_currentIndex]
          : null;

  /// Switches active tab smoothly by index.
  void switchToTab(int index) {
    if (index < 0 || index >= _tabs.length || index == _currentIndex) return;
    final oldTab = activeTab;
    if (oldTab != null) {
      if (_tabIdHistory.isEmpty || _tabIdHistory.last != oldTab.id) {
        _tabIdHistory.add(oldTab.id);
        if (_tabIdHistory.length > 50) {
          _tabIdHistory.removeAt(0);
        }
      }
    }
    _currentIndex = index;
    notifyListeners();
    syncUrlController();
    updateNavState();
  }

  /// Switches active tab relative to current index (e.g. +1, -1).
  void switchToTabRelative(int offset) {
    if (_tabs.length <= 1) return;
    final newIndex =
        ((_currentIndex + offset) % _tabs.length + _tabs.length) % _tabs.length;
    switchToTab(newIndex);
  }

  /// Opens a new tab with optional background loading logic.
  void openInNewTab(
    String url, {
    bool switchToTab = false,
    TabOrigin origin = TabOrigin.userDirect,
    bool isIncognito = false,
  }) {
    if (!isActive() || url.isEmpty) return;

    // 1. Evict stale background ad/popup tabs atomically before adding
    _evictStaleAdTabsInternal();

    // 2. Construct the new tab
    final newTab = createTab(
      initialUrl: url,
      isIncognito: isIncognito,
      origin: origin,
    );
    _tabs.add(newTab);

    // 3. Update current index if switching or keep focus on active tab
    if (switchToTab) {
      final oldActive = activeTab;
      if (oldActive != null) {
        if (_tabIdHistory.isEmpty || _tabIdHistory.last != oldActive.id) {
          _tabIdHistory.add(oldActive.id);
          if (_tabIdHistory.length > 50) {
            _tabIdHistory.removeAt(0);
          }
        }
      }
      _currentIndex = _tabs.length - 1;
      syncUrlController();
      updateNavState();
    }

    notifyListeners();
    saveTabs();
  }

  /// Directly adds a tab instance created outside TabManager.
  void addTab(BrowserTab tab, {bool switchToTab = true}) {
    _tabs.add(tab);
    if (switchToTab) {
      final oldActive = activeTab;
      if (oldActive != null && oldActive.id != tab.id) {
        if (_tabIdHistory.isEmpty || _tabIdHistory.last != oldActive.id) {
          _tabIdHistory.add(oldActive.id);
          if (_tabIdHistory.length > 50) {
            _tabIdHistory.removeAt(0);
          }
        }
      }
      _currentIndex = _tabs.length - 1;
      syncUrlController();
      updateNavState();
    }
    notifyListeners();
    saveTabs();
  }

  /// Closes a tab by ID with atomic state update and smooth LRU/adjacent fallback.
  void closeTab(String tabId) {
    final targetIndex = _tabs.indexWhere((t) => t.id == tabId);
    if (targetIndex == -1) return;

    final isClosingActive = targetIndex == _currentIndex;
    final closingTab = _tabs[targetIndex];

    cleanupTabState(closingTab.id);

    // Atomic removal and index recalculation
    _tabs.removeAt(targetIndex);
    _tabIdHistory.removeWhere((id) => id == tabId);

    if (_tabs.isEmpty) {
      final fallback = createTab();
      _tabs.add(fallback);
      _currentIndex = 0;
    } else if (isClosingActive) {
      int nextIndex = -1;
      while (_tabIdHistory.isNotEmpty) {
        final lastId = _tabIdHistory.removeLast();
        final idx = _tabs.indexWhere((t) => t.id == lastId);
        if (idx != -1) {
          nextIndex = idx;
          break;
        }
      }
      if (nextIndex == -1) {
        nextIndex = targetIndex.clamp(0, _tabs.length - 1);
      }
      _currentIndex = nextIndex;
    } else if (targetIndex < _currentIndex) {
      _currentIndex = (_currentIndex - 1).clamp(0, _tabs.length - 1);
    }

    notifyListeners();
    syncUrlController();
    updateNavState();
    saveTabs();

    // Post-frame disposal prevents double-dispose or widget unmount crashes
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposedTabIds.contains(closingTab.id)) {
        _recordDisposedTabId(closingTab.id);
        closingTab.dispose();
      }
    });
  }

  /// Clears all open tabs and resets state.
  void clearAllTabs() {
    for (final tab in _tabs) {
      cleanupTabState(tab.id);
      if (!_disposedTabIds.contains(tab.id)) {
        _recordDisposedTabId(tab.id);
        try {
          tab.dispose();
        } catch (_) {}
      }
    }
    _tabs.clear();
    _currentIndex = 0;
    _tabIdHistory.clear();
    notifyListeners();
  }

  /// Safely evicts stale unvisited ad/popup tabs without interrupting the active tab.
  void evictStaleAdTabs() {
    if (_evictStaleAdTabsInternal()) {
      notifyListeners();
      saveTabs();
    }
  }

  bool _evictStaleAdTabsInternal() {
    final activeId = activeTab?.id;
    final candidates = _tabs
        .where((t) =>
            (t.origin == TabOrigin.adOrPopup ||
                t.origin == TabOrigin.redirect) &&
            t.id != activeId)
        .toList()
      ..sort((a, b) => a.lastVisitedAt.compareTo(b.lastVisitedAt));

    bool mutated = false;
    while (candidates.length >= _maxUnvisitedAdTabs) {
      final oldest = candidates.removeAt(0);
      _log.info('[TabManager] Evicting stale background ad tab: ${oldest.url}');
      cleanupTabState(oldest.id);
      _tabs.remove(oldest);
      mutated = true;
      if (_currentIndex >= _tabs.length) {
        _currentIndex = _tabs.length - 1;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposedTabIds.contains(oldest.id)) {
          _recordDisposedTabId(oldest.id);
          oldest.dispose();
        }
      });
    }
    return mutated;
  }

  void delayed(Duration duration, VoidCallback callback) {
    late Timer timer;
    timer = Timer(duration, () {
      pendingTimers.remove(timer);
      callback();
    });
    pendingTimers.add(timer);
  }

  @override
  void dispose() {
    for (final timer in pendingTimers) {
      timer.cancel();
    }
    pendingTimers.clear();
    _disposedTabIds.clear();
    super.dispose();
  }

  Future<void> saveTabs() async {
    try {
      final normalTabs = _tabs.where((t) => !t.isIncognito).toList();
      final tabsData = normalTabs
          .map(
            (tab) => {
              'id': tab.id,
              'url': tab.url,
              'title': tab.title,
              'isIncognito': false,
            },
          )
          .toList();

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

      final db = resolveDatabase();
      if (db.isInitialized) {
        final List<SavedBrowserTab> dbTabs = [];
        for (var i = 0; i < normalTabs.length; i++) {
          final tab = normalTabs[i];
          dbTabs.add(
            SavedBrowserTab(
              id: tab.id,
              url: tab.url,
              title: tab.title,
              isActive: tab.id == activeTabId,
              position: i,
              createdAt: DateTime.now().millisecondsSinceEpoch,
              lastVisitedAt: tab.lastVisitedAt,
              faviconUrl: tab.faviconUrl,
            ),
          );
        }
        await db.saveOpenTabs(dbTabs);
      } else {
        _log.warning('Database is not initialized. Tabs saved to SharedPreferences only.');
      }
    } catch (e) {
      _log.warning('Failed to save tabs: $e');
    }
  }

  Future<void> restoreTabs() async {
    int attempts = 0;
    while (attempts < 2) {
      attempts++;
      try {
        await _performRestoreTabs();
        return;
      } catch (e, st) {
        _log.severe('[TabManager] restoreTabs failed (attempt $attempts)', e, st);
        if (attempts < 2) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
    }

    if (!isActive()) return;
    final fallback = createTab();
    _tabs
      ..clear()
      ..add(fallback);
    _currentIndex = 0;
    notifyListeners();
  }

  Future<void> _performRestoreTabs() async {
    if (!isActive()) return;
    try {
      final db = resolveDatabase();
      if (db.isInitialized) {
        final saved = await db.loadAndClearOpenTabs();
        if (saved.isNotEmpty && isActive()) {
          await applyRestoredTabs(saved);
          return;
        }
      }
    } catch (e) {
      _log.warning('[Browser] Drift restore failed: $e');
    }

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
            final url = item['url']?.toString() ?? 'about:blank';
            final title = item['title']?.toString() ?? restoredTitle;
            final id = item['id']?.toString();
            final isIncognito = item['isIncognito'] as bool? ?? false;
            if (isIncognito) continue;
            final uri = Uri.tryParse(url);
            if (uri != null &&
                url != 'about:blank' &&
                url.isNotEmpty &&
                uri.scheme != 'http' &&
                uri.scheme != 'https') {
              _log.warning('[Browser] Skipping unsafe restored URL: $url');
              continue;
            }
            final tab = createTab(
                initialUrl: url, isIncognito: false, id: id, autoLoad: false);
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
          for (final oldTab in _tabs) {
            if (_disposedTabIds.contains(oldTab.id)) continue;
            _recordDisposedTabId(oldTab.id);
            cleanupTabState(oldTab.id);
            try {
              oldTab.dispose();
            } catch (e, st) {
              Logger('tab_manager').warning('[tab_manager] oldTab dispose failed', e, st);
            }
          }
          _tabs
            ..clear()
            ..addAll(loadedTabs);
          _currentIndex = activeIdx;
          notifyListeners();
          syncUrlController();
          updateNavState();
          loadRestoredTabs();
          return;
        }
      }
    } catch (e) {
      _log.warning('[Browser] SharedPreferences restore failed: $e');
    }

    if (!isActive()) return;
    final fallback = createTab();
    _tabs
      ..clear()
      ..add(fallback);
    _currentIndex = 0;
    notifyListeners();
  }

  Future<void> applyRestoredTabs(List<SavedBrowserTab> saved) async {
    for (final tab in _tabs) {
      if (_disposedTabIds.contains(tab.id)) continue;
      _recordDisposedTabId(tab.id);
      cleanupTabState(tab.id);
      try {
        tab.dispose();
      } catch (e, st) {
        Logger('tab_manager').warning('[tab_manager] operation failed', e, st);
      }
    }
    var activeIdx = 0;
    final newTabs = <BrowserTab>[];
    for (var i = 0; i < saved.length; i++) {
      final row = saved[i];
      final isBlank = row.url.isEmpty || row.url == 'about:blank';
      final tab = createTab(
          initialUrl: isBlank ? 'about:blank' : row.url, autoLoad: false);
      if (row.title.isNotEmpty) tab.title = row.title;
      newTabs.add(tab);
      if (row.isActive) activeIdx = i;
    }
    if (!isActive()) return;
    _tabs
      ..clear()
      ..addAll(newTabs);
    _currentIndex = activeIdx.clamp(0, _tabs.length - 1);
    notifyListeners();
    if (_tabs.isNotEmpty) {
      syncUrlController();
    }
    loadRestoredTabs();
  }

  void loadRestoredTabs() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (!isActive()) return;
        final active = activeTab;
        if (active != null && active.url.isNotEmpty && !active.isHome) {
          if (active.controller != null) {
            try {
              active.controller
                  ?.loadUrl(urlRequest: URLRequest(url: WebUri(active.url)));
            } catch (e) {
              _log.warning('[Browser] Restored active tab load error: $e');
            }
          }
        }
      });
    });
  }

  Future<PageClassification> smartNavigate(
    String url, {
    bool isUserInitiated = true,
    bool isFromClick = false,
  }) async {
    final classifier = PageIntentClassifier.instance;
    final classification = classifier.classifyWithContext(
      currentUrl: activeTab?.url ?? '',
      targetUrl: url,
      isUserInitiated: isUserInitiated,
      isFromClick: isFromClick,
    );

    switch (classification.action) {
      case PageAction.block:
        return classification;

      case PageAction.openSameTab:
        final active = activeTab;
        if (active != null) {
          active.url = url;
          active.controller?.loadUrl(
            urlRequest: URLRequest(url: WebUri(url)),
          );
        }
        return classification;

      case PageAction.openNewTab:
      case PageAction.openNewTabWithWarning:
      case PageAction.openNewTabWithDownloadSuggestion:
        openInNewTab(url, switchToTab: true);
        return classification;

      case PageAction.openBackgroundTab:
        openInNewTab(url, switchToTab: false);
        return classification;

      case PageAction.directDownload:
        return classification;
    }
  }
}
