import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/browser_tab.dart';

class BrowserTabManager {
  static const _tabsKey = 'persisted_browser_tabs';

  final List<BrowserTab> tabs = [];
  int currentTabIndex = 0;

  BrowserTab? get currentTab =>
      tabs.isEmpty ? null : tabs[currentTabIndex];

  void addTab(BrowserTab tab) {
    tabs.add(tab);
    currentTabIndex = tabs.length - 1;
  }

  void removeTab(int index) {
    if (index < 0 || index >= tabs.length) return;
    tabs.removeAt(index);
    if (tabs.isEmpty) {
      currentTabIndex = 0;
    } else if (currentTabIndex >= tabs.length) {
      currentTabIndex = tabs.length - 1;
    }
  }

  void closeAllTabs() {
    tabs.clear();
    currentTabIndex = 0;
  }

  Future<void> saveTabs() async {
    final prefs = await SharedPreferences.getInstance();
    final data = tabs
        .where((t) => !t.isIncognito && t.url != 'about:blank')
        .map((t) => {
          'url': t.url,
          'title': t.title,
        })
        .toList();
    await prefs.setString(_tabsKey, jsonEncode(data));
  }

  Future<List<Map<String, dynamic>>> loadTabs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_tabsKey);
    if (raw == null) return [];
    try {
      return List<Map<String, dynamic>>.from(jsonDecode(raw));
    } catch (_) {
      return [];
    }
  }
}
