import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';

import '../../settings/provider/settings_provider.dart';
import '../models/browser_tab.dart';
import 'search_engine_config.dart';

/// Handles URL bar state, forward/backward navigation, search prefixes, and reloads.
class NavigationController extends ChangeNotifier {
  static final _log = Logger('NavigationController');

  final SettingsProvider settingsProvider;
  final TextEditingController urlController = TextEditingController();
  final FocusNode focusNode = FocusNode();

  bool _isFocused = false;
  bool get isFocused => _isFocused;

  final BrowserTab? Function() getActiveTab;
  final void Function(String url, {bool switchTo}) onOpenInNewTab;
  final void Function(BrowserTab tab) onResumeTab;

  NavigationController({
    required this.settingsProvider,
    required this.getActiveTab,
    required this.onOpenInNewTab,
    required this.onResumeTab,
  }) {
    focusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    _isFocused = focusNode.hasFocus;
    notifyListeners();
  }

  void syncUrlController(BrowserTab? activeTab) {
    if (focusNode.hasFocus) return;
    final currentText = urlController.text;
    final newText =
        (activeTab == null || activeTab.isHome) ? '' : activeTab.url;
    if (currentText != newText) {
      urlController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
    }
  }

  Future<void> navigateToUrl(String rawUrl) async {
    var target = rawUrl.trim();
    if (target.isEmpty) return;

    if (!target.contains('://') && !target.startsWith('about:')) {
      if (target.contains('.') && !target.contains(' ')) {
        target = 'https://$target';
      } else {
        target =
            '${SearchEngineConfig.prefixFor(settingsProvider.searchEngine)}${Uri.encodeComponent(target)}';
      }
    }

    final tab = getActiveTab();
    if (tab == null) {
      onOpenInNewTab(target, switchTo: true);
      return;
    }

    if (tab.isSuspended || tab.controller == null) {
      onResumeTab(tab);
    }

    tab.updateUrl(target);
    tab.isLoading = true;
    tab.hasError = false;
    tab.hasCrashed = false;
    tab.errorDescription = null;

    syncUrlController(tab);
    notifyListeners();

    try {
      if (tab.controller != null) {
        await tab.controller!
            .loadUrl(urlRequest: URLRequest(url: WebUri(target)));
      }
    } catch (e) {
      _log.warning('Navigation failed: $e');
    }
  }

  Future<void> goBack() async {
    final tab = getActiveTab();
    if (tab?.controller != null && tab!.canGoBack) {
      await tab.controller!.goBack();
    } else {
      loadHome();
    }
  }

  Future<void> goForward() async {
    final tab = getActiveTab();
    if (tab?.controller != null && tab!.canGoForward) {
      await tab.controller!.goForward();
    }
  }

  Future<void> reload() async {
    final tab = getActiveTab();
    if (tab != null) {
      tab.isLoading = true;
      notifyListeners();
      await tab.controller?.reload();
    }
  }

  Future<void> stopLoading() async {
    final tab = getActiveTab();
    if (tab != null) {
      await tab.controller?.stopLoading();
      tab.isLoading = false;
      notifyListeners();
    }
  }

  void loadHome() {
    final tab = getActiveTab();
    if (tab == null) return;
    try {
      tab.controller?.dispose();
    } catch (_) {}
    tab.controller = null;
    tab.pullToRefreshController = null;
    tab.updateUrl(BrowserTab.canonicalBlankUrl);
    tab.title = 'New Tab';
    tab.isHome = true;
    tab.isLoading = false;
    tab.hasError = false;
    tab.hasCrashed = false;
    tab.errorDescription = null;
    syncUrlController(tab);
    notifyListeners();
  }

  @override
  void dispose() {
    focusNode.removeListener(_onFocusChanged);
    focusNode.dispose();
    urlController.dispose();
    super.dispose();
  }
}
