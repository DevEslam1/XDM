import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/database_service.dart';
import '../../../core/services/redirect_guard.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';
import '../data/browser_preferences_repository.dart';
import '../models/browser_tab.dart';
import '../models/closed_tab.dart';
import 'ad_blocker_delegate.dart';
import 'ad_blocker_service.dart';
import 'browser_download_coordinator.dart';
import 'browser_tab_controller.dart';
import 'download_interceptor.dart';
import 'element_picker_service.dart';
import 'fingerprint_manager.dart';
import 'history_manager.dart';
import 'inactivity_watchdog.dart';
import 'media_sniffer.dart';
import 'navigation_controller.dart';
import 'reader_mode_service.dart';
import 'script_injector.dart';
import 'site_settings_store.dart';
import 'tab_manager.dart';

/// Central production-grade controller facade composing TabController,
/// NavigationController, BrowserDownloadCoordinator, and security engines.
class BrowserController extends ChangeNotifier {
  static final _log = Logger('BrowserController');

  final SettingsProvider settingsProvider;
  final DownloadProvider downloadProvider;
  final DatabaseService databaseService;
  final BrowserPreferencesRepository prefsRepo;

  late final AdBlockerDelegate adBlocker;
  late final RedirectGuard redirectGuard;
  late final BrowserHistoryManager historyManager;
  late final InactivityWatchdog inactivityWatchdog;
  late final FingerprintManager fingerprintManager;
  late final ScriptInjector scriptInjector;
  late final SiteSettingsStore siteSettingsStore;
  late final ReaderModeService readerModeService;

  // Composed Sub-Controllers
  late final TabManager tabManager;
  late final BrowserTabController tabController;
  late final NavigationController navigationController;
  late final BrowserDownloadCoordinator downloadCoordinator;

  // Delegated UI hooks
  TextEditingController get urlController => navigationController.urlController;
  FocusNode get focusNode => navigationController.focusNode;
  bool get isFocused => navigationController.isFocused;

  final ValueNotifier<bool> showBarsNotifier = ValueNotifier<bool>(true);
  final ScrollController tabStripScrollController = ScrollController();

  List<String> get lruTabIds => tabController.lruTabIds;
  List<ClosedTab> get recentlyClosedTabs => tabController.recentlyClosedTabs;

  // Blocked ads and popups per tab tracking
  final Map<String, ValueNotifier<int>> _blockedAdsNotifiers = {};
  final Map<String, int> _blockedAdsPerTab = {};
  final Map<String, int> _blockedPopupsPerTab = {};

  // Per-tab loading timeout timers
  final Map<String, Timer> _loadingTimeoutTimers = {};

  // Navigation state tracking
  final Map<String, bool> navigatingBackForwardTabIds = {};

