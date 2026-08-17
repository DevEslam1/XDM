import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../settings/provider/settings_provider.dart';
import '../models/browser_tab.dart';
import '../models/closed_tab.dart';
import 'tab_manager.dart';

/// Manages tab collections, active tab selection, LRU ordering, and tab suspensions.
class BrowserTabController extends ChangeNotifier {
  final TabManager tabManager;
  final SettingsProvider settingsProvider;

  static const int maxRecentClosedTabs = 10;
  final List<ClosedTab> _recentlyClosedTabs = [];
  List<ClosedTab> get recentlyClosedTabs =>
      List.unmodifiable(_recentlyClosedTabs);

  final List<String> _lruTabIds = [];
  List<String> get lruTabIds => List.unmodifiable(_lruTabIds);

  BrowserTabController({
    required this.tabManager,
    required this.settingsProvider,
  });

  List<BrowserTab> get tabs => tabManager.tabs;
  int get currentIndex => tabManager.currentIndex;
  BrowserTab? get activeTab => tabManager.activeTab;

  void openInNewTab(
    String url, {
    bool switchTo = false,
    TabOrigin origin = TabOrigin.userDirect,
    bool isIncognito = false,
  }) {
    tabManager.openInNewTab(
      url,
      switchToTab: switchTo,
      origin: origin,
      isIncognito: isIncognito,
    );
    _updateLruOrder();
    notifyListeners();
  }

  void switchTab(int index) {
    if (index < 0 || index >= tabs.length) return;
    final oldTab = activeTab;
    if (oldTab != null) {
      oldTab.controller?.evaluateJavascript(
        source:
            'document.querySelectorAll("video, audio").forEach(m => m.pause());',
      );
    }

    tabManager.switchToTab(index);
    _updateLruOrder();

    final newTab = activeTab;
    if (newTab != null) {
      newTab.lastVisitedAt = DateTime.now().millisecondsSinceEpoch;
      if (newTab.isSuspended) {
        resumeTab(newTab);
      }
    }
    notifyListeners();
  }

  void closeTab(String tabId) {
    final idx = tabs.indexWhere((t) => t.id == tabId);
    if (idx != -1) {
      final t = tabs[idx];
      if (!t.isIncognito && t.url.isNotEmpty && !t.isHome) {
        _recentlyClosedTabs.insert(
          0,
          ClosedTab(
            url: t.url,
            title: t.title,
            closedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        if (_recentlyClosedTabs.length > maxRecentClosedTabs) {
          _recentlyClosedTabs.removeLast();
        }
      }
    }

    tabManager.closeTab(tabId);
    _lruTabIds.remove(tabId);
    _updateLruOrder();
    notifyListeners();
  }

  void closeAllTabs() {
    for (final t in tabs) {
      if (!t.isIncognito && t.url.isNotEmpty && !t.isHome) {
        _recentlyClosedTabs.insert(
          0,
          ClosedTab(
            url: t.url,
            title: t.title,
            closedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
    }
    if (_recentlyClosedTabs.length > maxRecentClosedTabs) {
      _recentlyClosedTabs.removeRange(
          maxRecentClosedTabs, _recentlyClosedTabs.length);
    }

    tabManager.clearAllTabs();
    _lruTabIds.clear();
    notifyListeners();
  }

  void closeOtherTabs(String tabId) {
    final toClose = tabs.where((t) => t.id != tabId).map((t) => t.id).toList();
    for (final id in toClose) {
      closeTab(id);
    }
    notifyListeners();
  }

  void duplicateTab(dynamic tabOrId) {
    if (tabOrId is BrowserTab) {
      openInNewTab(
        tabOrId.url,
        switchTo: true,
        isIncognito: tabOrId.isIncognito,
      );
    } else if (tabOrId is String) {
      final tab = tabs.firstWhere(
        (t) => t.id == tabOrId,
        orElse: () => activeTab ?? tabs.first,
      );
      openInNewTab(
        tab.url,
        switchTo: true,
        isIncognito: tab.isIncognito,
      );
    }
  }

  void clearRecentlyClosedTabs() {
    _recentlyClosedTabs.clear();
    notifyListeners();
  }

  void restoreRecentlyClosedTab() {
    if (_recentlyClosedTabs.isEmpty) return;
    final lastClosed = _recentlyClosedTabs.removeAt(0);
    openInNewTab(lastClosed.url, switchTo: true);
    notifyListeners();
  }

  void suspendTab(BrowserTab tab) {
    if (tab.isSuspended || tab == activeTab) return;
    tab.savedScrollY = 0;
    tab.controller = null;
    tab.pullToRefreshController = null;
    tab.isSuspended = true;
    notifyListeners();
  }

  void resumeTab(BrowserTab tab) {
    if (!tab.isSuspended) return;
    tab.isSuspended = false;
    if (tab.pullToRefreshController == null) {
      try {
        tab.pullToRefreshController = PullToRefreshController(
          settings: PullToRefreshSettings(color: Colors.blue),
          onRefresh: () async {
            await tab.controller?.reload();
          },
        );
      } catch (_) {}
    }
    notifyListeners();
  }

  void _updateLruOrder() {
    if (tabs.isEmpty) {
      _lruTabIds.clear();
      return;
    }
    final validIds = tabs.map((t) => t.id).toSet();
    _lruTabIds.removeWhere((id) => !validIds.contains(id));

    if (activeTab != null) {
      _lruTabIds.remove(activeTab!.id);
      _lruTabIds.insert(0, activeTab!.id);
    }
    const cap = 3;
    if (_lruTabIds.length > cap) {
      _lruTabIds.removeRange(cap, _lruTabIds.length);
    }
    tabManager.evictInactiveTabs(keepRecentCount: cap);
  }

  Future<void> restoreTabs() async {
    await tabManager.restoreTabs();
    _updateLruOrder();
    notifyListeners();
  }

  @override
  void dispose() {
    tabManager.dispose();
    super.dispose();
  }
}
