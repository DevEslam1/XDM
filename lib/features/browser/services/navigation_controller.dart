import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/widget_deep_link.dart';
import '../../../core/utils/localization.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/browser_tab.dart';
import 'page_intent_classifier.dart';
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

    // FIX(D9): Run the page-intent classifier before navigating. Fully
    // blocked pages get a warning dialog instead of loading; pages meant
    // for a new tab are routed to onOpenInNewTab.
    final classification = PageIntentClassifier.instance.classifyWithContext(
      currentUrl: tab.url,
      targetUrl: target,
      isUserInitiated: true,
      isFromClick: false,
    );

    if (classification.shouldBlock) {
      if (!await _confirmOverrideBlockedUrl(classification)) {
        return;
      }
    } else if (classification.shouldOpenNewTab) {
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

  /// FIX(D9): Shows a warning dialog explaining why the URL was blocked.
  /// Returns true when the user explicitly overrides the block.
  Future<bool> _confirmOverrideBlockedUrl(
      PageClassification classification) async {
    final context = WidgetDeepLinkHandler.navigatorKey?.currentContext;
    if (context == null) {
      _log.warning(
          'Blocked URL (no navigator context): ${classification.url} (${classification.reason})');
      return false;
    }
    final isDark = settingsProvider.isDarkMode;
    return showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: Text(
          L10n.of(context, 'browser_nav_blocked_title'),
          style: TextStyle(
            fontSize: 16,
            color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
          ),
        ),
        content: Text(
          L10n.of(
            context,
            'browser_nav_blocked_reason',
            args: {'reason': classification.reason ?? 'unknown'},
          ),
          style: TextStyle(
            fontSize: 14,
            color:
                isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text(L10n.of(context, 'cancel_btn_uppercase')),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.neonBlue,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(L10n.of(context, 'browser_nav_open_anyway')),
          ),
        ],
      ),
    ).then((result) => result ?? false);
  }

  @override
  void dispose() {
    focusNode.removeListener(_onFocusChanged);
    focusNode.dispose();
    urlController.dispose();
    super.dispose();
  }
}