  // Favicon HTTP client & cache
  HttpClient? _sharedHttpClient;
  HttpClient get _faviconHttpClient => _sharedHttpClient ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 4);
  final Map<String, DateTime> _faviconCache = {};

  // Find in page state
  final TextEditingController findTextController = TextEditingController();
  bool _findPanelVisible = false;
  bool get findPanelVisible => _findPanelVisible;
  int _findActiveMatch = 0;
  int get findActiveMatch => _findActiveMatch;
  int _findMatchCount = 0;
  int get findMatchCount => _findMatchCount;

  // Reader mode state
  ReaderArticle? _readerArticle;
  ReaderArticle? get readerArticle => _readerArticle;
  String? _readerTabId;
  String? get readerTabId => _readerTabId;
  bool _readerControlsVisible = false;
  bool get readerControlsVisible => _readerControlsVisible;
  double _readerFontSize = 16.0;
  double get readerFontSize => _readerFontSize;
  String _readerTheme = 'light';
  String get readerTheme => _readerTheme;
  String _readerFontFamily = 'serif';
  String get readerFontFamily => _readerFontFamily;

  void setReaderControlsVisible(bool visible) {
    _readerControlsVisible = visible;
    notifyListeners();
  }

  void setReaderFontSize(double size) {
    _readerFontSize = size;
    notifyListeners();
  }

  void setReaderTheme(String theme) {
    _readerTheme = theme;
    notifyListeners();
  }

  void setReaderFontFamily(String family) {
    _readerFontFamily = family;
    notifyListeners();
  }

  // Sniffer state proxy
  bool get isSnifferEnabled => downloadCoordinator.isSnifferEnabled;
  MediaSniffer get mediaSniffer => downloadCoordinator.mediaSniffer;
  DownloadInterceptor get downloadInterceptor =>
      downloadCoordinator.downloadInterceptor;

  // Session flags
  bool _incognitoBannerDismissed = false;
  bool get incognitoBannerDismissed => _incognitoBannerDismissed;

  bool _isRestoring = false;
  bool get isRestoring => _isRestoring;

  bool _isDisposed = false;
  bool get isDisposed => _isDisposed;

  final Completer<void> ready = Completer<void>();

  // Form autofill debounce timer
  Timer? _autofillDebounceTimer;
  Map<String, String>? _pendingAutofillData;

  BrowserController({
    required this.settingsProvider,
    required this.downloadProvider,
    required this.databaseService,
    BrowserPreferencesRepository? prefsRepo,
    AdBlockerDelegate? adBlocker,
    RedirectGuard? redirectGuard,
    DownloadInterceptor? downloadInterceptor,
    MediaSniffer? mediaSniffer,
    BrowserHistoryManager? historyManager,
    InactivityWatchdog? inactivityWatchdog,
    FingerprintManager? fingerprintManager,
    ScriptInjector? scriptInjector,
    SiteSettingsStore? siteSettingsStore,
    ReaderModeService? readerModeService,
    TabManager? tabManager,
  }) : prefsRepo = prefsRepo ?? BrowserPreferencesRepository() {
    this.adBlocker = adBlocker ?? AdBlockerDelegate();
    this.redirectGuard = redirectGuard ?? RedirectGuard();
    this.siteSettingsStore = siteSettingsStore ?? SiteSettingsStore();
    this.readerModeService = readerModeService ?? ReaderModeService();
    this.fingerprintManager = fingerprintManager ?? FingerprintManager();
    this.scriptInjector = scriptInjector ?? ScriptInjector();
    this.inactivityWatchdog = inactivityWatchdog ?? InactivityWatchdog();

    this.tabManager = tabManager ??
        TabManager(
          isActive: () => !_isDisposed,
          createTab: createNewTab,
          resolveDatabase: () => databaseService,
          fallbackTitle: () => 'New Tab',
          cleanupTabState: cleanupTabState,
          syncUrlController: syncUrlController,
          updateNavState: updateNavState,
          settingsProvider: settingsProvider,
        );

    tabController = BrowserTabController(
      tabManager: this.tabManager,
      settingsProvider: settingsProvider,
    );
    tabController.addListener(notifyListeners);

    navigationController = NavigationController(
      settingsProvider: settingsProvider,
      getActiveTab: () => activeTab,
      onOpenInNewTab: (url, {bool switchTo = true}) =>
          openInNewTab(url, switchTo: switchTo),
      onResumeTab: (tab) => resumeTab(tab),
    );
    navigationController.addListener(notifyListeners);

    downloadCoordinator = BrowserDownloadCoordinator(
      downloadProvider: downloadProvider,
      settingsProvider: settingsProvider,
      prefsRepo: this.prefsRepo,
      getActiveTab: () => activeTab,
      containsTab: (tab) => tabs.any((t) => t.id == tab.id),
      onStateChanged: notifyListeners,
    );
    downloadCoordinator.addListener(notifyListeners);

    this.historyManager = historyManager ??
        BrowserHistoryManager(
          resolveDatabase: () => databaseService,
          isIncognito: () => settingsProvider.incognitoEnabled,
          cleanUrl: cleanUrl,
          isActive: () => !_isDisposed,
        );

    _initAsyncState();
  }

  List<BrowserTab> get tabs => tabController.tabs;
  int get currentIndex => tabController.currentIndex;
  BrowserTab? get activeTab => tabController.activeTab;

  Future<void> _initAsyncState() async {
    try {
      _incognitoBannerDismissed = await prefsRepo.getIncognitoBannerDismissed();

      if (tabs.isEmpty) {
        await restoreTabs();
      }
    } catch (e, st) {
      _log.warning('Init async state error', e, st);
    } finally {
      if (!ready.isCompleted) {
        ready.complete();
      }
      if (!_isDisposed) {
        notifyListeners();
      }
    }
  }

  ValueNotifier<int> blockedAdsNotifier(String tabId) {
    return _blockedAdsNotifiers.putIfAbsent(
      tabId,
      () => ValueNotifier<int>(_blockedAdsPerTab[tabId] ?? 0),
    );
  }

  int blockedAdsCount(String tabId) => _blockedAdsPerTab[tabId] ?? 0;
  int blockedPopupsCount(String tabId) => _blockedPopupsPerTab[tabId] ?? 0;

  void recordBlockedAd(String tabId, String url) {
    adBlocker.recordBlocked(url);
    final count = (_blockedAdsPerTab[tabId] ?? 0) + 1;
    _blockedAdsPerTab[tabId] = count;
    _evictTrackingMapsIfNeeded();
    final notifier = _blockedAdsNotifiers[tabId];
    if (notifier != null) {
      notifier.value = count;
    }
    notifyListeners();
  }

  void recordBlockedPopup(String tabId) {
    _blockedPopupsPerTab[tabId] = (_blockedPopupsPerTab[tabId] ?? 0) + 1;
    notifyListeners();
  }

  void _evictTrackingMapsIfNeeded() {
    if (_blockedAdsNotifiers.length > 20) {
      final activeIds = tabs.map((t) => t.id).toSet();
      final toRemove = _blockedAdsNotifiers.keys
          .where((k) => !activeIds.contains(k))
          .take(_blockedAdsNotifiers.length - 20)
          .toList();
      for (final k in toRemove) {
        final n = _blockedAdsNotifiers.remove(k);
        n?.dispose();
      }
    }
  }

  // ── Tab Management Facade ──

  BrowserTab createNewTab({
    String initialUrl = '',
    bool isIncognito = false,
    String? id,
    bool autoLoad = true,
    TabOrigin origin = TabOrigin.userDirect,
  }) {
    final tabId = id ?? const Uuid().v4();
    final effectiveUrl =
        (initialUrl.isEmpty || initialUrl == BrowserTab.canonicalBlankUrl)
            ? BrowserTab.canonicalBlankUrl
            : initialUrl;

    final tab = BrowserTab(
      id: tabId,
      url: effectiveUrl,
      title: 'New Tab',
      isIncognito: isIncognito,
      origin: origin,
      isHome: effectiveUrl == BrowserTab.canonicalBlankUrl,
    );

    if (autoLoad && !tab.isHome) {
      try {
        tab.pullToRefreshController = PullToRefreshController(
          settings: PullToRefreshSettings(color: Colors.blue),
          onRefresh: () async {
            await refreshTab(tab);
          },
        );
      } catch (_) {}
    }

    return tab;
  }

  void openInNewTab(
    String url, {
    bool switchTo = false,
    TabOrigin origin = TabOrigin.userDirect,
    bool isIncognito = false,
  }) {
    tabController.openInNewTab(
      url,
      switchTo: switchTo,
      origin: origin,
      isIncognito: isIncognito,
    );
    syncUrlController();
    updateNavState();
  }

  void switchTab(int index) {
    tabController.switchTab(index);
    syncUrlController();
    updateNavState();
  }

  void closeTab(String tabId) {
    tabController.closeTab(tabId);
    cleanupTabState(tabId);
    syncUrlController();
    updateNavState();
  }

  void closeAllTabs() {
    tabController.closeAllTabs();
    syncUrlController();
    updateNavState();
  }

  void closeOtherTabs(String tabId) {
    tabController.closeOtherTabs(tabId);
    syncUrlController();
    updateNavState();
  }

  void duplicateTab(dynamic tabOrId) {
    tabController.duplicateTab(tabOrId);
    syncUrlController();
    updateNavState();
  }

  void clearRecentlyClosedTabs() {
    tabController.clearRecentlyClosedTabs();
  }

  void restoreRecentlyClosedTab() {
    tabController.restoreRecentlyClosedTab();
    syncUrlController();
    updateNavState();
  }

  void suspendTab(BrowserTab tab) {
    tabController.suspendTab(tab);
  }

  void resumeTab(BrowserTab tab) {
    tabController.resumeTab(tab);
  }

  void syncUrlController() {
    navigationController.syncUrlController(activeTab);
  }

  // FIX(D6): Public refresh so views outside the controller (e.g. tab view
  // video detection) can push UI updates without touching notifyListeners.
  void refreshChrome() {
    if (_isDisposed) return;
    notifyListeners();
  }

  void updateNavState() async {
    final tab = activeTab;
    if (tab?.controller == null || _isDisposed) return;
    final tabId = tab!.id;
    try {
      final results = await Future.wait([
        tab.controller!.canGoBack(),
        tab.controller!.canGoForward(),
      ]);
      if (activeTab?.id == tabId && !_isDisposed) {
        tab.canGoBack = results[0];
        tab.canGoForward = results[1];
        notifyListeners();
      }
    } catch (_) {}
  }

  void cleanupTabState(String tabId) {
    _loadingTimeoutTimers.remove(tabId)?.cancel();
    final n = _blockedAdsNotifiers.remove(tabId);
    n?.dispose();
    _blockedAdsPerTab.remove(tabId);
    _blockedPopupsPerTab.remove(tabId);
    mediaSniffer.cleanupTab(tabId);
    // FIX(B12): Drop the tab from the inactivity watchdog's paused set so no
    // stale id lingers after the tab is closed.
    inactivityWatchdog.clearTab(tabId);
  }

  // ── Navigation Facade ──

  Future<void> navigateToUrl(String rawUrl) =>
      navigationController.navigateToUrl(rawUrl);

  Future<void> goBack() async {
    final tab = activeTab;
    if (tab != null) {
      navigatingBackForwardTabIds[tab.id] = true;
      try {
        await navigationController.goBack();
      } finally {
        Future.delayed(const Duration(milliseconds: 500), () {
          navigatingBackForwardTabIds.remove(tab.id);
        });
      }
    }
  }

  Future<void> goForward() async {
    final tab = activeTab;
    if (tab != null) {
      navigatingBackForwardTabIds[tab.id] = true;
      try {
        await navigationController.goForward();
      } finally {
        Future.delayed(const Duration(milliseconds: 500), () {
          navigatingBackForwardTabIds.remove(tab.id);
        });
      }
    }
  }

  Future<void> reload() => navigationController.reload();
  Future<void> stopLoading() => navigationController.stopLoading();
  void loadHome() => navigationController.loadHome();

  // FIX(D8): Injects the element-picker script into the active tab and listens
  // on the XdmPickerChannel JS handler. When the user clicks an element, the
  // selector is turned into an ad-block rule, persisted, and the tab reloads.
  Future<void> startElementPicker(BrowserTab tab) async {
    final webController = tab.controller;
    if (webController == null) return;
    try {
      webController.addJavaScriptHandler(
        handlerName: 'XdmPickerChannel',
        callback: (args) {
          if (args.isEmpty) return;
          _handlePickerMessage(args.first.toString());
        },
      );
      await webController.evaluateJavascript(
        source: ElementPickerService.pickerScript,
      );
    } catch (e, st) {
      _log.warning('Element picker injection failed', e, st);
    }
  }

  void _handlePickerMessage(String raw) {
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (decoded['action'] == 'cancel') return;
      final selector = decoded['selector'] as String? ?? '';
      if (selector.isEmpty) return;
      final rule = ElementPickerService.blockRule(selector);
      if (rule.isEmpty) return;
      AdBlockerService.instance.addCustomRule(rule);
      final tab = activeTab;
      if (tab?.controller != null) {
        reload();
      }
    } catch (e, st) {
      _log.warning('Element picker message parse failed', e, st);
    }
  }

  Future<void> refreshTab(BrowserTab tab) async {
    if (tab.isHome || tab.url.isEmpty) {
      tab.pullToRefreshController?.endRefreshing();
      return;
    }
    if (tab.controller != null) {
      await tab.controller!.reload();
    }
    tab.pullToRefreshController?.endRefreshing();
  }

  // ── Download & Media Facade ──

  Future<void> setSnifferEnabled(bool value) =>
      downloadCoordinator.setSnifferEnabled(value);

  // ── Lifecycle & Security ──

  void handleAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        tabManager.saveTabsImmediately();
        for (final tab in tabs) {
          if (tab.controller != null) {
            tab.controller?.evaluateJavascript(
              source:
                  'document.querySelectorAll("video, audio").forEach(m => m.pause());',
            );
          }
        }
        break;
      case AppLifecycleState.detached:
        tabManager.saveTabsImmediately();
        break;
      case AppLifecycleState.resumed:
        break;
      default:
        break;
    }
  }

  Future<void> quitBrowser({BuildContext? context}) async {
    await tabManager.saveTabsImmediately();

    for (final tab in tabs) {
      if (tab.isIncognito) {
        try {
          if (tab.url.isNotEmpty && tab.url != BrowserTab.canonicalBlankUrl) {
            await CookieManager.instance().deleteCookies(url: WebUri(tab.url));
          }
          await tab.controller?.evaluateJavascript(
            source: 'localStorage.clear(); sessionStorage.clear();',
          );
        } catch (_) {}
      }
    }

    if (context != null && context.mounted) {
      Provider.of<DownloadProvider>(context, listen: false)
          .setActiveTabIndex(0);
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> restoreTabs() async {
    if (_isRestoring) return;
    _isRestoring = true;
    notifyListeners();

    try {
      await tabController.restoreTabs();
    } catch (e, st) {
      _log.warning('Tab restoration failed: $e', e, st);
    } finally {
      _isRestoring = false;
      notifyListeners();
    }
  }

  // ── Webview Lifecycle Interception ──

  void handlePageLoadStart(BrowserTab tab, String? url) {
    if (_isDisposed) return;
    tab.isLoading = true;
    tab.isTimedOut = false;
    tab.hasError = false;
    tab.hasCrashed = false;
    tab.errorDescription = null;
    // FIX(B3): Reset the per-tab silent crash-reload flag on every load start.
    tab.hasAttemptedSilentReload = false;

    if (url != null) {
      tab.updateUrl(url);
      syncUrlController();
    }

    _loadingTimeoutTimers[tab.id]?.cancel();
    _loadingTimeoutTimers[tab.id] = Timer(const Duration(seconds: 25), () {
      if (tab.isLoading && !_isDisposed) {
        tab.isTimedOut = true;
        tab.isLoading = false;
        notifyListeners();
      }
    });

    mediaSniffer.cleanupTab(tab.id);

    if (url != null && tab.controller != null) {
      _applyUserAgent(tab, url);
    }

    // Early script injection at document start (B7, B3)
    if (tab.controller != null && url != null) {
      if (settingsProvider.antiFingerprinting) {
        tab.controller
            ?.evaluateJavascript(source: FingerprintManager.fingerprintHideJs);
      }
      if (adBlocker.isEnabled) {
        tab.controller?.evaluateJavascript(source: adBlocker.service.earlyJs);
        if (url.contains('youtube.com') || url.contains('youtu.be')) {
          tab.controller
              ?.evaluateJavascript(source: AdBlockerService.youtubeEarlyJs);
        }
      }
      if (settingsProvider.forceDarkMode) {
        tab.controller?.evaluateJavascript(
          source: ScriptInjector.buildSmartForceDarkScript(),
        );
      }
      tab.controller
          ?.evaluateJavascript(source: ScriptInjector.kLongPressScript);
    }

    notifyListeners();
  }

  Future<void> _applyUserAgent(BrowserTab tab, String url) async {
    final lower = url.toLowerCase();
    String? customUa;
    if (lower.contains('accounts.google.com') ||
        lower.contains('accounts.youtube.com')) {
      customUa =
          'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
    } else if (settingsProvider.desktopMode) {
      customUa =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
    }

    if (customUa != null) {
      try {
        await tab.controller?.setSettings(
          settings: InAppWebViewSettings(userAgent: customUa),
        );
      } catch (_) {}
    }
  }

  Future<void> handlePageLoadStop(BrowserTab tab, String? url) async {
    if (_isDisposed) return;
    _loadingTimeoutTimers[tab.id]?.cancel();
    tab.isTimedOut = false;

    if (url != null) {
      tab.updateUrl(url);
      syncUrlController();

      try {
        final title = await tab.controller?.getTitle();
        if (title != null && title.isNotEmpty) {
          tab.title = title;
        }
      } catch (_) {}

      historyManager.recordVisit(
        url: url,
        title: tab.title,
        isIncognito: tab.isIncognito,
      );

      fetchAndCacheFavicon(tab, url);

      try {
        await _injectPageScripts(tab, url);
      } catch (e, st) {
        _log.warning('Script injection error on page stop: $e', e, st);
      }

      if (isSnifferEnabled && !tab.isHome) {
        mediaSniffer.scheduleScan(tab, tabs: tabs);
      }
    }

    tab.isLoading = false;
    updateNavState();
    tabManager.saveTabs();
    notifyListeners();
  }

  Future<void> _injectPageScripts(BrowserTab tab, String url) async {
    if (tab.controller == null) return;
    final uri = Uri.tryParse(url);
    final host = uri?.host.toLowerCase() ?? '';

    // Direct SiteSettingsStore lookup (B1)
    final siteSettings = await siteSettingsStore.getForHost(host);

    if (siteSettings.zoomLevel != null && siteSettings.zoomLevel! > 0) {
      await tab.controller?.zoomBy(zoomFactor: siteSettings.zoomLevel!);
    }

    final customJs = siteSettings.customJs?.join('\n') ?? '';
    final customCss = siteSettings.customCss?.join('\n') ?? '';

    await scriptInjector.injectAllScripts(
      tab,
      url,
      settings: settingsProvider,
      adBlocker: adBlocker.service,
      customJs: customJs,
      customCss: customCss,
    );
  }

  void handlePageError(BrowserTab tab, String errorDescription) {
    if (_isDisposed) return;
    _loadingTimeoutTimers[tab.id]?.cancel();
    tab.isLoading = false;
    tab.hasError = true;
    tab.errorDescription = errorDescription;
    notifyListeners();
  }

  void handleTabCrash(BrowserTab tab) {
    if (_isDisposed) return;
    _loadingTimeoutTimers[tab.id]?.cancel();
    tab.isLoading = false;
    tab.hasCrashed = true;
    notifyListeners();
  }

  void handlePageProgress(BrowserTab tab, int progress) {
    if (_isDisposed) return;
    final pct = progress / 100.0;
    if ((pct - tab.progress).abs() < 0.02 && progress != 100) return;
    tab.progress = pct;
    if (progress == 100 || progress % 10 == 0) {
      notifyListeners();
    }
  }

  // ── Favicon Caching ──

  Future<void> fetchAndCacheFavicon(BrowserTab tab, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty || tab.isIncognito) return;
    final domain = uri.host.toLowerCase();

    final lastFetch = _faviconCache[domain];
    if (lastFetch != null &&
        DateTime.now().difference(lastFetch).inMinutes < 60) {
      return;
    }
    _faviconCache[domain] = DateTime.now();

    final faviconUrl = '${uri.scheme}://${uri.host}/favicon.ico';
    try {
      final request = await _faviconHttpClient.getUrl(Uri.parse(faviconUrl));
      final response = await request.close();
      if (response.statusCode == 200) {
        final contentType = response.headers.contentType?.mimeType.toLowerCase() ?? '';
        if (contentType.contains('html') || contentType.contains('text')) {
          return;
        }
        final bytes = await consolidateHttpClientResponseBytes(response);
        if (bytes.isNotEmpty && bytes.length <= 256 * 1024) {
          tab.faviconBytes = bytes;
          notifyListeners();
        }
      }
    } catch (_) {}
  }

  // ── Incognito Banner & UI State ──

  Future<void> dismissIncognitoBanner() async {
    _incognitoBannerDismissed = true;
    await prefsRepo.setIncognitoBannerDismissed(true);
    notifyListeners();
  }

  // ── Find In Page ──

  void openFindPanel() {
    _findPanelVisible = true;
    notifyListeners();
  }

  void closeFindPanel() {
    _findPanelVisible = false;
    findTextController.clear();
    _findMatchCount = 0;
    _findActiveMatch = 0;
    activeTab?.findInteractionController?.clearMatches();
    notifyListeners();
  }

  Future<void> searchFindQuery(String query) async {
    final tab = activeTab;
    if (tab == null || tab.findInteractionController == null) return;
    tab.findQuery = query;
    if (query.isEmpty) {
      await tab.findInteractionController!.clearMatches();
      _findMatchCount = 0;
      _findActiveMatch = 0;
    } else {
      await tab.findInteractionController!.findAll(find: query);
    }
    notifyListeners();
  }

  Future<void> findNext() async {
    await activeTab?.findInteractionController?.findNext(forward: true);
  }

  Future<void> findPrevious() async {
    await activeTab?.findInteractionController?.findNext(forward: false);
  }

  // ── Reader Mode ──

  Future<void> activateReaderMode(BrowserTab? tab) async {
    final target = tab ?? activeTab;
    if (target == null || target.controller == null) return;
    try {
      final article = await ReaderModeService.extract(target.controller!);
      if (article != null) {
        _readerArticle = article;
        _readerTabId = target.id;
        _readerControlsVisible = true;
        _readerTheme = settingsProvider.isDarkMode ? 'dark' : 'light';
        notifyListeners();
      }
    } catch (e, st) {
      _log.warning('Failed to activate reader mode: $e', e, st);
    }
  }

  void closeReaderMode() {
    _readerArticle = null;
    _readerTabId = null;
    _readerControlsVisible = false;
    notifyListeners();
  }

  // ── Form Autofill ──

  void handleAutofillMessage(dynamic raw) {
    try {
      final Map<String, dynamic> data = (raw is String)
          ? (jsonDecode(raw) as Map<String, dynamic>)
          : (raw is Map ? Map<String, dynamic>.from(raw) : {});
      final url = data['url'] as String? ?? '';
      final fields =
          (data['fields'] as Map<String, dynamic>?)?.cast<String, String>() ??
              {};
      final uri = Uri.tryParse(url);
      final host = uri?.host.toLowerCase() ?? '';
      if (host.isNotEmpty && fields.isNotEmpty) {
        queueAutofill(host, fields);
      }
    } catch (e, st) {
      _log.warning('Autofill message parse failed: $e', e, st);
    }
  }

  void queueAutofill(String host, Map<String, String> formData) {
    if (host.isEmpty || formData.isEmpty || settingsProvider.incognitoEnabled) {
      return;
    }
    _pendingAutofillData = Map.from(formData);
    _autofillDebounceTimer?.cancel();
    _autofillDebounceTimer =
        Timer(const Duration(milliseconds: 1500), () async {
      // FIX(B1): Guard timer callback against post-dispose execution.
      if (_isDisposed) return;
      if (_pendingAutofillData != null) {
        try {
          final settings = await siteSettingsStore.getForHost(host);
          await siteSettingsStore.saveForHost(
            host,
            settings.copyWith(
              customJs: [
                ...settings.customJs ?? [],
                '/* autofill */ window.__autofill = ${jsonEncode(_pendingAutofillData)};',
              ],
            ),
          );
        } catch (_) {}
        _pendingAutofillData = null;
      }
    });
  }

  // ── Offline Page Saving ──

  Future<void> savePageOffline(BrowserTab tab, {BuildContext? context}) async {
    if (tab.controller == null || tab.url.isEmpty) return;
    try {
      final html = await tab.controller?.getHtml();
      if (html != null && html.isNotEmpty) {
        final dir = await getApplicationDocumentsDirectory();
        final offlineDir = Directory(p.join(dir.path, 'offline_pages'));
        if (!offlineDir.existsSync()) {
          offlineDir.createSync(recursive: true);
        }
        final safeName = tab.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final file = File(p.join(offlineDir.path,
            '${safeName}_${DateTime.now().millisecondsSinceEpoch}.html'));
        await file.writeAsString(html);
        if (context != null && context.mounted) {
          ThemedSnackbar.show(
            context,
            message: 'Page saved for offline viewing',
            color: AppTheme.neonGreen,
            icon: Icons.check_circle_outline,
            isDarkMode: settingsProvider.isDarkMode,
          );
        }
      }
    } catch (e, st) {
      _log.warning('Save offline error', e, st);
    }
  }

  // ── Zoom Management ──

  Future<void> setZoomLevel(String host, double level) async {
    if (host.isNotEmpty) {
      await siteSettingsStore.setZoom(host, level);
    }
    final tab = activeTab;
    if (tab != null &&
        tab.host == host.toLowerCase() &&
        tab.controller != null) {
      await tab.controller?.zoomBy(zoomFactor: level);
    }
    notifyListeners();
  }

  Future<void> setPageZoom(double level) async {
    final tab = activeTab;
    if (tab?.controller == null) return;
    final uri = Uri.tryParse(tab!.url);
    final host = uri?.host.toLowerCase() ?? '';
    if (host.isNotEmpty) {
      await siteSettingsStore.setZoom(host, level);
    }
    await tab.controller?.zoomBy(zoomFactor: level);
    notifyListeners();
  }

  // ── Protocol / URL sanitization ──

  String cleanUrl(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.contains('://') &&
        !trimmed.startsWith('about:') &&
        trimmed.isNotEmpty) {
      return 'https://$trimmed';
    }
    return trimmed;
  }

  @override
  void dispose() {
    if (_isDisposed) return;

    // FIX(B1): Cancel autofill debounce timer BEFORE marking as disposed so
    // the timer callback can still be inspected; null out pending data.
    _autofillDebounceTimer?.cancel();
    _autofillDebounceTimer = null;
    _pendingAutofillData = null;

    _isDisposed = true;

    _sharedHttpClient?.close(force: true);

    for (final t in _loadingTimeoutTimers.values) {
      t.cancel();
    }
    _loadingTimeoutTimers.clear();

    for (final n in _blockedAdsNotifiers.values) {
      n.dispose();
    }
    _blockedAdsNotifiers.clear();

    findTextController.dispose();
    showBarsNotifier.dispose();
    tabStripScrollController.dispose();

    tabController.removeListener(notifyListeners);
    tabController.dispose();

    navigationController.removeListener(notifyListeners);
    navigationController.dispose();

    downloadCoordinator.removeListener(notifyListeners);
    downloadCoordinator.dispose();

    inactivityWatchdog.dispose();

    super.dispose();
  }
}
