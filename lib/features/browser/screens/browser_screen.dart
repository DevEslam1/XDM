import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart' show Dio, DioException, Options, ResponseType;
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../../core/app_theme.dart';
import '../../../core/services/database/app_database.dart';
import '../../../core/services/database_service.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/services/user_script_manager.dart' hide UserScript;
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/url_utils.dart';
import '../../../shared/mixins/pausable_loop_animation.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../add_download/widgets/add_download_dialog.dart';
import '../../add_download/widgets/youtube_playlist_sheet.dart';
import '../../add_download/widgets/media_quality_sheet.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/bookmark.dart';
import '../models/browser_tab.dart';
import '../services/fingerprint_manager.dart';
import '../services/script_injector.dart';
import '../services/inactivity_watchdog.dart';
import '../services/browser_detector.dart';
import '../services/ad_blocker_delegate.dart';
import '../services/ad_blocker_service.dart';
import '../services/download_interceptor.dart';
import '../services/element_picker_service.dart';
import '../services/history_manager.dart';
import '../services/long_press_parser.dart';
import '../services/media_sniffer.dart';
import '../services/reader_mode_service.dart';
import '../services/tab_manager.dart';
import '../services/redirect_guard.dart';
import '../services/page_intent_classifier.dart';
import '../screens/script_manager_screen.dart';
import '../widgets/bookmark_manager_screen.dart';
import '../widgets/browser_download_sheet.dart';
import '../widgets/browser_history_sheet.dart';
import '../widgets/browser_home_page.dart';
import '../widgets/redirect_sheet.dart';
import 'package:logging/logging.dart';

class JavaScriptMessage {
  final String message;
  const JavaScriptMessage({required this.message});
}

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen>
    with HapticHelper, WidgetsBindingObserver {
  static final _log = Logger('BrowserScreen');

  late final TabManager _tabManager = TabManager(
    isActive: () => mounted,
    setHostState: setState,
    createTab: _createNewTab,
    resolveDatabase: () => context.read<DatabaseService>(),
    fallbackTitle: () => L10n.of(context, 'browser_new_tab'),
    cleanupTabState: _cleanupTabState,
    syncUrlController: () {
      if (_tabs.isNotEmpty) {
        _urlController.text =
            _tabs[_currentTabIndex].isHome ? '' : _tabs[_currentTabIndex].url;
      }
    },
    updateNavState: _updateNavState,
  );

  final List<String> _tabIdHistory = [];

  List<BrowserTab> get _tabs => _tabManager.tabs;
  int get _currentTabIndex => _tabManager.currentIndex;
  set _currentTabIndex(int value) {
    if (value >= 0 && value < _tabs.length) {
      final oldActiveTab = _tabs.length > _currentTabIndex && _currentTabIndex >= 0
          ? _tabs[_currentTabIndex]
          : null;
      if (oldActiveTab != null && oldActiveTab.id != _tabs[value].id) {
        if (_tabIdHistory.isEmpty || _tabIdHistory.last != oldActiveTab.id) {
          _tabIdHistory.add(oldActiveTab.id);
        }
      }
    }
    _tabManager.currentIndex = value;
  }

  final TextEditingController _urlController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _isFocused = false;
  final ValueNotifier<bool> _showBarsNotifier = ValueNotifier<bool>(true);
  double _lastScrollY = 0;
  String _customJs = '';
  String _customCss = '';

  // E6: Element Picker State
  bool _isPickerModeActive = false;

  // E9 & E10: Blocked Popups and Ads Counters
  // ignore: unused_field - incremented for state tracking; displayed via ThemedSnackbar
  int _blockedPopupCount = 0;
  int _blockedAdsCount = 0;

  // E13: Tab Suspension/Resume Visual Feedback
  String? _restoringTabId;

  late final MediaSniffer _sniffer = MediaSniffer(
    isActive: () => mounted,
    containsTab: (tab) => _tabs.contains(tab),
    isSnifferEnabled: () => _isSnifferEnabled,
    onStateChanged: () {
      if (mounted) setState(() {});
    },
  );

  Map<String, String> get _detectedDownloadUrls =>
      _sniffer.detectedDownloadUrls;
  Map<String, List<Map<String, dynamic>>> get _detectedMediaSources =>
      _sniffer.detectedMediaSources;
  Map<String, int> get _detectedPlaylistUrls => _sniffer.detectedPlaylistUrls;
  Map<String, DateTime> get _ytDetectionFailed => _sniffer.ytDetectionFailed;
  Map<String, bool> get _mediaScanFailed => _sniffer.mediaScanFailed;
  Map<String, DateTime> get _lastYoutubeAuthTimes =>
      _sniffer.lastYoutubeAuthTimes;

  static const _youtubeAuthCooldown = Duration(seconds: 30);
  Map<String, Timer> get _mediaScanTimers => _sniffer.mediaScanTimers;

  bool _quitPersisted = false;
  bool _isRestoring = false;

  final AdBlockerDelegate _adBlocker = AdBlockerDelegate();
  final RedirectGuard _redirectGuard = RedirectGuard.instance;

  String? _lastInterceptedUrl;
  DateTime? _lastInterceptedTime;

  void _ensureTabsExist() {
    if (_tabs.isEmpty && !_isRestoring) {
      _restoreTabs();
    }
  }

  DownloadProvider? _downloadProvider;

  late final BrowserHistoryManager _historyManager = BrowserHistoryManager(
    resolveDatabase: () => Provider.of<DatabaseService>(context, listen: false),
    isIncognito: () =>
        Provider.of<SettingsProvider>(context, listen: false).incognitoEnabled,
    cleanUrl: _cleanUrl,
    isActive: () => mounted,
  );

  late final DownloadInterceptor _interceptor = DownloadInterceptor(
    resolveDownloadProvider: () =>
        Provider.of<DownloadProvider>(context, listen: false),
    resolveActiveTab: () =>
        (_currentTabIndex >= 0 && _currentTabIndex < _tabs.length)
            ? _tabs[_currentTabIndex]
            : null,
  );

  final ScrollController _dashboardScrollController = ScrollController();
  List<Timer> get _pendingTimers => _tabManager.pendingTimers;
  Timer? _navDebounce;

  static const String _snifferPrefKey = 'browserSnifferEnabled';
  bool _isSnifferEnabled = true;
  bool _lastZoomEnabled = false;
  String? _homeReturnUrl;

  static const String _longPressChannel = 'XDM_LongPress';
  static const String _popupsChannel = 'XDM_Popups';
  static const String _pickerChannel = 'XdmPickerChannel';

  // ─────────────────────────────────────────────────────────────
  // Tab persistence
  // ─────────────────────────────────────────────────────────────
  Future<void> _saveTabs() => _tabManager.saveTabs();

  final List<String> _lruTabIds = [];
  final Map<String, Timer> _loadingTimeoutTimers = {};

  final _inactivityWatchdog = InactivityWatchdog();

  void _pauseTabMedia(BrowserTab tab) => _inactivityWatchdog.pauseTabMedia(tab);

  void _updateLruOrder() {
    if (_tabs.isEmpty) {
      _lruTabIds.clear();
      return;
    }
    final validIds = _tabs.map((t) => t.id).toSet();
    _lruTabIds.removeWhere((id) => !validIds.contains(id));

    if (_currentTabIndex >= 0 && _currentTabIndex < _tabs.length) {
      final activeTab = _tabs[_currentTabIndex];
      _lruTabIds.remove(activeTab.id);
      _lruTabIds.insert(0, activeTab.id);
    }
    if (_lruTabIds.length > 3) {
      _lruTabIds.removeRange(3, _lruTabIds.length);
    }
  }

  void _onTabSwitched(int oldIndex, int newIndex) {
    // E9 & E10: Reset counters on tab switch
    setState(() {
      _blockedPopupCount = 0;
      _blockedAdsCount = 0;
    });

    if (oldIndex >= 0 && oldIndex < _tabs.length && oldIndex != newIndex) {
      final oldTab = _tabs[oldIndex];
      _pauseTabMedia(oldTab);
    }
    if (newIndex >= 0 && newIndex < _tabs.length) {
      final newTab = _tabs[newIndex];
      if (newTab.isSuspended) {
        _resumeTab(newTab);
      }
      if (!newTab.isHome &&
          newTab.url.isNotEmpty &&
          newTab.url != 'about:blank') {
        newTab.controller?.getUrl().then((webUri) {
          final currentUrl = webUri?.toString();
          if (mounted &&
              (currentUrl == null ||
                  currentUrl.isEmpty ||
                  currentUrl == 'about:blank')) {
            try {
              newTab.controller
                  ?.loadUrl(urlRequest: URLRequest(url: WebUri(newTab.url)));
            } catch (e, st) {
              Logger('browser_screen')
                  .warning('[browser_screen] operation failed', e, st);
            }
          }
        }).catchError((_) {
          if (mounted) {
            try {
              newTab.controller
                  ?.loadUrl(urlRequest: URLRequest(url: WebUri(newTab.url)));
            } catch (e, st) {
              Logger('browser_screen')
                  .warning('[browser_screen] operation failed', e, st);
            }
          }
        });
      }
    }
  }

  void _switchTab(int newIndex) {
    if (newIndex == _currentTabIndex && _tabs.isNotEmpty) return;
    final oldIndex = _currentTabIndex;
    setState(() {
      _currentTabIndex = newIndex;
      _updateLruOrder();
      if (_tabs.isNotEmpty &&
          _currentTabIndex >= 0 &&
          _currentTabIndex < _tabs.length) {
        final tab = _tabs[_currentTabIndex];
        _urlController.text = tab.isHome ? '' : tab.url;
        _showBarsNotifier.value = true;
      }
    });
    _onTabSwitched(oldIndex, newIndex);
    _saveTabs();
    _suspendBackgroundTabs();
  }

  Future<void> _restoreTabs() async {
    assert(!_isRestoring, 'restoreTabs re-entered');
    if (_isRestoring) return;
    _isRestoring = true;
    try {
      await _tabManager.restoreTabs();
      // E14: Tab Persistence/Restore Visual Feedback
      if (mounted && _tabs.length > 1) {
        final isDark = context.read<SettingsProvider>().isDarkMode;
        ThemedSnackbar.show(
          context,
          message: 'Restored ${_tabs.length} tabs',
          icon: Icons.restore_rounded,
          color: AppTheme.neonBlue,
          isDarkMode: isDark,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isRestoring = false;
        });
      } else {
        _isRestoring = false;
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _adBlocker.addListener(_updateAdBlockSettings);
    WidgetsBinding.instance.addObserver(this);

    _focusNode.addListener(() {
      if (_isFocused != _focusNode.hasFocus) {
        if (mounted) {
          setState(() {
            _isFocused = _focusNode.hasFocus;
          });
        }
      }
      if (_focusNode.hasFocus && mounted) {
        _urlController.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _urlController.text.length,
        );
      }
    });

    _loadSnifferPref();
    _loadCustomJsCss();
    UserScriptManager.instance.load();

    _dashboardScrollController.addListener(_onDashboardScroll);
    unawaited(_adBlocker.init());
    _redirectGuard.init();
  }

  Future<void> _updateAdBlockSettings() async {
    if (!mounted) return;
    for (final tab in _tabs) {
      if (tab.controller != null) {
        try {
          await tab.controller!.setSettings(
            settings: InAppWebViewSettings(
              contentBlockers: _adBlocker.contentBlockers,
              incognito: tab.isIncognito,
            ),
          );
        } catch (e) {
          if (e is MissingPluginException) {
            tab.controller = null;
          } else {
            _log.warning(
                '[Browser] Failed to update settings for tab ${tab.id}: $e');
          }
        }
      }
    }
    _resetInactivityTimer();
  }

  void _resetInactivityTimer() {
    _inactivityWatchdog.resetTimer(
      isMounted: mounted,
      onTimeout: _onInactivityTimeout,
    );
  }

  void _onInactivityTimeout() {
    _inactivityWatchdog.hibernate(
      isMounted: mounted,
      tabs: _tabs,
      currentTabIndex: _currentTabIndex,
      cancelScanTimers: () {
        _sniffer.cancelAllScanTimers();
        for (final timer in _loadingTimeoutTimers.values) {
          timer.cancel();
        }
        _loadingTimeoutTimers.clear();
      },
      saveTabs: _saveTabs,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _inactivityWatchdog.handleAppLifecycleState(
      state: state,
      tabs: _tabs,
      resetInactivityTimer: _resetInactivityTimer,
    );
  }

  @override
  void didHaveMemoryPressure() {
    super.didHaveMemoryPressure();
    _onInactivityTimeout();
    if (mounted && _tabs.isNotEmpty) {
      setState(() {
        if (_currentTabIndex >= 0 && _currentTabIndex < _tabs.length) {
          final activeId = _tabs[_currentTabIndex].id;
          _lruTabIds
            ..clear()
            ..add(activeId);
        }
      });
    }
  }

  Future<void> _safeReloadTab(BrowserTab tab) async {
    if (!mounted) return;

    if (tab.hasCrashed) {
      setState(() {
        tab.hasCrashed = false;
        tab.isTimedOut = false;
        tab.isLoading = true;
        tab.controller = null;
      });
      return;
    }

    setState(() {
      tab.isTimedOut = false;
      tab.isLoading = true;
    });

    final controller = tab.controller;
    if (controller != null) {
      try {
        await controller.reload();
        return;
      } catch (e) {
        _log.warning('[Browser] controller.reload() failed: $e');
        try {
          if (tab.url.isNotEmpty && tab.url != 'about:blank') {
            await controller.loadUrl(
              urlRequest: URLRequest(url: WebUri(tab.url)),
            );
            return;
          }
        } catch (e2) {
          _log.warning('[Browser] controller.loadUrl() failed: $e2');
        }
      }
    }

    if (mounted) {
      setState(() {
        tab.controller = null;
      });
    }
  }

  Future<void> _refreshTabForPull(BrowserTab tab) async {
    await _safeReloadTab(tab);

    // Keep the native indicator visible for a bounded three seconds.
    await Future<void>.delayed(const Duration(seconds: 3));
    final pullToRefresh = tab.pullToRefreshController;
    if (pullToRefresh != null) {
      try {
        await pullToRefresh.endRefreshing();
      } catch (_) {
        // The controller may be disposed during tab eviction.
      }
    }
  }

  BrowserTab _createNewTab({
    String initialUrl = 'about:blank',
    bool isIncognito = false,
    String? id,
    bool autoLoad = true,
  }) {
    final cleanInitialUrl = (initialUrl.isEmpty || initialUrl == 'about:blank')
        ? 'about:blank'
        : initialUrl;
    final tabId = id ??
        '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(999999)}';

    final tab = BrowserTab(
      id: tabId,
      url: cleanInitialUrl == 'about:blank' ? '' : cleanInitialUrl,
      title: cleanInitialUrl == 'about:blank'
          ? L10n.of(context, 'browser_new_tab')
          : cleanInitialUrl,
      isIncognito: isIncognito,
      isHome: cleanInitialUrl == 'about:blank',
    );

    // Create PullToRefreshController HERE — before the InAppWebView widget is
    // built — so flutter_inappwebview can register it at construction time.
    // Creating it inside onWebViewCreated (after the widget is already built
    // with pullToRefreshController: null) causes a lifecycle mismatch that
    // leads to "AndroidPullToRefreshController used after being disposed".
    //
    // The onRefresh closure captures `tab`. At call time tab.controller is
    // already set by _configureController, so the reload is delegated correctly
    // without needing to re-create the controller or call any non-existent
    // setOnRefreshCallback API.
    try {
      tab.pullToRefreshController = PullToRefreshController(
        settings: PullToRefreshSettings(color: AppTheme.neonBlue),
        onRefresh: () => _refreshTabForPull(tab),
      );
    } catch (e) {
      _log.fine(
          'PullToRefreshController not supported or uninitialized in current environment: $e');
    }

    return tab;
  }

  void _configureController(BrowserTab tab, InAppWebViewController controller) {
    tab.controller = controller;
    final settings = Provider.of<SettingsProvider>(context, listen: false);

    // Register JS handlers (channels)
    controller.addJavaScriptHandler(
      handlerName: _longPressChannel,
      callback: (args) {
        final msg = args.isNotEmpty ? args.first.toString() : '';
        _handleLongPressMessageForTab(tab, JavaScriptMessage(message: msg));
      },
    );
    controller.addJavaScriptHandler(
      handlerName: _popupsChannel,
      callback: (args) {
        final msg = args.isNotEmpty ? args.first.toString() : '';
        _handlePopupMessageForTab(tab, JavaScriptMessage(message: msg));
      },
    );
    controller.addJavaScriptHandler(
      handlerName: _pickerChannel,
      callback: (args) {
        final msg = args.isNotEmpty ? args.first.toString() : '';
        _handlePickerMessageForTab(tab, JavaScriptMessage(message: msg));
      },
    );

    // Configure user agent and zoom
    controller.setSettings(
        settings: InAppWebViewSettings(
      useShouldOverrideUrlLoading: true,
      useOnDownloadStart: true,
      userAgent:
          _resolveUserAgent(isIncognito: tab.isIncognito, settings: settings),
      supportZoom: settings.desktopMode || settings.pinchToZoom,
      incognito: tab.isIncognito,
    ));
    // NOTE: PullToRefreshController was already created in _createNewTab().
    // Its onRefresh closure captures `tab` and calls tab.controller?.reload(),
    // which now resolves to this controller. No re-creation needed.
  }

  void _onPageStart(BrowserTab tab, String url) async {
    if (url.startsWith('magnet:') || isMagnetUrl(url)) {
      _log.info(
          '[Browser] Stopped webview from navigating to magnet scheme: $url');
      tab.controller?.stopLoading();
      if (await tab.controller?.canGoBack() == true) {
        await tab.controller?.goBack();
      }
      if (mounted) {
        setState(() {
          tab.isLoading = false;
        });
        AddDownloadDialog.show(context, prefilledUrl: url);
      }
      return;
    }
    tab.hasCrashed = false;
    tab.isTimedOut = false;
    _loadingTimeoutTimers[tab.id]?.cancel();
    _loadingTimeoutTimers[tab.id] = Timer(
      const Duration(seconds: 25),
      () {
        if (mounted && tab.isLoading) {
          setState(() {
            tab.isTimedOut = true;
          });
        }
      },
    );

    if (url.contains('accounts.google.com') ||
        url.contains('google.com/ServiceLogin') ||
        url.contains('google.com/accounts')) {
      tab.controller?.setSettings(
          settings: InAppWebViewSettings(
        userAgent:
            'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
        incognito: tab.isIncognito,
      ));
      _hideWebViewFingerprints(tab);
    }

    if (mounted) {
      final downloadProvider = Provider.of<DownloadProvider>(
        context,
        listen: false,
      );
      setState(() {
        tab.isLoading = true;
        tab.progress = 0.0;
        tab.lastRenderedProgress = 0;
        tab.url = _cleanUrl(url);
        if (url != 'about:blank') {
          tab.isHome = false;
        }
        _showBarsNotifier.value = true;
        _lastScrollY = 0;
        if (_currentTabIndex >= 0 &&
            _currentTabIndex < _tabs.length &&
            _tabs[_currentTabIndex].id == tab.id) {
          _urlController.text = tab.url;
        }
        _detectedDownloadUrls.remove(tab.id);
        _detectedPlaylistUrls.remove(tab.id);
        _detectedMediaSources.remove(tab.id);
        _mediaScanTimers[tab.id]?.cancel();
      });
      downloadProvider.setNavbarVisible(true);
    }

    tab.controller
        ?.evaluateJavascript(source: AdBlockerService.intervalCleanupJs)
        .catchError((_) {});
    _injectTimerSpeedScript(tab);
    _adBlocker.injectAntiDetect(tab);
    _adBlocker.injectEarly(tab);
    _injectLongPressScriptToTab(tab);
    _injectCustomJsCss(tab);

    final settings = Provider.of<SettingsProvider>(context, listen: false);
    _injectDesktopModeScript(tab, settings);

    _updateNavState();
    _delayed(const Duration(milliseconds: 500), _updateNavState);
  }

  void _onPageStop(BrowserTab tab, String url) {
    _loadingTimeoutTimers[tab.id]?.cancel();
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    unawaited(_injectAllScripts(tab, url));

    // E25: Script Injection Visual Feedback
    if (mounted && _customJs.isNotEmpty || _customCss.isNotEmpty) {
      ThemedSnackbar.show(
        context,
        message: 'Scripts injected',
        icon: Icons.code_rounded,
        color: AppTheme.neonGreen,
        isDarkMode: settings.isDarkMode,
      );
    }

    if (mounted) {
      setState(() {
        tab.isLoading = false;
        tab.isTimedOut = false;
        _detectedDownloadUrls.remove(tab.id);
        _detectedMediaSources.remove(tab.id);
      });
      tab.controller?.getTitle().then((t) {
        if (t != null && t.isNotEmpty && mounted && t != tab.title) {
          setState(() {
            tab.title = t;
          });
          if (!tab.isIncognito &&
              !settings.incognitoEnabled &&
              settings.saveBrowserHistory) {
            _recordHistory(url, title: t);
          }
        }
      });
    }

    if (url.contains('accounts.google.com') ||
        url.contains('google.com/ServiceLogin') ||
        url.contains('google.com/accounts')) {
      tab.controller?.evaluateJavascript(source: '''
        (function() {
          var style = document.createElement('style');
          style.textContent = 'body, html { padding-bottom: 350px !important; }';
          document.head.appendChild(style);
          document.addEventListener('focusin', function(e) {
            if (e.target && e.target.scrollIntoView) {
              setTimeout(function() {
                e.target.scrollIntoView({behavior:'smooth', block:'center'});
              }, 350);
            }
          });
          if (window.visualViewport) {
            window.visualViewport.addEventListener('resize', function() {
              var el = document.activeElement;
              if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA')) {
                setTimeout(function() {
                  el.scrollIntoView({behavior:'smooth', block:'center'});
                }, 100);
              }
            });
          }
        })();
      ''');
    }

    if (!tab.isIncognito && !settings.incognitoEnabled) {
      final isYoutubeDomain = url.contains('youtube.com') ||
          url.contains('accounts.google.com') ||
          url.contains('google.com');
      if (isYoutubeDomain) {
        final now = DateTime.now();
        final lastAuth = _lastYoutubeAuthTimes[tab.id];
        if (lastAuth == null ||
            now.difference(lastAuth) > _youtubeAuthCooldown) {
          _lastYoutubeAuthTimes[tab.id] = now;
          YoutubeService.authenticateFromBrowser();
        }
      }
    }

    _updateNavState();
    _delayed(const Duration(milliseconds: 500), _updateNavState);
    _delayed(const Duration(milliseconds: 1200), _updateNavState);

    if (!_isYoutubeHost(tab.url)) {
      _scheduleMediaScan(tab);
    }
  }

  void _onUrlChange(BrowserTab tab, String url) {
    if (url.startsWith('magnet:') || isMagnetUrl(url)) return;
    final cleanUrl = _cleanUrl(url);
    if (tab.url == cleanUrl) return;
    if (mounted) {
      setState(() {
        tab.url = cleanUrl;
        if (cleanUrl.isNotEmpty) {
          tab.isHome = false;
        }
        if (_currentTabIndex >= 0 &&
            _currentTabIndex < _tabs.length &&
            _tabs[_currentTabIndex].id == tab.id) {
          _urlController.text = tab.url;
        }
      });
      _detectedDownloadUrls.remove(tab.id);
      _detectedPlaylistUrls.remove(tab.id);
      _detectedMediaSources.remove(tab.id);
      _ytDetectionFailed.remove(tab.url);

      if (!_isYoutubeHost(tab.url)) {
        _scheduleMediaScan(tab);
      }

      _delayed(const Duration(milliseconds: 1000), () {
        if (mounted) {
          tab.controller?.getTitle().then((t) {
            if (t != null && t.isNotEmpty && mounted) {
              setState(() {
                tab.title = t;
              });
            }
          });
        }
      });
    }
    _updateNavState();
    _delayed(const Duration(milliseconds: 500), _updateNavState);
  }

  void _recordHistory(String url, {String? title}) =>
      _historyManager.recordHistory(url, title: title);

  static bool _isYoutubeHost(String url) => MediaSniffer.isYoutubeHost(url);

  Future<void> _injectTimerSpeedScript(BrowserTab tab) async {
    if (!mounted) return;
    await _scriptInjector.injectTimerSpeedScript(tab);
  }

  Future<void> _injectLongPressScriptToTab(BrowserTab tab) async {
    if (!mounted) return;
    await _scriptInjector.injectLongPressScriptToTab(tab);
  }

  Timer? _mediaScanDebounce;

  void _scheduleMediaScan(BrowserTab tab) {
    _mediaScanDebounce?.cancel();
    _mediaScanDebounce = Timer(const Duration(seconds: 3), () {
      if (mounted && !tab.isSuspended && !tab.isTimedOut) {
        _scanPageMedia(tab);
      }
    });
  }

  void _suspendBackgroundTabs() {
    for (var i = 0; i < _tabs.length; i++) {
      if (i == _currentTabIndex) continue;
      final tab = _tabs[i];
      if (tab.isHome || tab.isSuspended) continue;
      try {
        tab.controller?.evaluateJavascript(source: '''
          try { window.stop(); } catch(e) {}
          var media = document.querySelectorAll('video, audio');
          for (var m = 0; m < media.length; m++) { try { media[m].pause(); } catch(e) {} }
          if (window.__xdmScrollFixInterval) { clearInterval(window.__xdmScrollFixInterval); window.__xdmScrollFixInterval = null; }
          if (window.__xdmYtAdInterval) { clearInterval(window.__xdmYtAdInterval); window.__xdmYtAdInterval = null; }
        ''');
      } catch (_) {}
      tab.isSuspended = true;
      tab.controller = null;
    }
  }

  void _resumeTab(BrowserTab tab) {
    if (!tab.isSuspended) return;
    tab.isSuspended = false;
    try {
      tab.pullToRefreshController ??= PullToRefreshController(
        settings: PullToRefreshSettings(color: AppTheme.neonBlue),
        onRefresh: () => _refreshTabForPull(tab),
      );
    } catch (_) {}

    // E13: Tab Suspension/Resume Visual Feedback
    setState(() {
      _restoringTabId = tab.id;
    });
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _restoringTabId = null;
        });
      }
    });

    _safeReloadTab(tab);
  }

  Future<void> _injectAllScripts(BrowserTab tab, String url) async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    await _scriptInjector.injectAllScripts(
      tab,
      url,
      settings: settings,
      adBlocker: AdBlockerService.instance,
      customJs: _customJs,
      customCss: _customCss,
    );
  }

  void _cleanupTabState(String tabId) {
    _sniffer.cleanupTab(tabId);
    _detectedDownloadUrls.remove(tabId);
    _detectedMediaSources.remove(tabId);
    _mediaScanFailed.remove(tabId);
    _loadingTimeoutTimers[tabId]?.cancel();
    _loadingTimeoutTimers.remove(tabId);

    final tabIndex = _tabs.indexWhere((t) => t.id == tabId);
    if (tabIndex != -1) {
      final tab = _tabs[tabIndex];
      if (tab.isIncognito) {
        try {
          unawaited(InAppWebViewController.clearAllCache());
          unawaited(tab.controller?.evaluateJavascript(
              source:
                  'window.localStorage.clear(); window.sessionStorage.clear();'));
          if (tab.url.isNotEmpty && tab.url != 'about:blank') {
            unawaited(
                CookieManager.instance().deleteCookies(url: WebUri(tab.url)));
          }
        } catch (_) {}
      }
    }
  }

  final _fingerprintManager = FingerprintManager();
  final _scriptInjector = ScriptInjector();

  String _resolveUserAgent({
    required bool isIncognito,
    required SettingsProvider settings,
  }) =>
      _fingerprintManager.resolveUserAgent(
        isIncognito: isIncognito,
        settings: settings,
      );

  Future<void> _applyUserAgent(
    BrowserTab tab,
    SettingsProvider settings,
  ) =>
      _fingerprintManager.applyUserAgent(tab, settings);

  Future<void> _hideWebViewFingerprints(BrowserTab tab) =>
      _fingerprintManager.hideWebViewFingerprints(tab);

  void _injectDesktopModeScript(BrowserTab tab, SettingsProvider settings) =>
      _scriptInjector.injectDesktopModeScript(tab, settings);

  void _handleLongPressMessageForTab(
    BrowserTab tab,
    JavaScriptMessage message,
  ) {
    if (!mounted) return;
    try {
      final payload = LongPressPayload.tryParse(message.message);
      if (payload == null) return;
      final url = payload.url;
      final type = payload.type;
      final settings = Provider.of<SettingsProvider>(context, listen: false);
      triggerHaptic(settings);
      _showLongPressSheet(context, url, type,
          text: payload.text, tabId: tab.id);
    } catch (e) {
      _log.warning(
        '[DMX Browser] Failed to decode/handle long press message: $e',
      );
    }
  }

  void _handlePopupMessageForTab(
    BrowserTab parentTab,
    JavaScriptMessage message,
  ) {
    if (!mounted) return;
    final url = message.message.trim();
    if (url.isEmpty || url == 'about:blank') return;

    // 1. Magnet URL check
    if (url.startsWith('magnet:') || isMagnetUrl(url)) {
      _log.info('[Browser] Intercepted magnet URL in popup: $url');
      AddDownloadDialog.show(context, prefilledUrl: url);
      return;
    }

    // 2. Direct downloadable file check (APKs, ZIPs, Videos, etc.)
    if (BrowserDetector.isAutoDownloadable(url) ||
        _interceptor.shouldIntercept(tabUrl: parentTab.url, requestUrl: url)) {
      _log.info('[Browser] Intercepted downloadable file from popup: $url');
      _showInterceptionSheet(context, url);
      return;
    }

    // 3. Ad-blocker: drop popup ad URLs but silently follow redirect chain
    // to rescue any download that sits behind the ad redirect.
    if (_adBlocker.isEnabled && _adBlocker.shouldBlock(url)) {
      _log.info('[Browser] Blocked ad popup URL: $url');
      _adBlocker.recordBlocked(url);
      _followAndInterceptAdRedirect(url, parentTab);
      return;
    }

    // 4. Open popup URL in new tab directly (Popup Blocking Disabled)
    _log.info('[Browser] Opening popup URL in new tab: $url');
    _redirectGuard.markUserInitiated(url);
    setState(() {
      final newTab = _createNewTab(
        initialUrl: url,
        isIncognito: parentTab.isIncognito,
      );
      _tabs.add(newTab);
      _currentTabIndex = _tabs.length - 1;
      _urlController.text = url;
      _showBarsNotifier.value = true;
    });
    _saveTabs();
  }

  /// Silently follows HTTP redirects from a blocked ad popup URL.
  /// If the redirect chain ends at a downloadable file (APK, ZIP, video, etc.)
  /// the XDM download sheet is shown instead of opening a tab.
  Future<void> _followAndInterceptAdRedirect(
      String adUrl, BrowserTab parentTab) async {
    try {
      final dio = Dio();
      dio.options
        ..connectTimeout = const Duration(seconds: 8)
        ..receiveTimeout = const Duration(seconds: 8)
        ..followRedirects = true
        ..maxRedirects = 10
        ..validateStatus = (s) => true;

      // HEAD first — lightweight, follows redirects without downloading body
      final response = await dio.head<void>(
        adUrl,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
            'Accept': '*/*',
          },
        ),
      );

      final finalUrl =
          response.realUri.toString().isNotEmpty
              ? response.realUri.toString()
              : (response.redirects.isNotEmpty
                  ? response.redirects.last.location.toString()
                  : adUrl);
      final contentType = (response.headers.value('content-type') ?? '').toLowerCase();
      final contentDisposition =
          (response.headers.value('content-disposition') ?? '').toLowerCase();

      final isDownload = contentDisposition.contains('attachment') ||
          contentType.contains('application/octet-stream') ||
          contentType.contains('application/vnd.android.package-archive') ||
          contentType.contains('application/zip') ||
          contentType.contains('application/x-zip') ||
          contentType.contains('application/x-rar') ||
          contentType.contains('video/') ||
          contentType.contains('audio/') ||
          BrowserDetector.isAutoDownloadable(finalUrl) ||
          _interceptor.shouldIntercept(
              tabUrl: parentTab.url, requestUrl: finalUrl);

      if (isDownload && mounted) {
        _log.info(
            '[Browser] Ad redirect resolved to download: $finalUrl (type: $contentType)');
        _showInterceptionSheet(context, finalUrl);
      } else {
        _log.fine(
            '[Browser] Ad redirect did not lead to download (type: $contentType, url: $finalUrl)');
      }
    } on DioException catch (e) {
      _log.fine('[Browser] Ad redirect follow failed: $e');
    } catch (e) {
      _log.fine('[Browser] Ad redirect follow error: $e');
    }
  }

  void _handlePickerMessageForTab(
    BrowserTab tab,
    JavaScriptMessage message,
  ) {
    if (!mounted) return;
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
    if (_tabs[_currentTabIndex].id != tab.id) return;

    String? selector;
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is Map<String, dynamic>) {
        selector = decoded['selector'] as String?;
      }
    } catch (e) {
      _log.warning('[DMX Browser] Failed to decode picker message: $e');
      return;
    }

    if (selector == null || selector.trim().isEmpty) return;
    _confirmBlockElement(tab, selector.trim());
  }

  void _confirmBlockElement(BrowserTab tab, String selector) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final rule = ElementPickerService.blockRule(selector);

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
        title: Text(L10n.of(context, 'block_element')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Hide this element on every page?',
              style: TextStyle(
                color:
                    isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
              ),
            ),
            const SizedBox(height: 8),
            SelectableText(
              rule,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: accent,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(L10n.of(context, 'cancel_btn_uppercase')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.black,
            ),
            onPressed: () async {
              Navigator.pop(dialogContext);
              await _adBlocker.addCustomRule(rule);
              if (mounted) {
                ThemedSnackbar.show(
                  context,
                  message: L10n.of(context, 'element_blocked',
                      args: {'selector': selector}),
                  color: accent,
                  icon: Icons.block,
                  isDarkMode: settings.isDarkMode,
                );
                if (!tab.isHome) {
                  await _safeReloadTab(tab);
                }
              }
            },
            child: Text(L10n.of(context, 'block_btn')),
          ),
        ],
      ),
    );
  }

  void _openInNewTab(String url,
      {bool isIncognito = false, bool switchToTab = false}) {
    if (!mounted || url.isEmpty) return;
    if (url.startsWith('magnet:') || isMagnetUrl(url)) {
      _log.info('[Browser] Intercepted magnet URL in _openInNewTab: $url');
      AddDownloadDialog.show(context, prefilledUrl: url);
      return;
    }
    _redirectGuard.markUserInitiated(url);
    setState(() {
      final newTab = _createNewTab(
        initialUrl: url,
        isIncognito: isIncognito,
      );
      _tabs.add(newTab);
      if (switchToTab) {
        _currentTabIndex = _tabs.length - 1;
        _urlController.text = url;
        _showBarsNotifier.value = true;
      }
    });
    _saveTabs();
  }

  void _suggestDownload(String url, PageClassification classification) {
    if (!mounted) return;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final isDark = settings.isDarkMode;

    ThemedSnackbar.show(
      context,
      message: classification.detectedFileName != null
          ? 'Download available: ${classification.detectedFileName}'
          : 'Downloadable content detected',
      color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
      icon: Icons.download_rounded,
      isDarkMode: isDark,
      actionLabel: 'DOWNLOAD',
      onAction: () => _startDirectDownload(url,
          suggestedName: classification.detectedFileName),
    );
  }

  void _showAdWarning(BuildContext context, String url) {
    if (!mounted) return;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    ThemedSnackbar.show(
      context,
      message: 'This page might be an advertisement',
      color: AppTheme.neonAmber,
      icon: Icons.warning_amber_rounded,
      isDarkMode: settings.isDarkMode,
    );
  }

  void _openInBackgroundTab(String url, {bool isIncognito = false}) {
    if (!mounted || url.isEmpty) return;
    _openInNewTab(url, isIncognito: isIncognito, switchToTab: false);
    final isDark = context.read<SettingsProvider>().isDarkMode;
    ThemedSnackbar.show(
      context,
      message: L10n.of(context, 'redirect_bg_opened'),
      color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
      icon: Icons.tab_rounded,
      isDarkMode: isDark,
    );
  }

  Future<void> _handleRedirectIntercept(
      BrowserTab parentTab, String targetUrl) async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    triggerHaptic(settings);

    final action = await RedirectSheet.show(
      context,
      targetUrl: targetUrl,
      currentTabUrl: parentTab.url,
    );

    if (!mounted || action == null) return;

    switch (action) {
      case RedirectAction.openOnceInNewTab:
        _openInNewTab(targetUrl,
            isIncognito: parentTab.isIncognito, switchToTab: true);
        break;
      case RedirectAction.openInBackgroundTab:
        _openInNewTab(targetUrl,
            isIncognito: parentTab.isIncognito, switchToTab: false);
        if (!mounted) return;
        ThemedSnackbar.show(
          context,
          message: L10n.of(context, 'redirect_bg_opened'),
          color:
              settings.isDarkMode ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
          icon: Icons.tab_unselected_rounded,
          isDarkMode: settings.isDarkMode,
        );
        break;
      case RedirectAction.alwaysOpenInNewTab:
        await _redirectGuard.addAlwaysNewTabDomain(targetUrl);
        _openInNewTab(targetUrl,
            isIncognito: parentTab.isIncognito, switchToTab: true);
        break;
      case RedirectAction.allowInSameTab:
        _redirectGuard.markUserInitiated(targetUrl);
        parentTab.controller
            ?.loadUrl(urlRequest: URLRequest(url: WebUri(targetUrl)));
        break;
    }
  }

  void _onDashboardScroll() {
    if (!_dashboardScrollController.hasClients) return;
    final y = _dashboardScrollController.offset;
    _handleScroll(y);
  }

  void _handleScroll(double y) {
    if (!mounted) return;
    final downloadProvider = Provider.of<DownloadProvider>(
      context,
      listen: false,
    );
    if (downloadProvider.activeTabIndex != 1) return;

    // The URL bar is intentionally persistent; scrolling may still update
    // the surrounding app navigation visibility, but never hides this bar.
    _showBarsNotifier.value = true;
    if (y <= 0 || y < _lastScrollY) {
      downloadProvider.setNavbarVisible(true);
    } else if (y - _lastScrollY > 40) {
      downloadProvider.setNavbarVisible(false);
    }
    _lastScrollY = y;
  }

  void _delayed(Duration duration, VoidCallback callback) =>
      _tabManager.delayed(duration, callback);

  @override
  void dispose() {
    _mediaScanDebounce?.cancel();
    _showBarsNotifier.dispose();
    _adBlocker.removeListener(_updateAdBlockSettings);
    _inactivityWatchdog.dispose();
    WidgetsBinding.instance.removeObserver(this);

    for (final timer in _loadingTimeoutTimers.values) {
      timer.cancel();
    }
    _loadingTimeoutTimers.clear();

    if (!_quitPersisted && _tabs.isNotEmpty) {
      try {
        _tabManager.saveTabs();
      } catch (e, st) {
        Logger('browser_screen')
            .warning('[browser_screen] operation failed', e, st);
      }
    }

    for (final tab in _tabs) {
      _cleanupTabState(tab.id);
    }

    for (final tab in _tabs) {
      if (tab.isIncognito) {
        try {
          unawaited(InAppWebViewController.clearAllCache());
          tab.controller?.evaluateJavascript(
              source:
                  'window.localStorage.clear(); window.sessionStorage.clear();');
        } catch (_) {/* ignore: clearing cache/storage on close */}
      }
      try {
        tab.dispose();
      } catch (_) {/* ignore: disposing tab may already be disposed */}
    }

    _tabs.clear();
    _detectedDownloadUrls.clear();
    _detectedMediaSources.clear();
    _detectedPlaylistUrls.clear();
    _ytDetectionFailed.clear();

    for (final timer in _mediaScanTimers.values) {
      timer.cancel();
    }
    _mediaScanTimers.clear();

    for (final timer in _pendingTimers) {
      timer.cancel();
    }
    _pendingTimers.clear();

    _navDebounce?.cancel();
    _downloadProvider?.removeListener(_onDownloadProviderChanged);

    _urlController.dispose();
    _focusNode.dispose();
    _dashboardScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadSnifferPref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getBool(_snifferPrefKey) ?? true;
      if (!mounted) return;
      setState(() {
        _isSnifferEnabled = value;
      });
    } catch (e) {
      _log.warning('[DMX Browser] Failed to load sniffer preference: $e');
    }
  }

  Future<void> _setSnifferEnabled(bool value) async {
    setState(() {
      _isSnifferEnabled = value;
      if (!value) {
        _detectedDownloadUrls.clear();
        _detectedPlaylistUrls.clear();
        _detectedMediaSources.clear();
        for (final timer in _mediaScanTimers.values) {
          timer.cancel();
        }
        _mediaScanTimers.clear();
      }
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_snifferPrefKey, value);
    } catch (e) {
      _log.warning('[DMX Browser] Failed to save sniffer preference: $e');
    }
  }

  Future<void> _loadCustomJsCss() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _customJs = prefs.getString('browser_custom_js') ?? '';
        _customCss = prefs.getString('browser_custom_css') ?? '';
      });
    } catch (e) {
      _log.warning('[DMX Browser] Failed to load custom JS/CSS: $e');
    }
  }

  Future<void> _updateNavState() async {
    if (!mounted || _tabs.isEmpty) return;
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;

    final activeTab = _tabs[_currentTabIndex];
    if (activeTab.isHome && _homeReturnUrl != null) return;

    try {
      final canBack = await activeTab.controller?.canGoBack() ?? false;
      final canForward = await activeTab.controller?.canGoForward() ?? false;
      final webUri = await activeTab.controller?.getUrl();
      final currentUrl = webUri?.toString();

      if (mounted) {
        setState(() {
          if (currentUrl != null && currentUrl.isNotEmpty) {
            final clean = _cleanUrl(currentUrl);
            final isBlank = clean == 'about:blank' || clean.isEmpty;

            if (!activeTab.isHome || isBlank) {
              activeTab.url = clean;
              activeTab.isHome = isBlank;
              if (_tabs[_currentTabIndex].id == activeTab.id) {
                _urlController.text = isBlank ? '' : clean;
              }
            }

            if (activeTab.isHome) {
              activeTab.canGoBack = false;
              activeTab.canGoForward =
                  _homeReturnUrl != null && _homeReturnUrl!.isNotEmpty;
            } else {
              activeTab.canGoBack = canBack;
              activeTab.canGoForward = canForward;
            }
          } else {
            if (!activeTab.isHome) {
              activeTab.canGoBack = canBack;
              activeTab.canGoForward = canForward;
            }
          }
        });
      }
    } catch (_) {
      /* ignore: getUrl/canGoBack may throw if controller disposed */
    }
  }

  Future<void> _goBack() async {
    if (_tabs.isEmpty ||
        _currentTabIndex < 0 ||
        _currentTabIndex >= _tabs.length) {
      return;
    }
    final activeTab = _tabs[_currentTabIndex];
    if (activeTab.canGoBack) {
      _homeReturnUrl = null;
      unawaited(activeTab.controller?.goBack() ?? Future.value());
      _updateNavState();
    } else if (!activeTab.isHome && activeTab.url.isNotEmpty) {
      if (mounted) {
        _homeReturnUrl = activeTab.url;
        setState(() {
          activeTab.isHome = true;
          activeTab.url = '';
          activeTab.canGoBack = false;
          activeTab.canGoForward = true;
          activeTab.controller = null;
          _urlController.clear();
        });
      }
    }
  }

  bool _switchToPreviousTab() {
    _tabIdHistory.removeWhere((id) => !_tabs.any((t) => t.id == id));
    if (_tabIdHistory.isNotEmpty) {
      final prevId = _tabIdHistory.removeLast();
      final idx = _tabs.indexWhere((t) => t.id == prevId);
      if (idx != -1) {
        setState(() {
          _currentTabIndex = idx;
        });
        return true;
      }
    }
    return false;
  }

  void _switchToTabRelative(int offset) {
    if (_tabs.length <= 1) return;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    triggerHaptic(settings);
    setState(() {
      final newIndex = (_currentTabIndex + offset) % _tabs.length;
      _currentTabIndex = newIndex;
      _urlController.text = _tabs[newIndex].url;
    });
  }

  Future<void> _goForward() async {
    if (_tabs.isEmpty ||
        _currentTabIndex < 0 ||
        _currentTabIndex >= _tabs.length) {
      return;
    }
    final activeTab = _tabs[_currentTabIndex];
    if (!activeTab.canGoForward) return;

    if (activeTab.isHome &&
        _homeReturnUrl != null &&
        _homeReturnUrl!.isNotEmpty) {
      final returnUrl = _homeReturnUrl!;
      _homeReturnUrl = null;
      if (mounted) {
        setState(() {
          activeTab.isHome = false;
        });
      }
      _navigateToUrl(returnUrl);
      return;
    }

    unawaited(activeTab.controller?.goForward() ?? Future.value());
    _updateNavState();
  }

  void _navigateToUrl(String input) {
    var url = input.trim();
    if (url.isEmpty) return;

    _redirectGuard.markUserInitiated(url);
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final engine = settings.searchEngine;

    String searchPrefix = 'https://google.com/search?q=';
    if (engine == 'DuckDuckGo') {
      searchPrefix = 'https://duckduckgo.com/?q=';
    } else if (engine == 'Bing') {
      searchPrefix = 'https://www.bing.com/search?q=';
    } else if (engine == 'Yahoo') {
      searchPrefix = 'https://search.yahoo.com/search?p=';
    }

    final lowerUrl = url.toLowerCase();
    if (lowerUrl.startsWith('http://') ||
        lowerUrl.startsWith('https://') ||
        lowerUrl.startsWith('file://') ||
        lowerUrl.startsWith('about:')) {
    } else if (url.contains(' ') || !url.contains('.')) {
      url = '$searchPrefix${Uri.encodeComponent(input)}';
    } else {
      url = 'https://$url';
    }

    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
    final activeTab = _tabs[_currentTabIndex];
    final parsed = Uri.tryParse(url);
    final targetUrl = parsed != null ? parsed.toString() : url;

    if (targetUrl.startsWith('magnet:') || isMagnetUrl(targetUrl)) {
      _log.info(
          '[Browser] Intercepted magnet URL from URL bar input: $targetUrl');
      _urlController.text = activeTab.isHome ? '' : activeTab.url;
      AddDownloadDialog.show(context, prefilledUrl: targetUrl);
      return;
    }

    setState(() {
      activeTab.isHome = false;
      activeTab.url = targetUrl;
      _urlController.text = targetUrl;
    });

    if (activeTab.controller != null) {
      activeTab.controller?.loadUrl(
        urlRequest: URLRequest(url: WebUri(targetUrl)),
      );
    }
    _delayed(const Duration(milliseconds: 300), _updateNavState);
  }

  String _cleanUrl(String url) {
    if (url == 'about:blank') return '';
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return url;
    var clean = uri.toString();
    if (clean.endsWith('/') && clean.length > uri.scheme.length + 3) {
      clean = clean.substring(0, clean.length - 1);
    }
    return clean;
  }

  PopupMenuItem<String> _menuItem(
    IconData icon,
    String label,
    String value,
    Color textClr,
  ) {
    return PopupMenuItem<String>(
      value: value,
      height: 44,
      child: Row(
        children: [
          Icon(icon, size: 16, color: textClr),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: textClr,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleMenuAction(String value) async {
    final settings = context.read<SettingsProvider>();
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
    final activeTab = _tabs[_currentTabIndex];

    switch (value) {
      case 'show_bookmarks':
        _openBookmarks();
        break;
      case 'show_history':
        _openHistory();
        break;
      case 'reload':
        if (!activeTab.isHome) {
          await _safeReloadTab(activeTab);
        }
        break;
      case 'bookmark':
        final currentUrl = _urlController.text.trim();
        if (currentUrl.isEmpty) return;
        try {
          final db = context.read<DatabaseService>();
          await db.saveBookmark(
            Bookmark(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              title: activeTab.title.isNotEmpty ? activeTab.title : currentUrl,
              url: currentUrl,
              createdAt: DateTime.now(),
            ),
          );
          if (mounted) {
            ThemedSnackbar.show(
              context,
              message: L10n.of(context, 'browser_bookmark_saved'),
              color: settings.isDarkMode
                  ? AppTheme.neonBlue
                  : AppTheme.lightNeonBlue,
              icon: Icons.bookmark_added,
              isDarkMode: settings.isDarkMode,
            );
          }
        } catch (e) {
          _log.warning('[DMX Browser] Failed to save bookmark: $e');
        }
        break;
      case 'copy':
        final url = _urlController.text.trim();
        if (url.isNotEmpty) {
          await Clipboard.setData(ClipboardData(text: url));
          if (mounted) {
            ThemedSnackbar.show(
              context,
              message: L10n.of(context, 'browser_url_copied'),
              color: settings.isDarkMode
                  ? AppTheme.neonBlue
                  : AppTheme.lightNeonBlue,
              icon: Icons.copy,
              isDarkMode: settings.isDarkMode,
            );
          }
        }
        break;
      case 'share':
        final url = _urlController.text.trim();
        if (url.isNotEmpty) {
          await SharePlus.instance.share(
            ShareParams(text: url, subject: activeTab.title),
          );
        }
        break;
      case 'desktop':
        await settings.setDesktopMode(!settings.desktopMode);
        if (mounted) {
          ThemedSnackbar.show(
            context,
            message: settings.desktopMode
                ? L10n.of(context, 'browser_desktop_mode_reload')
                : L10n.of(context, 'browser_mobile_mode_reload'),
            color: settings.isDarkMode
                ? AppTheme.neonBlue
                : AppTheme.lightNeonBlue,
            icon: settings.desktopMode
                ? Icons.desktop_windows
                : Icons.phone_android,
            isDarkMode: settings.isDarkMode,
          );
          await Future.wait(
            _tabs.map((t) async {
              await _applyUserAgent(t, settings);
              try {
                await t.controller?.setSettings(
                  settings: InAppWebViewSettings(
                    supportZoom: settings.desktopMode || settings.pinchToZoom,
                    incognito: t.isIncognito,
                  ),
                );
              } catch (e, st) {
                Logger('browser_screen')
                    .warning('[browser_screen] operation failed', e, st);
              }
            }),
          );
          for (final t in _tabs) {
            if (!t.isHome) {
              await _safeReloadTab(t);
            }
          }
        }
        break;
      case 'sniffer':
        await _setSnifferEnabled(!_isSnifferEnabled);
        if (mounted) {
          ThemedSnackbar.show(
            context,
            message: _isSnifferEnabled
                ? L10n.of(context, 'browser_media_detector_on')
                : L10n.of(context, 'browser_media_detector_off'),
            color: settings.isDarkMode
                ? AppTheme.neonGreen
                : AppTheme.lightNeonGreen,
            icon: _isSnifferEnabled ? Icons.check_circle_outline : Icons.block,
            isDarkMode: settings.isDarkMode,
          );
        }
        break;
      case 'adblocker':
        await _adBlocker.toggle();
        if (mounted) {
          ThemedSnackbar.show(
            context,
            message: _adBlocker.isEnabled
                ? L10n.of(context, 'browser_adblocker_on')
                : L10n.of(context, 'browser_adblocker_off'),
            color: settings.isDarkMode
                ? AppTheme.neonGreen
                : AppTheme.lightNeonGreen,
            icon:
                _adBlocker.isEnabled ? Icons.check_circle_outline : Icons.block,
            isDarkMode: settings.isDarkMode,
          );
          if (!activeTab.isHome) {
            await _safeReloadTab(activeTab);
          }
        }
        break;
      case 'incognito':
        await settings.setIncognitoEnabled(!settings.incognitoEnabled);
        if (mounted) {
          ThemedSnackbar.show(
            context,
            message: settings.incognitoEnabled
                ? L10n.of(context, 'browser_incognito_on')
                : L10n.of(context, 'browser_incognito_off'),
            color: settings.isDarkMode
                ? AppTheme.neonBlue
                : AppTheme.lightNeonBlue,
            icon: Icons.security,
            isDarkMode: settings.isDarkMode,
          );
        }
        break;
      case 'injector':
        _showJsCssInjectorDialog();
        break;
      case 'reader':
        await _activateReaderMode(activeTab);
        break;
      case 'picker':
        await _startElementPicker(activeTab);
        break;
      case 'offline':
        _savePageOffline(activeTab);
        break;
      case 'quit':
        await _quitBrowser();
        break;
    }
  }

  Future<void> _activateReaderMode(BrowserTab activeTab) async {
    final settings = context.read<SettingsProvider>();
    if (activeTab.isHome || activeTab.url.isEmpty) return;
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    final ok = activeTab.controller == null
        ? false
        : await ReaderModeService.activateReaderMode(
            activeTab.controller!,
            (htmlUrl) {
              if (mounted) {
                activeTab.controller
                    ?.loadUrl(urlRequest: URLRequest(url: WebUri(htmlUrl)))
                    .catchError((e, st) {
                  Logger('browser_screen').warning(
                      '[browser_screen] reader mode load failed', e, st);
                });
              }
            },
          );

    if (mounted) {
      ThemedSnackbar.show(
        context,
        message: ok ? 'Reader mode activated' : 'No article content found',
        color: accent,
        icon: ok ? Icons.menu_book : Icons.error_outline,
        isDarkMode: isDark,
      );
    }
  }

  Future<void> _startElementPicker(BrowserTab activeTab) async {
    final settings = context.read<SettingsProvider>();
    if (activeTab.isHome) return;
    try {
      await activeTab.controller
          ?.evaluateJavascript(source: ElementPickerService.pickerScript);
      // E6: Element Picker Mode Indicator
      setState(() {
        _isPickerModeActive = true;
      });
    } catch (e) {
      _log.warning('[DMX Browser] Failed to start element picker: $e');
      return;
    }

    if (mounted) {
      ThemedSnackbar.show(
        context,
        message: 'Tap an element on the page to block it',
        color: settings.isDarkMode ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
        icon: Icons.touch_app,
        isDarkMode: settings.isDarkMode,
      );
    }
  }

  void _showLongPressSheet(
    BuildContext context,
    String url,
    String type, {
    String text = '',
    String? tabId,
  }) {
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
    final activeTab = _tabs[_currentTabIndex];
    final tab = tabId == null
        ? activeTab
        : _tabs.firstWhere(
            (t) => t.id == tabId,
            orElse: () => activeTab,
          );

    final hasMultipleQualities =
        _detectedMediaSources[tab.id]?.isNotEmpty ?? false;

    final discovered = (_detectedMediaSources[tab.id] ?? [])
        .map(MediaSourceItem.fromMap)
        .toList();
    final sources = filterSourcesForTarget(discovered, url, type);

    final cleanUrl = url.trim();
    final isWebUrl = cleanUrl.startsWith('http://') ||
        cleanUrl.startsWith('https://') ||
        cleanUrl.startsWith('www.');

    BrowserDownloadSheet.show(
      context,
      url,
      type: type,
      text: text,
      downloadPageUrl: tab.isHome ? null : tab.url,
      onQuality: hasMultipleQualities
          ? () => _showQualityPicker(tab.id, fallbackUrl: url)
          : null,
      onOpenInNewTab: isWebUrl
          ? () {
              _redirectGuard.markUserInitiated(cleanUrl);
              setState(() {
                final newTab = _createNewTab(
                  initialUrl: cleanUrl,
                  isIncognito: tab.isIncognito,
                );
                _tabs.add(newTab);
                _currentTabIndex = _tabs.length - 1;
                _urlController.text = cleanUrl;
                _showBarsNotifier.value = true;
              });
              _saveTabs();
            }
          : null,
      onOpenInIncognito: isWebUrl
          ? () {
              _redirectGuard.markUserInitiated(cleanUrl);
              setState(() {
                final newTab = _createNewTab(
                  initialUrl: cleanUrl,
                  isIncognito: true,
                );
                _tabs.add(newTab);
                _currentTabIndex = _tabs.length - 1;
                _urlController.text = cleanUrl;
                _showBarsNotifier.value = true;
              });
              _saveTabs();
            }
          : null,
      sources: sources,
    );
  }

  void _showInterceptionSheet(BuildContext context, String downloadUrl) {
    final now = DateTime.now();
    if (_lastInterceptedUrl == downloadUrl &&
        _lastInterceptedTime != null &&
        now.difference(_lastInterceptedTime!) < const Duration(seconds: 2)) {
      _log.info(
          '[Browser] Skipping duplicate interception sheet for: $downloadUrl');
      return;
    }
    _lastInterceptedUrl = downloadUrl;
    _lastInterceptedTime = now;

    final settings = Provider.of<SettingsProvider>(context, listen: false);
    triggerHaptic(settings);
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final isMagnetSignal =
        downloadUrl.startsWith('magnet:') || isMagnetUrl(downloadUrl);
    if (isMagnetSignal) {
      AddDownloadDialog.show(context, prefilledUrl: downloadUrl);
      return;
    }
    final detected = BrowserDetector.detect(downloadUrl);
    final kindLabel =
        detected == null ? 'FILE' : detected.kind.name.toUpperCase();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return Directionality(
          textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            child: DmxBackdropFilter(
              sigmaX: 15,
              sigmaY: 15,
              child: Container(
                decoration: BoxDecoration(
                  color: (isDark ? AppTheme.surface : AppTheme.lightSurface)
                      .withValues(alpha: 0.88),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(28),
                  ),
                  border: Border(
                    top: BorderSide(
                      color: accent.withValues(alpha: 0.4),
                      width: 1.2,
                    ),
                  ),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: Container(
                            width: 40,
                            height: 4,
                            margin: const EdgeInsets.only(bottom: 20),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            _PulsingIconBadge(
                              icon: Icons.radar_rounded,
                              color: accent,
                              isDark: isDark,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    L10n.of(
                                      context,
                                      'browser_intercepted_signal',
                                    ),
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                          color: accent,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 0.3,
                                          fontSize: 14,
                                        ),
                                  ),
                                  const SizedBox(height: 3),
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 7,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: accent.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(
                                            5,
                                          ),
                                        ),
                                        child: Text(
                                          kindLabel,
                                          style: TextStyle(
                                            color: accent,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.3,
                                            fontFamily: 'Space Grotesk',
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        isRtl
                                            ? 'إشارة قابلة للتنزيل'
                                            : 'Downloadable stream',
                                        style: TextStyle(
                                          color: isDark
                                              ? AppTheme.textMuted
                                              : AppTheme.lightTextMuted,
                                          fontSize: 12,
                                          letterSpacing: 0.3,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        _CornerBracketBox(
                          color: accent,
                          isDark: isDark,
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.link_rounded,
                                  size: 14,
                                  color: accent.withValues(alpha: 0.7),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    downloadUrl,
                                    style: TextStyle(
                                      color: isDark
                                          ? AppTheme.textPrimary
                                          : AppTheme.lightTextPrimary,
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                      height: 1.5,
                                    ),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(
                                    color: isDark
                                        ? AppTheme.glassBorder
                                        : AppTheme.lightGlassBorder,
                                  ),
                                  foregroundColor: isDark
                                      ? AppTheme.textSecondary
                                      : AppTheme.lightTextSecondary,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                ),
                                onPressed: () {
                                  Navigator.pop(context);
                                  if (isMagnetSignal) {
                                    AddDownloadDialog.show(context,
                                        prefilledUrl: downloadUrl);
                                    return;
                                  }
                                  if (_currentTabIndex >= 0 &&
                                      _currentTabIndex < _tabs.length) {
                                    final activeTab = _tabs[_currentTabIndex];
                                    _interceptor.addBypass(downloadUrl);
                                    activeTab.controller?.loadUrl(
                                      urlRequest:
                                          URLRequest(url: WebUri(downloadUrl)),
                                    );
                                  }
                                },
                                child: Text(
                                  isMagnetSignal
                                      ? (isRtl
                                          ? 'اختيار الملفات'
                                          : 'CHOOSE FILES')
                                      : L10n.of(
                                          context, 'browser_continue_browsing'),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: NeonGlowButton(
                                isFilled: true,
                                color: accent,
                                onPressed: () {
                                  Navigator.pop(context);
                                  _startDirectDownload(downloadUrl);
                                },
                                text: L10n.of(context, 'browser_download_btn'),
                                icon: Icons.download_rounded,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _scanPageMedia(BrowserTab tab) =>
      _sniffer.scanPageMedia(tab, tabs: _tabs);

  void _showQualityPicker(String tabId, {String? fallbackUrl}) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final detectedSources = _detectedMediaSources[tabId] ?? [];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: DmxBackdropFilter(
            sigmaX: 15,
            sigmaY: 15,
            child: Container(
              decoration: BoxDecoration(
                color: (isDark ? AppTheme.surface : AppTheme.lightSurface)
                    .withValues(alpha: 0.95),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                border: Border(
                  top: BorderSide(
                    color: isDark
                        ? AppTheme.glassBorder
                        : AppTheme.lightGlassBorder,
                    width: 0.8,
                  ),
                ),
              ),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 20),
                          decoration: BoxDecoration(
                            color: (isDark
                                    ? AppTheme.textMuted
                                    : AppTheme.lightTextMuted)
                                .withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          Icon(Icons.tune_rounded, color: accent, size: 20),
                          const SizedBox(width: 10),
                          Text(
                            L10n.of(context, 'browser_select_video_quality'),
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  color: accent,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.0,
                                  fontSize: 14,
                                ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (detectedSources.isNotEmpty) ...[
                        ...detectedSources.map((src) {
                          final label = src['label'] as String? ??
                              L10n.of(context, 'browser_alternative_stream');
                          final srcUrl = src['src'] as String? ?? '';
                          return _buildQualityTile(
                            context,
                            label,
                            srcUrl,
                            isDark,
                            settings,
                          );
                        }),
                      ] else ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Text(
                            L10n.isRtl(context)
                                ? L10n.of(
                                    context,
                                    'browser_no_alternative_streams',
                                  )
                                : L10n.of(
                                    context,
                                    'browser_no_alternative_streams',
                                  ),
                            style: TextStyle(
                              color: accent,
                              fontSize: 13,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildQualityTile(
    BuildContext context,
    String label,
    String streamUrl,
    bool isDark,
    SettingsProvider settings,
  ) {
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            Navigator.pop(context);
            _startDirectDownload(streamUrl, type: 'video');
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: (isDark ? AppTheme.glassBg : AppTheme.lightGlassBg)
                  .withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color:
                    isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                width: 0.7,
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.video_settings, color: accent, size: 16),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.textPrimary
                          : AppTheme.lightTextPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Icon(Icons.download_rounded, color: accent, size: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showDetectedMediaSheet(BuildContext context, String tabId) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final detectedSources = _detectedMediaSources[tabId] ?? [];
    final downloadPageUrl =
        _tabs.where((t) => t.id == tabId).map((t) => t.url).firstOrNull;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: DmxBackdropFilter(
            sigmaX: 15,
            sigmaY: 15,
            child: Container(
              decoration: BoxDecoration(
                color: (isDark ? AppTheme.surface : AppTheme.lightSurface)
                    .withValues(alpha: 0.95),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                border: Border(
                  top: BorderSide(
                    color: accent.withValues(alpha: 0.4),
                    width: 1.2,
                  ),
                ),
              ),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 20),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          _PulsingIconBadge(
                            icon: Icons.sensors_rounded,
                            color: accent,
                            isDark: isDark,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  L10n.of(context, 'browser_detected_media'),
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(
                                        color: accent,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 0.5,
                                        fontSize: 14,
                                      ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '${detectedSources.length} ${L10n.isRtl(context) ? "إشارة" : "streams detected"}',
                                  style: TextStyle(
                                    color: isDark
                                        ? AppTheme.textMuted
                                        : AppTheme.lightTextMuted,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(context).size.height * 0.4,
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: detectedSources.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, i) {
                            final src = detectedSources[i];
                            final label = src['label'] as String? ??
                                '${L10n.of(context, 'browser_media_stream')} ${i + 1}';
                            final srcUrl = src['src'] as String? ?? '';
                            final isAudio = label.toLowerCase().contains(
                                  'audio',
                                );
                            final tileClr = isAudio
                                ? (isDark
                                    ? AppTheme.neonGreen
                                    : AppTheme.lightNeonGreen)
                                : accent;

                            return Material(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(14),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () {
                                  Navigator.pop(context);
                                  final title = src['title'] as String?;
                                  final ext = src['ext'] as String?;
                                  String? filename;
                                  if (title != null && title.isNotEmpty) {
                                    filename =
                                        ext != null ? "$title.$ext" : title;
                                  }
                                  BrowserDownloadSheet.show(
                                    context,
                                    srcUrl,
                                    suggestedName: filename,
                                    type: isAudio ? 'audio' : 'video',
                                    onQuality: () => _showQualityPicker(
                                      tabId,
                                      fallbackUrl: srcUrl,
                                    ),
                                    downloadPageUrl: downloadPageUrl,
                                  );
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: tileClr.withValues(alpha: 0.06),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: tileClr.withValues(alpha: 0.2),
                                      width: 0.7,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        isAudio
                                            ? Icons.audiotrack_rounded
                                            : Icons.play_circle_fill,
                                        color: tileClr,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              label,
                                              style: TextStyle(
                                                color: isDark
                                                    ? AppTheme.textPrimary
                                                    : AppTheme.lightTextPrimary,
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              srcUrl,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: isDark
                                                    ? AppTheme.textMuted
                                                    : AppTheme.lightTextMuted,
                                                fontSize: 12,
                                                fontFamily: 'monospace',
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Icon(
                                        Icons.download_rounded,
                                        size: 16,
                                        color: tileClr,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showJsCssInjectorDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return _JsCssInjectorDialog(
          initialJs: _customJs,
          initialCss: _customCss,
          onSave: (js, css) async {
            setState(() {
              _customJs = js;
              _customCss = css;
            });
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('browser_custom_js', js);
            await prefs.setString('browser_custom_css', css);
            if (_currentTabIndex >= 0 && _currentTabIndex < _tabs.length) {
              _injectCustomJsCss(_tabs[_currentTabIndex]);
            }
          },
        );
      },
    );
  }

  Future<void> _injectCustomJsCss(BrowserTab tab) async {
    if (!mounted) return;
    await _scriptInjector.injectCustomJsCss(
      tab,
      customJs: _customJs,
      customCss: _customCss,
    );
  }

  Future<void> _savePageOffline(BrowserTab tab) async {
    if (tab.isHome) return;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    triggerHaptic(settings);
    try {
      final result = await tab.controller?.evaluateJavascript(
        source: "document.documentElement.outerHTML",
      );
      String rawHtml = '';
      if (result is String) {
        rawHtml = result;
        if (rawHtml.startsWith('"') && rawHtml.endsWith('"')) {
          try {
            rawHtml = jsonDecode(rawHtml) as String;
          } catch (e, st) {
            Logger('browser_screen')
                .warning('[browser_screen] operation failed', e, st);
            if (rawHtml.length > 2) {
              rawHtml = rawHtml.substring(1, rawHtml.length - 1);
            }
          }
        }
      }

      if (rawHtml.isEmpty) {
        if (mounted) {
          ThemedSnackbar.show(
            context,
            message: L10n.of(context, 'browser_save_page_failed'),
            color:
                settings.isDarkMode ? AppTheme.neonRed : AppTheme.lightNeonRed,
            icon: Icons.error_outline,
            isDarkMode: settings.isDarkMode,
          );
        }
        return;
      }

      final offlineTitle =
          mounted ? L10n.of(context, 'browser_offline_page') : 'Offline Page';
      String title = tab.title.isNotEmpty ? tab.title : offlineTitle;
      title = title.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();

      final path = settings.customDownloadPath?.isNotEmpty == true
          ? settings.customDownloadPath!
          : await PermissionService().defaultDownloadDirectory();
      final filePath = p.join(path, "$title.html");
      final file = File(filePath);
      await file.writeAsString(rawHtml);

      final id = DateTime.now().millisecondsSinceEpoch.toString();
      final size = utf8.encode(rawHtml).length;

      final task = DownloadTask(
        id: id,
        fileName: "$title.html",
        url: tab.url,
        fileSize: size,
        downloadedBytes: size,
        category: "Document",
        status: DownloadStatus.completed,
        savePath: path,
        localFilePath: filePath,
        tempFilePath: "",
        threadCount: 1,
        chunks: [1.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        completedAt: DateTime.now(),
      );

      if (!mounted) return;
      final db = context.read<DatabaseService>();
      await db.saveTask(task);

      if (mounted) {
        await context.read<DownloadProvider>().load(
              pauseOrphanDownloads: false,
            );
        if (mounted) {
          ThemedSnackbar.show(
            context,
            message: '${L10n.of(context, 'browser_page_saved')} - $title.html',
            color: settings.isDarkMode
                ? AppTheme.neonGreen
                : AppTheme.lightNeonGreen,
            icon: Icons.check_circle_outline,
            isDarkMode: settings.isDarkMode,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ThemedSnackbar.show(
          context,
          message: '${L10n.of(context, 'browser_page_save_error')}: $e',
          color: settings.isDarkMode ? AppTheme.neonRed : AppTheme.lightNeonRed,
          icon: Icons.error_outline,
          isDarkMode: settings.isDarkMode,
        );
      }
    }
  }

  void _showTabLimitDialog(
    BuildContext switcherContext,
    StateSetter setModalState, {
    required bool isIncognito,
  }) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return AlertDialog(
          backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
          title: Text(L10n.of(context, 'tab_limit_reached')),
          content: Text(
            L10n.of(context, 'browser_max_tabs'),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                int closeIdx = -1;
                for (int i = 0; i < _tabs.length; i++) {
                  if (i != _currentTabIndex) {
                    closeIdx = i;
                    break;
                  }
                }
                if (closeIdx != -1) {
                  setModalState(() {
                    setState(() {
                      _cleanupTabState(_tabs[closeIdx].id);
                      _tabs[closeIdx].dispose();
                      _tabs.removeAt(closeIdx);
                      if (_currentTabIndex >= _tabs.length) {
                        _currentTabIndex = _tabs.length - 1;
                      }
                      final tab = _createNewTab(isIncognito: isIncognito);
                      _tabs.add(tab);
                      _currentTabIndex = _tabs.length - 1;
                      _urlController.text = '';
                      _showBarsNotifier.value = true;
                    });
                    _saveTabs();
                  });
                  Navigator.pop(switcherContext);
                }
              },
              child: Text(L10n.of(context, 'close_oldest_inactive')),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                setModalState(() {
                  setState(() {
                    final active = _tabs[_currentTabIndex];
                    for (final tab in _tabs) {
                      if (tab.id != active.id) {
                        _cleanupTabState(tab.id);
                      }
                    }
                    _tabs.clear();
                    _tabs.add(active);
                    _currentTabIndex = 0;

                    final newTab = _createNewTab(isIncognito: isIncognito);
                    _tabs.add(newTab);
                    _currentTabIndex = 1;
                    _urlController.text = '';
                    _showBarsNotifier.value = true;
                  });
                  _saveTabs();
                });
                Navigator.pop(switcherContext);
              },
              child: Text(L10n.of(context, 'close_all_other_tabs')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(L10n.of(context, 'cancel_btn')),
            ),
          ],
        );
      },
    );
  }

  void _showTabSwitcher(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final violet = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            // E20: Tab Switcher Open/Close Animation
            return AnimatedSlide(
              offset: Offset.zero,
              duration: AppTheme.motionBase,
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: 1.0,
                duration: AppTheme.motionBase,
                child: DraggableScrollableSheet(
                  expand: false,
                  initialChildSize: 0.85,
                  maxChildSize: 0.95,
                  minChildSize: 0.5,
                  builder: (context, controller) {
                    return ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(28),
                      ),
                      child: DmxBackdropFilter(
                        sigmaX: 15,
                        sigmaY: 15,
                        child: Container(
                          decoration: BoxDecoration(
                            color: (isDark
                                    ? AppTheme.surface
                                    : AppTheme.lightSurface)
                                .withValues(alpha: 0.95),
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(28),
                            ),
                            border: Border(
                              top: BorderSide(
                                color: isDark
                                    ? AppTheme.glassBorder
                                    : AppTheme.lightGlassBorder,
                                width: 0.8,
                              ),
                            ),
                          ),
                          child: SafeArea(
                            child: Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24.0,
                                    vertical: 16.0,
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: accent.withValues(alpha: 0.1),
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        child: Icon(
                                          Icons.tab_rounded,
                                          color: accent,
                                          size: 18,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Text(
                                        L10n.of(context, 'active_tabs'),
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(
                                              color: accent,
                                              fontWeight: FontWeight.bold,
                                              letterSpacing: 0.3,
                                              fontSize: 14,
                                            ),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: accent.withValues(alpha: 0.12),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          '${_tabs.length}',
                                          style: TextStyle(
                                            color: accent,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w800,
                                            fontFamily: 'Space Grotesk',
                                          ),
                                        ),
                                      ),
                                      const Spacer(),
                                      _TabSwitcherAction(
                                        icon: Icons.visibility_off_rounded,
                                        color: violet,
                                        tooltip: L10n.of(
                                          context,
                                          'browser_new_incognito_tab',
                                        ),
                                        onPressed: () {
                                          triggerHaptic(settings);
                                          if (_tabs.length >= 10) {
                                            _showTabLimitDialog(
                                              context,
                                              setModalState,
                                              isIncognito: true,
                                            );
                                            return;
                                          }
                                          final oldIdx = _currentTabIndex;
                                          setState(() {
                                            final tab = _createNewTab(
                                              isIncognito: true,
                                            );
                                            _tabs.add(tab);
                                            _currentTabIndex = _tabs.length - 1;
                                            _urlController.text = '';
                                            _showBarsNotifier.value = true;
                                            _updateLruOrder();
                                          });
                                          _onTabSwitched(
                                              oldIdx, _currentTabIndex);
                                          _saveTabs();
                                          Navigator.pop(context);
                                        },
                                      ),
                                      const SizedBox(width: 8),
                                      _TabSwitcherAction(
                                        icon: Icons.add_rounded,
                                        color: accent,
                                        tooltip: L10n.of(
                                          context,
                                          'browser_new_tab',
                                        ),
                                        onPressed: () {
                                          triggerHaptic(settings);
                                          if (_tabs.length >= 10) {
                                            _showTabLimitDialog(
                                              context,
                                              setModalState,
                                              isIncognito: false,
                                            );
                                            return;
                                          }
                                          final oldIdx = _currentTabIndex;
                                          setState(() {
                                            final tab = _createNewTab();
                                            _tabs.add(tab);
                                            _currentTabIndex = _tabs.length - 1;
                                            _urlController.text = '';
                                            _showBarsNotifier.value = true;
                                            _updateLruOrder();
                                          });
                                          _onTabSwitched(
                                              oldIdx, _currentTabIndex);
                                          _saveTabs();
                                          Navigator.pop(context);
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: GridView.builder(
                                    controller: controller,
                                    padding: const EdgeInsets.all(16),
                                    gridDelegate:
                                        const SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: 2,
                                      crossAxisSpacing: 12,
                                      mainAxisSpacing: 12,
                                      childAspectRatio: 0.9,
                                    ),
                                    itemCount: _tabs.length,
                                    itemBuilder: (context, index) {
                                      final tab = _tabs[index];
                                      final isActive =
                                          index == _currentTabIndex;
                                      final tabClr =
                                          tab.isIncognito ? violet : accent;

                                      // E21: Tab Switcher Tab Select/Deselect Animation & Swipe to Close
                                      return Dismissible(
                                          key: ValueKey(tab.id),
                                          direction:
                                              DismissDirection.horizontal,
                                          background: Container(
                                            margin: const EdgeInsets.symmetric(
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: (isDark
                                                      ? AppTheme.neonRed
                                                      : AppTheme.lightNeonRed)
                                                  .withValues(alpha: 0.25),
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                              border: Border.all(
                                                color: (isDark
                                                        ? AppTheme.neonRed
                                                        : AppTheme.lightNeonRed)
                                                    .withValues(alpha: 0.5),
                                                width: 1,
                                              ),
                                            ),
                                            alignment: Alignment.center,
                                            child: Icon(
                                              Icons.delete_outline_rounded,
                                              color: isDark
                                                  ? AppTheme.neonRed
                                                  : AppTheme.lightNeonRed,
                                              size: 26,
                                            ),
                                          ),
                                          onDismissed: (direction) {
                                            triggerHaptic(settings);
                                            setModalState(() {
                                              setState(() {
                                                _cleanupTabState(tab.id);
                                                tab.dispose();
                                                _tabs.removeAt(index);
                                                if (_currentTabIndex >=
                                                    _tabs.length) {
                                                  _currentTabIndex =
                                                      _tabs.length - 1;
                                                }
                                                if (_tabs.isEmpty) {
                                                  _tabs.add(_createNewTab());
                                                  _currentTabIndex = 0;
                                                }
                                                final activeTab =
                                                    _tabs[_currentTabIndex];
                                                _urlController.text =
                                                    activeTab.isHome
                                                        ? ''
                                                        : activeTab.url;
                                              });
                                              _saveTabs();
                                            });
                                          },
                                          child: AnimatedScale(
                                            scale: isActive ? 1.05 : 1.0,
                                            duration: AppTheme.motionFast,
                                            child: GestureDetector(
                                              onTap: () {
                                                triggerHaptic(settings);
                                                _switchTab(index);
                                                Navigator.pop(context);
                                              },
                                              child: AnimatedContainer(
                                                duration: const Duration(
                                                  milliseconds: 200,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: tab.isIncognito
                                                      ? (isDark
                                                          ? (settings
                                                                  .isAmoledMode
                                                              ? AppTheme
                                                                  .amoledSurfaceRaised
                                                              : const Color(
                                                                  0xFF16121F))
                                                          : const Color(
                                                              0xFFF3EEFA))
                                                      : (isDark
                                                          ? (settings
                                                                  .isAmoledMode
                                                              ? AppTheme
                                                                  .amoledCardBg
                                                              : AppTheme.cardBg)
                                                          : AppTheme
                                                              .lightCardBg),
                                                  borderRadius:
                                                      BorderRadius.circular(16),
                                                  border: Border.all(
                                                    color: isActive
                                                        ? tabClr.withValues(
                                                            alpha: 0.8)
                                                        : tabClr.withValues(
                                                            alpha: 0.15),
                                                    width: isActive ? 1.5 : 0.8,
                                                  ),
                                                  boxShadow: isActive
                                                      ? [
                                                          BoxShadow(
                                                            color: tabClr
                                                                .withValues(
                                                              alpha: 0.15,
                                                            ),
                                                            blurRadius: 12,
                                                            spreadRadius: -2,
                                                          ),
                                                        ]
                                                      : null,
                                                ),
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Container(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                        horizontal: 10,
                                                        vertical: 8,
                                                      ),
                                                      decoration: BoxDecoration(
                                                        color:
                                                            tabClr.withValues(
                                                          alpha: isActive
                                                              ? 0.12
                                                              : 0.05,
                                                        ),
                                                        borderRadius:
                                                            const BorderRadius
                                                                .vertical(
                                                          top: Radius.circular(
                                                              15),
                                                        ),
                                                      ),
                                                      child: Row(
                                                        children: [
                                                          Icon(
                                                            tab.isIncognito
                                                                ? Icons
                                                                    .visibility_off_rounded
                                                                : Icons
                                                                    .language_rounded,
                                                            size: 13,
                                                            color: tabClr,
                                                          ),
                                                          const Spacer(),
                                                          GestureDetector(
                                                            onTap: () {
                                                              triggerHaptic(
                                                                  settings);
                                                              setModalState(() {
                                                                setState(() {
                                                                  _cleanupTabState(
                                                                    tab.id,
                                                                  );
                                                                  tab.dispose();
                                                                  _tabs.removeAt(
                                                                      index);
                                                                  if (_currentTabIndex >=
                                                                      _tabs
                                                                          .length) {
                                                                    _currentTabIndex =
                                                                        _tabs.length -
                                                                            1;
                                                                  }
                                                                  if (_tabs
                                                                      .isEmpty) {
                                                                    _tabs.add(
                                                                      _createNewTab(),
                                                                    );
                                                                    _currentTabIndex =
                                                                        0;
                                                                  }
                                                                  final activeTab =
                                                                      _tabs[
                                                                          _currentTabIndex];
                                                                  _urlController
                                                                      .text = activeTab
                                                                          .isHome
                                                                      ? ''
                                                                      : activeTab
                                                                          .url;
                                                                });
                                                                _saveTabs();
                                                              });
                                                            },
                                                            child: Icon(
                                                              Icons
                                                                  .close_rounded,
                                                              size: 15,
                                                              color: isDark
                                                                  ? AppTheme
                                                                      .textMuted
                                                                  : AppTheme
                                                                      .lightTextMuted,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                    const SizedBox(height: 10),
                                                    Expanded(
                                                      child: Padding(
                                                        padding:
                                                            const EdgeInsets
                                                                .symmetric(
                                                          horizontal: 10,
                                                        ),
                                                        child: Text(
                                                          tab.title.isEmpty
                                                              ? 'New Tab'
                                                              : tab.title,
                                                          maxLines: 2,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: TextStyle(
                                                            color: isDark
                                                                ? AppTheme
                                                                    .textPrimary
                                                                : AppTheme
                                                                    .lightTextPrimary,
                                                            fontSize: 12,
                                                            fontWeight:
                                                                FontWeight.bold,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(height: 6),
                                                    Padding(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                        horizontal: 10,
                                                      ),
                                                      child: Text(
                                                        tab.isHome
                                                            ? 'Dashboard'
                                                            : tab.url,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          color: isDark
                                                              ? AppTheme
                                                                  .textMuted
                                                              : AppTheme
                                                                  .lightTextMuted,
                                                          fontSize: 12,
                                                          fontFamily:
                                                              'monospace',
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(height: 10),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ));
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildHomeDashboard(
    BuildContext context,
    SettingsProvider settings, {
    ScrollController? scrollController,
  }) {
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accentColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return SingleChildScrollView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          BrowserHomePage(
            onSearchTap: () {
              _focusNode.requestFocus();
            },
            onBookmarksTap: () async {
              final cleared = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => const BookmarkManagerScreen(),
                ),
              );
              if (cleared == true && mounted) setState(() {});
            },
            onHistoryTap: () {
              _openHistory();
            },
          ),
          const SizedBox(height: 24),
          _SnifferRadarCard(
            settings: settings,
            isEnabled: _isSnifferEnabled,
            onToggle: (val) {
              triggerHaptic(settings);
              _setSnifferEnabled(val);
            },
          ),
          const SizedBox(height: 16),
          Selector<DownloadProvider, ({int active, String speed})>(
            selector: (_, p) => (
              active: p.downloadingTasksCount,
              speed: p.currentDownloadSpeedFormatted,
            ),
            builder: (context, stats, _) {
              if (stats.active == 0) return const SizedBox.shrink();
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
                      .withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color:
                        (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
                            .withValues(alpha: 0.25),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  children: [
                    _LiveDot(
                      color:
                          isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${stats.active} ${isRtl ? "تنزيل نشط" : "Active downloads"}',
                      style: TextStyle(
                        color: isDark
                            ? AppTheme.textPrimary
                            : AppTheme.lightTextPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      Icons.speed_rounded,
                      size: 14,
                      color:
                          isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      stats.speed,
                      style: TextStyle(
                        color: isDark
                            ? AppTheme.neonGreen
                            : AppTheme.lightNeonGreen,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        fontFamily: 'Space Grotesk',
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          GlassCard(
            borderRadius: 24,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            isDarkMode: isDark,
            child: Row(
              children: [
                Icon(
                  Icons.search,
                  color: isDark
                      ? AppTheme.textSecondary
                      : AppTheme.lightTextSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText:
                          isRtl ? 'ابحث في الويب...' : 'Search the web...',
                      hintStyle: TextStyle(
                        color: isDark
                            ? AppTheme.textMuted
                            : AppTheme.lightTextMuted,
                        fontSize: 12,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.textPrimary
                          : AppTheme.lightTextPrimary,
                    ),
                    onSubmitted: (val) {
                      if (val.trim().isNotEmpty) {
                        _navigateToUrl(val);
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                isRtl ? 'محرك البحث:' : 'Search engine:',
                style: TextStyle(
                  color: isDark
                      ? AppTheme.textSecondary
                      : AppTheme.lightTextSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: settings.searchEngine,
                dropdownColor:
                    isDark ? AppTheme.surface : AppTheme.lightSurface,
                menuMaxHeight: 250,
                underline: const SizedBox(),
                style: TextStyle(
                  color: accentColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
                icon: Icon(Icons.arrow_drop_down, color: accentColor, size: 16),
                items: ['Google', 'DuckDuckGo', 'Bing', 'Yahoo'].map((engine) {
                  return DropdownMenuItem<String>(
                    value: engine,
                    child: Text(engine),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) {
                    triggerHaptic(settings);
                    settings.setSearchEngine(val);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              Container(
                width: 3,
                height: 14,
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isRtl ? 'إشارات سريعة (روابط)' : 'Quick access',
                style: TextStyle(
                  color: isDark
                      ? AppTheme.textSecondary
                      : AppTheme.lightTextSecondary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 2.5,
            children: [
              _buildShortcutCard(
                context,
                title: isRtl ? 'العلامات' : 'Bookmarks',
                url: '',
                icon: Icons.bookmark_rounded,
                color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                settings: settings,
                onTap: () async {
                  final cleared = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const BookmarkManagerScreen(),
                    ),
                  );
                  if (cleared == true && mounted) setState(() {});
                },
              ),
              _buildShortcutCard(
                context,
                title: isRtl ? 'السجل' : 'History',
                url: '',
                icon: Icons.history_rounded,
                color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
                settings: settings,
                onTap: _openHistory,
              ),
              _buildShortcutCard(
                context,
                title: isRtl ? 'السكريبتات' : 'Scripts',
                url: '',
                icon: Icons.code_rounded,
                color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                settings: settings,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ScriptManagerScreen(),
                    ),
                  );
                },
              ),
              _buildShortcutCard(
                context,
                title: 'Google',
                url: 'https://google.com',
                icon: Icons.search,
                color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                settings: settings,
              ),
              _buildShortcutCard(
                context,
                title: 'YouTube',
                url: 'https://youtube.com',
                icon: Icons.play_circle_fill,
                color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                settings: settings,
              ),
              _buildShortcutCard(
                context,
                title: 'TikTok',
                url: 'https://www.tiktok.com',
                icon: Icons.music_note,
                color:
                    isDark ? const Color(0xFFFE2C55) : const Color(0xFFE01E43),
                settings: settings,
              ),
              _buildShortcutCard(
                context,
                title: 'GitHub',
                url: 'https://github.com',
                icon: Icons.code,
                color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                settings: settings,
              ),
              _buildShortcutCard(
                context,
                title: 'Archive.org',
                url: 'https://archive.org',
                icon: Icons.history_edu,
                color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
                settings: settings,
              ),
              _buildShortcutCard(
                context,
                title: 'Sample Files',
                url: 'https://file-examples.com',
                icon: Icons.insert_drive_file_outlined,
                color: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
                settings: settings,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildShortcutCard(
    BuildContext context, {
    required String title,
    required String url,
    required IconData icon,
    required Color color,
    required SettingsProvider settings,
    VoidCallback? onTap,
  }) {
    final isDark = settings.isDarkMode;
    final textPrimary =
        isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;

    return GlassCard(
      borderRadius: 16,
      padding: EdgeInsets.zero,
      isDarkMode: isDark,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            triggerHaptic(settings);
            if (onTap != null) {
              onTap();
            } else {
              final activeTab = _tabs[_currentTabIndex];
              setState(() {
                activeTab.isHome = false;
              });
              _navigateToUrl(url);
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: color.withValues(alpha: 0.2),
                      width: 0.7,
                    ),
                  ),
                  child: Icon(icon, color: color, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: textPrimary,
                              fontSize: 13,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        url.replaceAll('https://', ''),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: isDark
                                  ? AppTheme.textMuted
                                  : AppTheme.lightTextMuted,
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final downloadProvider = Provider.of<DownloadProvider>(
      context,
      listen: false,
    );
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final statusBarHeight = MediaQuery.of(context).padding.top;

    if (_tabs.isEmpty ||
        _currentTabIndex < 0 ||
        _currentTabIndex >= _tabs.length) {
      _ensureTabsExist();
      return Scaffold(
        backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
        body: Center(
          child: CircularProgressIndicator(
            color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
          ),
        ),
      );
    }

    final activeTab = _tabs[_currentTabIndex];
    final showFab = !activeTab.isHome &&
        (_detectedDownloadUrls[activeTab.id] != null ||
            (_detectedMediaSources[activeTab.id]?.isNotEmpty ?? false) ||
            _detectedPlaylistUrls.containsKey(activeTab.id) ||
            (_mediaScanFailed[activeTab.id] ?? false));

    if (settings.pinchToZoom != _lastZoomEnabled) {
      _lastZoomEnabled = settings.pinchToZoom;
      for (final tab in _tabs) {
        tab.controller?.setSettings(
          settings: InAppWebViewSettings(
            supportZoom: settings.pinchToZoom,
            incognito: tab.isIncognito,
          ),
        );
      }
    }

    return Listener(
      onPointerDown: (_) => _resetInactivityTimer(),
      onPointerMove: (_) => _resetInactivityTimer(),
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) async {
          if (didPop) {
            return;
          }
          if (downloadProvider.activeTabIndex != 1) {
            return;
          }
          if (_tabs.isEmpty ||
              _currentTabIndex < 0 ||
              _currentTabIndex >= _tabs.length) {
            return;
          }
          if (Navigator.canPop(context)) {
            Navigator.pop(context);
            return;
          }
          final activeTab = _tabs[_currentTabIndex];
          final canGoBack = await activeTab.controller?.canGoBack() ?? false;
          if (canGoBack) {
            await _goBack();
          } else {
            final switched = _switchToPreviousTab();
            if (!switched) {
              downloadProvider.setActiveTabIndex(0);
            }
          }
        },
        child: GeometricGridBackground(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            resizeToAvoidBottomInset: false,
            floatingActionButton:
                showFab ? _buildDownloadFab(context, settings) : null,
            floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
            body: Column(
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: _showBarsNotifier,
                  builder: (context, showBars, child) {
                    return AnimatedSlide(
                      offset: showBars ? Offset.zero : const Offset(0, -1.2),
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      child: AnimatedOpacity(
                        opacity: showBars ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 150),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeInOut,
                          height:
                              showBars ? (kToolbarHeight + statusBarHeight) : 0,
                          clipBehavior: Clip.hardEdge,
                          decoration: const BoxDecoration(),
                          child: child,
                        ),
                      ),
                    );
                  },
                  child: RepaintBoundary(
                    child: DmxBackdropFilter(
                      sigmaX: 12,
                      sigmaY: 12,
                      child: Container(
                        padding: EdgeInsets.only(top: statusBarHeight),
                        height: kToolbarHeight + statusBarHeight,
                        decoration: BoxDecoration(
                          color: settings.classicUi
                              ? (isDark
                                  ? AppTheme.surface
                                  : AppTheme.lightSurface)
                              : (isDark
                                      ? AppTheme.surface
                                      : AppTheme.lightSurface)
                                  .withValues(alpha: 0.88),
                          border: Border(
                            bottom: BorderSide(
                              color: settings.classicUi
                                  ? (isDark
                                      ? AppTheme.border
                                      : AppTheme.lightBorder)
                                  : (isDark
                                      ? AppTheme.glassBorder
                                      : AppTheme.lightGlassBorder),
                              width: settings.classicUi ? 1.0 : 0.8,
                            ),
                          ),
                        ),
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onHorizontalDragEnd: (details) {
                            if (_isFocused) return;
                            if (details.primaryVelocity == null) return;
                            if (details.primaryVelocity! > 0) {
                              _switchToTabRelative(-1);
                            } else if (details.primaryVelocity! < 0) {
                              _switchToTabRelative(1);
                            }
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8.0),
                            child: Row(
                            children: [
                              IconButton(
                                icon:
                                    Icon(Icons.close, size: 20, color: textClr),
                                tooltip:
                                    isRtl ? 'إغلاق المتصفح' : 'Close browser',
                                onPressed: () {
                                  triggerHaptic(settings);
                                  if (Navigator.canPop(context)) {
                                    Navigator.pop(context);
                                  } else {
                                    downloadProvider.setActiveTabIndex(0);
                                  }
                                },
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  height: 38,
                                  decoration: BoxDecoration(
                                    // E3: Incognito Mode Visual Indicator
                                    color: (activeTab.isIncognito ||
                                            settings.incognitoEnabled)
                                        ? const Color(0xFF1A1A2E)
                                        : isDark
                                            ? (settings.isAmoledMode
                                                ? (_isFocused
                                                    ? AppTheme
                                                        .amoledSurfaceRaised
                                                    : AppTheme.amoledBackground)
                                                : (_isFocused
                                                    ? const Color(0xFF141424)
                                                    : const Color(0xFF0F0F16)))
                                            : (_isFocused
                                                ? AppTheme.lightNeonBlue
                                                    .withValues(alpha: 0.08)
                                                : const Color(0xFFF1F5F9)),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: (activeTab.isIncognito ||
                                              settings.incognitoEnabled)
                                          ? AppTheme.neonViolet
                                              .withValues(alpha: 0.3)
                                          : _isFocused
                                              ? (isDark
                                                      ? AppTheme.neonBlue
                                                      : AppTheme.lightNeonBlue)
                                                  .withValues(alpha: 0.5)
                                              : (isDark
                                                  ? const Color(0x15FFFFFF)
                                                  : const Color(0x0D000000)),
                                      width: (activeTab.isIncognito ||
                                              settings.incognitoEnabled)
                                          ? 1.0
                                          : (_isFocused ? 1.2 : 0.8),
                                    ),
                                    boxShadow: (_isFocused &&
                                            isDark &&
                                            settings.enableGlow)
                                        ? [
                                            BoxShadow(
                                              color: (isDark
                                                      ? AppTheme.neonBlue
                                                      : AppTheme.lightNeonBlue)
                                                  .withValues(alpha: 0.25),
                                              blurRadius: 8,
                                              spreadRadius: 0.5,
                                            ),
                                          ]
                                        : null,
                                  ),
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 4),
                                  child: Row(
                                    children: [
                                      // E3: Incognito Icon
                                      if (activeTab.isIncognito ||
                                          settings.incognitoEnabled)
                                        const Tooltip(
                                          message:
                                              'Incognito mode — cookies isolated, history not saved',
                                          child: Padding(
                                            padding: EdgeInsets.symmetric(
                                                horizontal: 4.0),
                                            child: Icon(
                                                Icons.visibility_off_rounded,
                                                size: 14,
                                                color: AppTheme.neonViolet),
                                          ),
                                        ),

                                      // E1 & E2: Security / Loading Indicator
                                      AnimatedSwitcher(
                                        duration: AppTheme.motionBase,
                                        child: activeTab.isLoading
                                            ? const SizedBox(
                                                key: ValueKey('loading'),
                                                width: 14,
                                                height: 14,
                                                child:
                                                    CircularProgressIndicator(
                                                        strokeWidth: 1.5,
                                                        color:
                                                            AppTheme.neonBlue),
                                              )
                                            : Tooltip(
                                                key: const ValueKey('security'),
                                                message: activeTab.url
                                                        .startsWith('https')
                                                    ? 'Secure connection'
                                                    : 'Insecure connection',
                                                child: Padding(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                      horizontal: 6.0),
                                                  child: Icon(
                                                    activeTab.isHome ||
                                                            activeTab
                                                                .url.isEmpty
                                                        ? Icons.search_rounded
                                                        : activeTab.url
                                                                .startsWith(
                                                                    'https')
                                                            ? Icons.lock_rounded
                                                            : Icons
                                                                .lock_open_rounded,
                                                    size: 14,
                                                    color: activeTab.isHome ||
                                                            activeTab
                                                                .url.isEmpty
                                                        ? (isDark
                                                            ? AppTheme.textMuted
                                                            : AppTheme
                                                                .lightTextMuted)
                                                        : activeTab.url
                                                                .startsWith(
                                                                    'https')
                                                            ? AppTheme.neonGreen
                                                            : AppTheme
                                                                .neonAmber,
                                                  ),
                                                ),
                                              ),
                                      ),

                                      // E4 & E10: Ad-blocker Indicator
                                      Tooltip(
                                        message: _adBlocker.isEnabled
                                            ? 'Ad-blocker active'
                                            : 'Ad-blocker disabled',
                                        child: Stack(
                                          clipBehavior: Clip.none,
                                          children: [
                                            Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 4.0),
                                              child: Icon(
                                                _adBlocker.isEnabled
                                                    ? Icons.shield_rounded
                                                    : Icons.shield_outlined,
                                                size: 14,
                                                color: _adBlocker.isEnabled
                                                    ? AppTheme.neonGreen
                                                    : (isDark
                                                        ? AppTheme.textMuted
                                                        : AppTheme
                                                            .lightTextMuted),
                                              ),
                                            ),
                                            if (_adBlocker.isEnabled &&
                                                _blockedAdsCount > 0)
                                              Positioned(
                                                right: -4,
                                                top: -4,
                                                child: Container(
                                                  padding:
                                                      const EdgeInsets.all(2),
                                                  decoration:
                                                      const BoxDecoration(
                                                          color: Colors.red,
                                                          shape:
                                                              BoxShape.circle),
                                                  constraints:
                                                      const BoxConstraints(
                                                          minWidth: 12,
                                                          minHeight: 12),
                                                  child: Text(
                                                      '$_blockedAdsCount',
                                                      style: const TextStyle(
                                                          color: Colors.white,
                                                          fontSize: 8)),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),

                                      // E7: Desktop Mode Indicator
                                      if (settings.desktopMode)
                                        const Tooltip(
                                          message: 'Desktop mode active',
                                          child: Padding(
                                            padding: EdgeInsets.symmetric(
                                                horizontal: 4.0),
                                            child: Icon(
                                                Icons.desktop_windows_rounded,
                                                size: 14,
                                                color: AppTheme.neonBlue),
                                          ),
                                        ),

                                      Expanded(
                                        child: ValueListenableBuilder<
                                            TextEditingValue>(
                                          valueListenable: _urlController,
                                          builder: (context, value, child) {
                                            return TextField(
                                              controller: _urlController,
                                              focusNode: _focusNode,
                                              textAlignVertical:
                                                  TextAlignVertical.center,
                                              style: TextStyle(
                                                  color: textClr, fontSize: 13),
                                              decoration: InputDecoration(
                                                isDense: true,
                                                suffixIcon: IconButton(
                                                  padding: EdgeInsets.zero,
                                                  constraints:
                                                      const BoxConstraints(
                                                          minWidth: 32,
                                                          minHeight: 32),
                                                  icon: Icon(
                                                    activeTab.isLoading
                                                        ? Icons.close
                                                        : (_isFocused &&
                                                                value.text
                                                                    .isNotEmpty)
                                                            ? Icons.clear
                                                            : Icons.refresh,
                                                    size: 16,
                                                    color: _isFocused
                                                        ? (isDark
                                                            ? AppTheme.neonBlue
                                                            : AppTheme
                                                                .lightNeonBlue)
                                                        : (isDark
                                                            ? AppTheme
                                                                .textSecondary
                                                            : AppTheme
                                                                .lightTextSecondary),
                                                  ),
                                                  tooltip: activeTab.isLoading
                                                      ? (isRtl
                                                          ? 'إلغاء التحميل'
                                                          : 'Stop loading')
                                                      : (_isFocused &&
                                                              value.text
                                                                  .isNotEmpty)
                                                          ? (isRtl
                                                              ? 'مسح'
                                                              : 'Clear')
                                                          : (isRtl
                                                              ? 'إعادة تحميل الصفحة'
                                                              : 'Refresh page'),
                                                  onPressed: () {
                                                    triggerHaptic(settings);
                                                    if (activeTab.isLoading) {
                                                      activeTab.controller
                                                          ?.evaluateJavascript(
                                                              source:
                                                                  'window.stop();');
                                                      setState(() {
                                                        activeTab.isLoading =
                                                            false;
                                                      });
                                                    } else if (_isFocused &&
                                                        value.text.isNotEmpty) {
                                                      _urlController.clear();
                                                    } else {
                                                      if (!activeTab.isHome) {
                                                        _safeReloadTab(
                                                            activeTab);
                                                      }
                                                    }
                                                  },
                                                ),
                                                suffixIconConstraints:
                                                    const BoxConstraints(
                                                        minWidth: 32,
                                                        minHeight: 32),
                                                hintText: isRtl
                                                    ? 'ابحث أو ادخل الرابط...'
                                                    : 'Search or enter URL...',
                                                hintStyle: TextStyle(
                                                    color: isDark
                                                        ? AppTheme.textMuted
                                                        : AppTheme
                                                            .lightTextMuted,
                                                    fontSize: 11),
                                                filled: false,
                                                border: InputBorder.none,
                                                enabledBorder: InputBorder.none,
                                                focusedBorder: InputBorder.none,
                                                contentPadding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 4,
                                                        vertical: 6),
                                              ),
                                              onSubmitted: (val) {
                                                _navigateToUrl(val);
                                              },
                                            );
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              if (!activeTab.isHome &&
                                  (YoutubeService.isYoutubeVideoUrl(
                                          activeTab.url) ||
                                      YoutubeService.isPlaylistUrl(
                                          activeTab.url))) ...[
                                _YouTubeGrabButton(
                                  isPlaylist: YoutubeService.isPlaylistUrl(
                                      activeTab.url),
                                  isRtl: isRtl,
                                  isDark: isDark,
                                  enableGlow: settings.enableGlow,
                                  onPressed: () =>
                                      _handleYouTubeGrab(activeTab, settings),
                                ),
                                const SizedBox(width: 4),
                              ],
                              IconButton(
                                icon: Icon(
                                  Icons.arrow_back_ios_new,
                                  size: 15,
                                  color:
                                      (activeTab.canGoBack || !activeTab.isHome)
                                          ? textClr
                                          : (isDark
                                              ? AppTheme.textMuted
                                              : AppTheme.lightTextMuted),
                                ),
                                onPressed:
                                    (activeTab.canGoBack || !activeTab.isHome)
                                        ? () async {
                                            triggerHaptic(settings);
                                            await _goBack();
                                          }
                                        : null,
                              ),
                              IconButton(
                                icon: Icon(
                                  Icons.arrow_forward_ios,
                                  size: 15,
                                  color: activeTab.canGoForward
                                      ? textClr
                                      : (isDark
                                          ? AppTheme.textMuted
                                          : AppTheme.lightTextMuted),
                                ),
                                onPressed: activeTab.canGoForward
                                    ? () async {
                                        triggerHaptic(settings);
                                        await _goForward();
                                      }
                                    : null,
                              ),
                              // E15: Tab Limit Visual Feedback
                              GestureDetector(
                                onTap: () {
                                  triggerHaptic(settings);
                                  _showTabSwitcher(context);
                                },
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    AnimatedContainer(
                                      duration:
                                          const Duration(milliseconds: 200),
                                      margin: const EdgeInsets.symmetric(
                                          horizontal: 6),
                                      width: 26,
                                      height: 26,
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                            color: textClr, width: 1.8),
                                        borderRadius: BorderRadius.circular(7),
                                        color: _tabs.length > 1
                                            ? (isDark
                                                    ? AppTheme.neonBlue
                                                    : AppTheme.lightNeonBlue)
                                                .withValues(alpha: 0.1)
                                            : Colors.transparent,
                                      ),
                                      alignment: Alignment.center,
                                      child: Text(
                                        '${_tabs.length}',
                                        style: TextStyle(
                                          color: textClr,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w800,
                                          fontFamily: 'Space Grotesk',
                                        ),
                                      ),
                                    ),
                                    if (_tabs.length >= 10)
                                      const Positioned(
                                        right: -2,
                                        top: -2,
                                        child: Tooltip(
                                          message: 'Tab limit reached (10/10)',
                                          child: Icon(
                                              Icons.warning_amber_rounded,
                                              size: 12,
                                              color: Colors.orangeAccent),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              PopupMenuButton<String>(
                                icon: Icon(Icons.more_vert,
                                    size: 18, color: textClr),
                                color: (isDark
                                    ? AppTheme.surface
                                    : AppTheme.lightSurface),
                                onSelected: (value) async {
                                  triggerHaptic(settings);
                                  await _handleMenuAction(value);
                                },
                                itemBuilder: (_) => [
                                  _menuItem(Icons.refresh, 'Reload', 'reload',
                                      textClr),
                                  _menuItem(
                                      Icons.bookmark_add_outlined,
                                      'Bookmark this page',
                                      'bookmark',
                                      textClr),
                                  _menuItem(
                                      Icons.bookmarks_outlined,
                                      'Bookmarks Manager',
                                      'show_bookmarks',
                                      textClr),
                                  _menuItem(Icons.history, 'Browser History',
                                      'show_history', textClr),
                                  _menuItem(
                                      Icons.copy, 'Copy URL', 'copy', textClr),
                                  _menuItem(Icons.share, 'Share URL', 'share',
                                      textClr),
                                  _menuItem(Icons.save_alt, 'Save Page Offline',
                                      'offline', textClr),
                                  _menuItem(Icons.menu_book_outlined,
                                      'Reader Mode', 'reader', textClr),
                                  _menuItem(Icons.code, 'Inject JS / CSS',
                                      'injector', textClr),
                                  const PopupMenuDivider(),
                                  _menuItem(
                                    settings.desktopMode
                                        ? Icons.smartphone
                                        : Icons.desktop_mac,
                                    settings.desktopMode
                                        ? 'Mobile mode'
                                        : 'Desktop mode',
                                    'desktop',
                                    textClr,
                                  ),
                                  _menuItem(
                                    _isSnifferEnabled
                                        ? Icons.radar
                                        : Icons.radar_outlined,
                                    _isSnifferEnabled
                                        ? (L10n.isRtl(context)
                                            ? 'كاشف الوسائط: مفعل'
                                            : 'Media detector: ON')
                                        : (L10n.isRtl(context)
                                            ? 'كاشف الوسائط: معطل'
                                            : 'Media detector: OFF'),
                                    'sniffer',
                                    textClr,
                                  ),
                                  _menuItem(
                                    _adBlocker.isEnabled
                                        ? Icons.shield
                                        : Icons.shield_outlined,
                                    _adBlocker.isEnabled
                                        ? 'Ad blocker: ON'
                                        : 'Ad blocker: OFF',
                                    'adblocker',
                                    textClr,
                                  ),
                                  _menuItem(Icons.touch_app_outlined,
                                      'Block Element', 'picker', textClr),
                                  _menuItem(
                                    settings.incognitoEnabled
                                        ? Icons.visibility_off
                                        : Icons.visibility,
                                    settings.incognitoEnabled
                                        ? 'Exit incognito'
                                        : 'New incognito tab',
                                    'incognito',
                                    textClr,
                                  ),
                                  _menuItem(
                                    Icons.exit_to_app_rounded,
                                    L10n.isRtl(context)
                                        ? 'إنهاء المتصفح'
                                        : 'Quit browser',
                                    'quit',
                                    textClr,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (activeTab.isLoading && !activeTab.isHome)
                  ValueListenableBuilder<double>(
                    valueListenable: activeTab.progressNotifier,
                    builder: (context, progressValue, child) {
                      return _ScanlineProgress(
                        progress: progressValue,
                        isDark: isDark,
                      );
                    },
                  ),
                Expanded(
                  child: Stack(
                    children: [
                      GestureDetector(
                        onTap: () {
                          if (_focusNode.hasFocus) {
                            _focusNode.unfocus();
                          }
                        },
                        behavior: HitTestBehavior.translucent,
                        child: _tabs.isEmpty
                            ? const SizedBox.shrink()
                            : Builder(
                                builder: (context) {
                                  _updateLruOrder();
                                  // E16: Tab Switch Animation
                                  return AnimatedSwitcher(
                                    duration: AppTheme.motionBase,
                                    switchInCurve: Curves.easeInOut,
                                    switchOutCurve: Curves.easeInOut,
                                    transitionBuilder: (child, animation) =>
                                        FadeTransition(
                                            opacity: animation, child: child),
                                    child: IndexedStack(
                                      index: _currentTabIndex >= 0 &&
                                              _currentTabIndex < _tabs.length
                                          ? _currentTabIndex
                                          : 0,
                                      children: _tabs.map((tab) {
                                        final tabIndex = _tabs.indexOf(tab);
                                        final isActiveTab =
                                            tabIndex == _currentTabIndex;


                                        if (tab.isHome) {
                                          return SizedBox(
                                            width: double.infinity,
                                            height: double.infinity,
                                            child: _buildHomeDashboard(
                                              context,
                                              settings,
                                              scrollController: isActiveTab
                                                  ? _dashboardScrollController
                                                  : null,
                                            ),
                                          );
                                        } else {
                                          final isLive =
                                              _lruTabIds.contains(tab.id);
                                          if (!isLive) {
                                            return SizedBox(
                                              width: double.infinity,
                                              height: double.infinity,
                                              child: Container(
                                                color: isDark
                                                    ? AppTheme.surface
                                                    : AppTheme.lightSurface,
                                                child: Center(
                                                  child: Column(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .center,
                                                    children: [
                                                      Icon(Icons.web,
                                                          size: 48,
                                                          color: (isDark
                                                                  ? AppTheme
                                                                      .neonBlue
                                                                  : AppTheme
                                                                      .lightNeonBlue)
                                                              .withValues(
                                                                  alpha: 0.6)),
                                                      const SizedBox(
                                                          height: 12),
                                                      Text(
                                                        tab.title.isNotEmpty
                                                            ? tab.title
                                                            : 'Web Page',
                                                        style: TextStyle(
                                                            fontSize: 16,
                                                            fontWeight:
                                                                FontWeight.w600,
                                                            color: isDark
                                                                ? Colors.white
                                                                : Colors
                                                                    .black87),
                                                        textAlign:
                                                            TextAlign.center,
                                                      ),
                                                      if (tab
                                                          .url.isNotEmpty) ...[
                                                        const SizedBox(
                                                            height: 4),
                                                        Padding(
                                                          padding:
                                                              const EdgeInsets
                                                                  .symmetric(
                                                                  horizontal:
                                                                      24),
                                                          child: Text(
                                                            tab.domain
                                                                    .isNotEmpty
                                                                ? tab.domain
                                                                : tab.url,
                                                            style: TextStyle(
                                                                fontSize: 12,
                                                                color: isDark
                                                                    ? Colors
                                                                        .white54
                                                                    : Colors
                                                                        .black54),
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          ),
                                                        ),
                                                      ],
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            );
                                          }
                                          return SizedBox(
                                            width: double.infinity,
                                            height: double.infinity,
                                            child: RepaintBoundary(
                                              key:
                                                  ValueKey('webview_${tab.id}'),
                                              child: RefreshIndicator(
                                                color: isDark
                                                    ? AppTheme.neonBlue
                                                    : AppTheme.lightNeonBlue,
                                                onRefresh: () async {
                                                  tab.hasCrashed = false;
                                                  await _refreshTabForPull(tab);
                                                },
                                                child: tab.hasCrashed
                                                    // E11: Tab Crash Recovery Visual Feedback
                                                    ? AnimatedOpacity(
                                                        opacity: 1.0,
                                                        duration:
                                                            AppTheme.motionBase,
                                                        child: Container(
                                                          color: isDark
                                                              ? AppTheme.surface
                                                              : AppTheme
                                                                  .lightSurface,
                                                          child: Center(
                                                            child: Column(
                                                              mainAxisAlignment:
                                                                  MainAxisAlignment
                                                                      .center,
                                                              children: [
                                                                TweenAnimationBuilder<
                                                                    double>(
                                                                  tween: Tween(
                                                                      begin:
                                                                          0.0,
                                                                      end: 1.0),
                                                                  duration: const Duration(
                                                                      milliseconds:
                                                                          600),
                                                                  curve: Curves
                                                                      .elasticOut,
                                                                  builder:
                                                                      (context,
                                                                          value,
                                                                          child) {
                                                                    final offset = sin(value *
                                                                            pi *
                                                                            4) *
                                                                        (1 -
                                                                            value) *
                                                                        4;
                                                                    return Transform.translate(
                                                                        offset: Offset(
                                                                            offset,
                                                                            0),
                                                                        child:
                                                                            child);
                                                                  },
                                                                  child: const Icon(
                                                                      Icons
                                                                          .error_outline_rounded,
                                                                      size: 54,
                                                                      color: Colors
                                                                          .orangeAccent),
                                                                ),
                                                                const SizedBox(
                                                                    height: 12),
                                                                Text(
                                                                    'This tab crashed unexpectedly',
                                                                    style: TextStyle(
                                                                        fontSize:
                                                                            16,
                                                                        fontWeight:
                                                                            FontWeight
                                                                                .bold,
                                                                        color: isDark
                                                                            ? Colors.white
                                                                            : Colors.black87)),
                                                                const SizedBox(
                                                                    height: 8),
                                                                Text(tab.url,
                                                                    style: TextStyle(
                                                                        fontSize:
                                                                            12,
                                                                        color: isDark
                                                                            ? Colors
                                                                                .white54
                                                                            : Colors
                                                                                .black54),
                                                                    maxLines: 1,
                                                                    overflow:
                                                                        TextOverflow
                                                                            .ellipsis),
                                                                const SizedBox(
                                                                    height: 16),
                                                                ElevatedButton
                                                                    .icon(
                                                                  style: ElevatedButton.styleFrom(
                                                                      backgroundColor: isDark
                                                                          ? AppTheme
                                                                              .neonBlue
                                                                          : AppTheme
                                                                              .lightNeonBlue,
                                                                      foregroundColor:
                                                                          Colors
                                                                              .white),
                                                                  onPressed:
                                                                      () {
                                                                    _safeReloadTab(
                                                                        tab);
                                                                  },
                                                                  icon: const Icon(
                                                                      Icons
                                                                          .refresh_rounded,
                                                                      size: 18),
                                                                  label: const Text(
                                                                      'Reload Tab'),
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                        ),
                                                      )
                                                    : Stack(
                                                        children: [
                                                          InAppWebView(
                                                            initialUrlRequest: tab
                                                                    .url.isEmpty
                                                                ? null
                                                                : URLRequest(
                                                                    url: WebUri(
                                                                        tab.url)),
                                                            onWebViewCreated:
                                                                (controller) {
                                                              _configureController(
                                                                  tab,
                                                                  controller);
                                                              _hideWebViewFingerprints(
                                                                  tab);
                                                              if (tab.url
                                                                      .isNotEmpty &&
                                                                  tab.url !=
                                                                      'about:blank') {
                                                                controller.loadUrl(
                                                                    urlRequest:
                                                                        URLRequest(
                                                                            url:
                                                                                WebUri(tab.url)));
                                                              }
                                                            },
                                                            initialUserScripts:
                                                                UnmodifiableListView<
                                                                    UserScript>([
                                                              UserScript(
                                                                source: '''
                                                                  window.XDM_LongPress = { postMessage: function(msg) { window.flutter_inappwebview.callHandler('XDM_LongPress', msg); } };
                                                                  window.XDM_Popups = { postMessage: function(msg) { window.flutter_inappwebview.callHandler('XDM_Popups', msg); } };
                                                                  window.XdmPickerChannel = { postMessage: function(msg) { window.flutter_inappwebview.callHandler('XdmPickerChannel', msg); } };
                                                                ''',
                                                                injectionTime:
                                                                    UserScriptInjectionTime
                                                                        .AT_DOCUMENT_START,
                                                              ),
                                                            ]),
                                                            initialSettings:
                                                                InAppWebViewSettings(
                                                              useShouldOverrideUrlLoading:
                                                                  true,
                                                              useOnDownloadStart:
                                                                  true,
                                                              useHybridComposition:
                                                                  true,
                                                              useShouldInterceptRequest:
                                                                  true,
                                                              transparentBackground:
                                                                  true,
                                                              allowsInlineMediaPlayback:
                                                                  true,
                                                              mediaPlaybackRequiresUserGesture:
                                                                  false,
                                                              javaScriptEnabled:
                                                                  true,
                                                              domStorageEnabled:
                                                                  true,
                                                              databaseEnabled:
                                                                  true,
                                                              thirdPartyCookiesEnabled:
                                                                  true,
                                                              cacheEnabled:
                                                                  true,
                                                              supportZoom: settings
                                                                      .desktopMode ||
                                                                  settings
                                                                      .pinchToZoom,
                                                              contentBlockers:
                                                                  _adBlocker
                                                                      .contentBlockers,
                                                              incognito: tab
                                                                  .isIncognito,
                                                            ),
                                                            onConsoleMessage:
                                                                (controller,
                                                                    consoleMessage) {
                                                              final msg =
                                                                  consoleMessage
                                                                      .message;
                                                              if (msg.contains(
                                                                      'recaptcha') ||
                                                                  msg.contains(
                                                                      "reading 'e3'")) {
                                                                return;
                                                              }
                                                              _log.fine(
                                                                  '[WebView Console] ${consoleMessage.messageLevel}: $msg');
                                                            },
                                                            gestureRecognizers: <Factory<
                                                                OneSequenceGestureRecognizer>>{
                                                              Factory<VerticalDragGestureRecognizer>(
                                                                  () =>
                                                                      VerticalDragGestureRecognizer()),
                                                              Factory<HorizontalDragGestureRecognizer>(
                                                                  () =>
                                                                      HorizontalDragGestureRecognizer()),
                                                            },
                                                            pullToRefreshController:
                                                                tab.pullToRefreshController,
                                                            onScrollChanged:
                                                                (controller, x,
                                                                    y) {
                                                              if (mounted &&
                                                                  _currentTabIndex >=
                                                                      0 &&
                                                                  _currentTabIndex <
                                                                      _tabs
                                                                          .length &&
                                                                  _tabs[_currentTabIndex]
                                                                          .id ==
                                                                      tab.id) {
                                                                _handleScroll(y
                                                                    .toDouble());
                                                              }
                                                            },
                                                            onLoadStart:
                                                                (controller,
                                                                    url) {
                                                              _onPageStart(
                                                                  tab,
                                                                  url?.toString() ??
                                                                      '');
                                                            },
                                                            onLoadStop:
                                                                (controller,
                                                                    url) {
                                                              _onPageStop(
                                                                  tab,
                                                                  url?.toString() ??
                                                                      '');
                                                            },
                                                            onProgressChanged:
                                                                (controller,
                                                                    progress) {
                                                              if (progress ==
                                                                      0 ||
                                                                  progress ==
                                                                      100 ||
                                                                  (progress - tab.lastRenderedProgress)
                                                                          .abs() >=
                                                                      2) {
                                                                tab.lastRenderedProgress =
                                                                    progress;
                                                                tab.progress =
                                                                    progress /
                                                                        100;
                                                              }
                                                            },
                                                            onUpdateVisitedHistory:
                                                                (controller,
                                                                    url,
                                                                    isReload) {
                                                              if (url != null) {
                                                                _onUrlChange(
                                                                    tab,
                                                                    url.toString());
                                                              }
                                                            },
                                                            onReceivedError:
                                                                (controller,
                                                                    request,
                                                                    error) async {
                                                              _log.warning(
                                                                  '[Browser] WebResourceError on tab ${tab.id}: ${error.description}');
                                                              final errUrl =
                                                                  request.url
                                                                      .toString();
                                                              if (errUrl.startsWith(
                                                                      'magnet:') ||
                                                                  isMagnetUrl(
                                                                      errUrl) ||
                                                                  error
                                                                      .description
                                                                      .contains(
                                                                          'ERR_UNKNOWN_URL_SCHEME')) {
                                                                _log.info(
                                                                    '[Browser] WebResourceError handled for magnet link: $errUrl');
                                                                controller
                                                                    .stopLoading();
                                                                if (await controller
                                                                    .canGoBack()) {
                                                                  await controller
                                                                      .goBack();
                                                                }
                                                                if (mounted) {
                                                                  setState(() {
                                                                    tab.isLoading =
                                                                        false;
                                                                  });
                                                                }
                                                                return;
                                                              }
                                                              if (mounted &&
                                                                  request.isForMainFrame ==
                                                                      true) {
                                                                setState(() {
                                                                  tab.isLoading =
                                                                      false;
                                                                });
                                                              }
                                                            },
                                                            onRenderProcessGone:
                                                                (controller,
                                                                    detail) async {
                                                              _log.warning(
                                                                  '[Browser] Render process gone on tab ${tab.id}: didCrash=${detail.didCrash}');
                                                              if (mounted) {
                                                                setState(() {
                                                                  tab.isLoading =
                                                                      false;
                                                                  tab.hasCrashed =
                                                                      true;
                                                                  tab.controller =
                                                                      null;
                                                                });
                                                              }
                                                            },
                                                            shouldInterceptRequest:
                                                                (controller,
                                                                    request) async {
                                                              final url = request
                                                                  .url
                                                                  .toString();
                                                              final currentUrl = await controller.getUrl();
                                                              final mainHost = currentUrl?.host.toLowerCase() ?? '';
                                                              final requestHost = request.url.host.toLowerCase();

                                                              // First-party bypass: Never block requests made to first-party hosts or their subdomains
                                                              bool isFirstParty = false;
                                                              if (mainHost.isNotEmpty && requestHost.isNotEmpty) {
                                                                if (requestHost == mainHost ||
                                                                    requestHost.endsWith('.$mainHost') ||
                                                                    mainHost.endsWith('.$requestHost')) {
                                                                  isFirstParty = true;
                                                                }
                                                                // sister domains check (e.g. akw.to <-> akwam.to, akoam.com)
                                                                if (!isFirstParty &&
                                                                    ((mainHost.contains('akw') && requestHost.contains('akw')) ||
                                                                     (mainHost.contains('akoam') && requestHost.contains('akoam')))) {
                                                                  isFirstParty = true;
                                                                }
                                                              }

                                                              if (!isFirstParty && _adBlocker.shouldBlock(url)) {
                                                                // E10: Blocked Ads Count Indicator
                                                                _blockedAdsCount++;
                                                                return WebResourceResponse(
                                                                  contentType:
                                                                      'text/plain',
                                                                  contentEncoding:
                                                                      'utf-8',
                                                                  statusCode:
                                                                      204,
                                                                  reasonPhrase:
                                                                      'Blocked',
                                                                  data:
                                                                      Uint8List(
                                                                          0),
                                                                );
                                                              }
                                                              return null;
                                                            },
                                                            shouldOverrideUrlLoading:
                                                                (controller,
                                                                    navigationAction) async {
                                                              final url =
                                                                  navigationAction
                                                                          .request
                                                                          .url
                                                                          ?.toString() ??
                                                                      '';
                                                              if (url.isEmpty) {
                                                                return NavigationActionPolicy
                                                                    .ALLOW;
                                                              }

                                                              // 0. Ad-blocker: cancel navigation-level ad redirects
                                                              // Only block sub-frame navigations (ads redirect in iframes/popups)
                                                              // Never block main-frame navigations so user can still browse
                                                              if (navigationAction
                                                                          .isForMainFrame !=
                                                                      true &&
                                                                  _adBlocker
                                                                      .shouldBlock(
                                                                          url)) {
                                                                _adBlocker
                                                                    .recordBlocked(
                                                                        url);
                                                                return NavigationActionPolicy
                                                                    .CANCEL;
                                                              }

                                                              // 1. Magnet link check
                                                              if (url.startsWith(
                                                                      'magnet:') ||
                                                                  isMagnetUrl(
                                                                      url)) {
                                                                _log.info(
                                                                    '[Browser] Intercepted magnet link in navigation: $url');
                                                                _showInterceptionSheet(
                                                                    context,
                                                                    url);
                                                                return NavigationActionPolicy
                                                                    .CANCEL;
                                                              }

                                                              // 2. HTTPS-only upgrade check
                                                              if (navigationAction
                                                                          .isForMainFrame ==
                                                                      true &&
                                                                  settings
                                                                      .httpsOnly &&
                                                                  url.startsWith(
                                                                      'http://')) {
                                                                final upgraded =
                                                                    url.replaceFirst(
                                                                        'http://',
                                                                        'https://');
                                                                _log.warning(
                                                                    '[Browser] HTTPS-only: upgrading $url -> $upgraded');
                                                                controller.loadUrl(
                                                                    urlRequest:
                                                                        URLRequest(
                                                                            url:
                                                                                WebUri(upgraded)));
                                                                return NavigationActionPolicy
                                                                    .CANCEL;
                                                              }

                                                              // 3. Bypass & User-initiated checks
                                                              if (_interceptor
                                                                  .consumeBypass(
                                                                      url)) {
                                                                return NavigationActionPolicy
                                                                    .ALLOW;
                                                              }
                                                              if (_redirectGuard
                                                                  .consumeUserInitiated(
                                                                      url)) {
                                                                return NavigationActionPolicy
                                                                    .ALLOW;
                                                              }

                                                              // 4. Smart classification
                                                              final classification =
                                                                  PageIntentClassifier
                                                                      .instance
                                                                      .classifyWithContext(
                                                                currentUrl:
                                                                    tab.url,
                                                                targetUrl: url,
                                                                isUserInitiated:
                                                                    navigationAction
                                                                        .isForMainFrame,
                                                                isFromClick:
                                                                    navigationAction
                                                                            .request
                                                                            .method ==
                                                                        'GET',
                                                              );

                                                              _log.info(
                                                                  '[Browser] Classification for $url: ${classification.action.name} (intent: ${classification.intent.name}, confidence: ${classification.confidence})');

                                                              switch (
                                                                  classification
                                                                      .action) {
                                                                case PageAction
                                                                      .block:
                                                                  AdBlockerService
                                                                      .instance
                                                                      .recordBlockedRequest(
                                                                          url);
                                                                  _log.warning(
                                                                      '[AdBlocker] Blocked: $url');
                                                                  return NavigationActionPolicy
                                                                      .CANCEL;

                                                                case PageAction
                                                                      .openNewTab:
                                                                case PageAction
                                                                      .openNewTabWithWarning:
                                                                case PageAction
                                                                      .openNewTabWithDownloadSuggestion:
                                                                  _openInNewTab(
                                                                      url,
                                                                      isIncognito: tab
                                                                          .isIncognito,
                                                                      switchToTab:
                                                                          true);
                                                                  if (classification
                                                                          .action ==
                                                                      PageAction
                                                                          .openNewTabWithDownloadSuggestion) {
                                                                    _suggestDownload(
                                                                        url,
                                                                        classification);
                                                                  }
                                                                  if (classification
                                                                          .action ==
                                                                      PageAction
                                                                          .openNewTabWithWarning) {
                                                                    _showAdWarning(
                                                                        context,
                                                                        url);
                                                                  }
                                                                  return NavigationActionPolicy
                                                                      .CANCEL;

                                                                case PageAction
                                                                      .openBackgroundTab:
                                                                  _openInBackgroundTab(
                                                                      url,
                                                                      isIncognito:
                                                                          tab.isIncognito);
                                                                  return NavigationActionPolicy
                                                                      .CANCEL;

                                                                case PageAction
                                                                      .directDownload:
                                                                  _startDirectDownload(
                                                                      url,
                                                                      suggestedName:
                                                                          classification
                                                                              .detectedFileName);
                                                                  return NavigationActionPolicy
                                                                      .CANCEL;

                                                                case PageAction
                                                                      .openSameTab:
                                                                  if (_interceptor.shouldIntercept(
                                                                      tabUrl: tab
                                                                          .url,
                                                                      requestUrl:
                                                                          url)) {
                                                                    setState(
                                                                        () {
                                                                      _detectedDownloadUrls[
                                                                              tab.id] =
                                                                          url;
                                                                    });
                                                                    _showInterceptionSheet(
                                                                        context,
                                                                        url);
                                                                    return NavigationActionPolicy
                                                                        .CANCEL;
                                                                  }
                                                                  if (_redirectGuard
                                                                      .isAlwaysNewTab(
                                                                          url)) {
                                                                    _openInNewTab(
                                                                        url,
                                                                        isIncognito: tab
                                                                            .isIncognito,
                                                                        switchToTab:
                                                                            true);
                                                                    return NavigationActionPolicy
                                                                        .CANCEL;
                                                                  }
                                                                  if (_redirectGuard.isSuspiciousRedirect(
                                                                      currentTabUrl:
                                                                          tab
                                                                              .url,
                                                                      targetUrl:
                                                                          url)) {
                                                                    _handleRedirectIntercept(
                                                                        tab,
                                                                        url);
                                                                    return NavigationActionPolicy
                                                                        .CANCEL;
                                                                  }
                                                                  return NavigationActionPolicy
                                                                      .ALLOW;
                                                              }
                                                            },
                                                          ),
                                                          // E13: Tab Suspension/Resume Visual Feedback
                                                          if (_restoringTabId ==
                                                              tab.id)
                                                            Positioned.fill(
                                                              child:
                                                                  AnimatedOpacity(
                                                                opacity: 1.0,
                                                                duration: AppTheme
                                                                    .motionBase,
                                                                child:
                                                                    Container(
                                                                  color: Colors
                                                                      .black
                                                                      .withValues(
                                                                          alpha:
                                                                              0.7),
                                                                  child: const Center(
                                                                      child: Text(
                                                                          'Restoring tab...',
                                                                          style: TextStyle(
                                                                              color: Colors.white,
                                                                              fontSize: 16))),
                                                                ),
                                                              ),
                                                            ),
                                                          // E5: Media Sniffer Detection Feedback
                                                          if (_detectedMediaSources[
                                                                      activeTab
                                                                          .id]
                                                                  ?.isNotEmpty ??
                                                              false)
                                                            Positioned(
                                                              top: 16,
                                                              right: 16,
                                                              child:
                                                                  AnimatedScale(
                                                                scale: 1.0,
                                                                duration: AppTheme
                                                                    .motionBase,
                                                                child:
                                                                    AnimatedOpacity(
                                                                  opacity: 1.0,
                                                                  duration: AppTheme
                                                                      .motionBase,
                                                                  child: Stack(
                                                                    alignment:
                                                                        Alignment
                                                                            .center,
                                                                    children: [
                                                                      Container(
                                                                        width:
                                                                            24,
                                                                        height:
                                                                            24,
                                                                        decoration: BoxDecoration(
                                                                            shape:
                                                                                BoxShape.circle,
                                                                            color: AppTheme.neonBlue.withValues(alpha: 0.3)),
                                                                      ),
                                                                      const CircleAvatar(
                                                                        backgroundColor:
                                                                            AppTheme.neonBlue,
                                                                        radius:
                                                                            10,
                                                                        child: Icon(
                                                                            Icons
                                                                                .download_rounded,
                                                                            size:
                                                                                12,
                                                                            color:
                                                                                Colors.white),
                                                                      ),
                                                                      Positioned(
                                                                        top: -4,
                                                                        right:
                                                                            -4,
                                                                        child:
                                                                            Container(
                                                                          padding: const EdgeInsets
                                                                              .all(
                                                                              2),
                                                                          decoration: const BoxDecoration(
                                                                              color: Colors.red,
                                                                              shape: BoxShape.circle),
                                                                          constraints: const BoxConstraints(
                                                                              minWidth: 14,
                                                                              minHeight: 14),
                                                                          child: Text(
                                                                              '${_detectedMediaSources[activeTab.id]!.length}',
                                                                              style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                                                                        ),
                                                                      ),
                                                                    ],
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                          // E6: Element Picker Mode Indicator
                                                          if (_isPickerModeActive)
                                                            Positioned(
                                                              top: 0,
                                                              left: 0,
                                                              right: 0,
                                                              child: Material(
                                                                color:
                                                                    Colors.blue,
                                                                child: Padding(
                                                                  padding: const EdgeInsets
                                                                      .symmetric(
                                                                      vertical:
                                                                          8.0,
                                                                      horizontal:
                                                                          16.0),
                                                                  child: Row(
                                                                    children: [
                                                                      const Icon(
                                                                          Icons
                                                                              .touch_app_rounded,
                                                                          color: Colors
                                                                              .white,
                                                                          size:
                                                                              16),
                                                                      const SizedBox(
                                                                          width:
                                                                              8),
                                                                      const Expanded(
                                                                          child: Text(
                                                                              'Element Picker Mode — Tap an element to block it',
                                                                              style: TextStyle(color: Colors.white, fontSize: 12))),
                                                                      TextButton(
                                                                          onPressed: () => setState(() => _isPickerModeActive =
                                                                              false),
                                                                          child: const Text(
                                                                              'Done',
                                                                              style: TextStyle(color: Colors.white))),
                                                                    ],
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                          if (_isPickerModeActive)
                                                            Positioned.fill(
                                                              child:
                                                                  IgnorePointer(
                                                                ignoring: true,
                                                                child: Container(
                                                                    decoration: BoxDecoration(
                                                                        border: Border.all(
                                                                            color:
                                                                                Colors.blue.withValues(alpha: 0.5),
                                                                            width: 2))),
                                                              ),
                                                            ),
                                                          // E12: Tab Timeout Visual Feedback
                                                          if (tab.isTimedOut &&
                                                              tab.isLoading)
                                                            Positioned(
                                                              top: 0,
                                                              left: 0,
                                                              right: 0,
                                                              child:
                                                                  AnimatedOpacity(
                                                                opacity: 1.0,
                                                                duration: AppTheme
                                                                    .motionBase,
                                                                child:
                                                                    Container(
                                                                  padding: const EdgeInsets
                                                                      .symmetric(
                                                                      horizontal:
                                                                          12,
                                                                      vertical:
                                                                          6),
                                                                  color: Colors
                                                                      .orange
                                                                      .withValues(
                                                                          alpha:
                                                                              0.9),
                                                                  child: Row(
                                                                    children: [
                                                                      TweenAnimationBuilder<
                                                                          double>(
                                                                        tween: Tween(
                                                                            begin:
                                                                                0.8,
                                                                            end:
                                                                                1.2),
                                                                        duration:
                                                                            const Duration(milliseconds: 800),
                                                                        builder: (context, value, child) => Transform.scale(
                                                                            scale:
                                                                                value,
                                                                            child:
                                                                                child),
                                                                        child: const Icon(
                                                                            Icons
                                                                                .warning_amber_rounded,
                                                                            size:
                                                                                16,
                                                                            color:
                                                                                Colors.white),
                                                                      ),
                                                                      const SizedBox(
                                                                          width:
                                                                              8),
                                                                      const Expanded(
                                                                        child: Text(
                                                                            'Page load taking long...',
                                                                            style: TextStyle(
                                                                                fontSize: 12,
                                                                                color: Colors.white,
                                                                                fontWeight: FontWeight.bold)),
                                                                      ),
                                                                      GestureDetector(
                                                                        onTap:
                                                                            () {
                                                                          tab.controller
                                                                              ?.evaluateJavascript(source: 'window.stop();');
                                                                          setState(
                                                                              () {
                                                                            tab.isLoading =
                                                                                false;
                                                                            tab.isTimedOut =
                                                                                false;
                                                                          });
                                                                        },
                                                                        child: Padding(
                                                                            padding:
                                                                                const EdgeInsets.symmetric(horizontal: 6),
                                                                            child: Text(L10n.of(context, 'stop_loading'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12))),
                                                                      ),
                                                                      GestureDetector(
                                                                        onTap:
                                                                            () {
                                                                          _safeReloadTab(
                                                                              tab);
                                                                          tab.isTimedOut =
                                                                              false;
                                                                        },
                                                                        child: Padding(
                                                                            padding:
                                                                                const EdgeInsets.symmetric(horizontal: 6),
                                                                            child: Text(L10n.of(context, 'reload_page'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12))),
                                                                      ),
                                                                    ],
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                        ],
                                                      ),
                                              ),
                                            ),
                                          );
                                        }
                                      }).toList(),
                                    ),
                                  );
                                },
                              ),
                      ),
                      if (!activeTab.isHome)
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: 28,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onHorizontalDragEnd: (details) {
                              if (details.primaryVelocity != null &&
                                  details.primaryVelocity! > 300) {
                                if (mounted) {
                                  triggerHaptic(settings);
                                  _goBack();
                                }
                              }
                            },
                          ),
                        ),
                      if (!activeTab.isHome)
                        Positioned(
                          right: 0,
                          top: 0,
                          bottom: 0,
                          width: 28,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onHorizontalDragEnd: (details) {
                              if (details.primaryVelocity != null &&
                                  details.primaryVelocity! < -300) {
                                if (mounted) {
                                  triggerHaptic(settings);
                                  _goForward();
                                }
                              }
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleYouTubeGrab(
    BrowserTab activeTab,
    SettingsProvider settings,
  ) async {
    triggerHaptic(settings);
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final tabUrl = activeTab.url;

    final isPlaylist = YoutubeService.isPlaylistUrl(tabUrl);
    final isVideo = YoutubeService.isYoutubeVideoUrl(tabUrl);
    final isMixed = isPlaylist && isVideo;

    if (isMixed) {
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: Text(
            isRtl ? 'ماذا تريد تحميل؟' : 'What do you want to download?',
            style: TextStyle(
                color: isDark ? Colors.white : Colors.black87,
                fontSize: 16,
                fontWeight: FontWeight.bold),
          ),
          content: Text(
            isRtl
                ? 'هذا الرابط يحتوي على فيديو وقائمة تشغيل.'
                : 'This link contains both a single video and a playlist.',
            style: TextStyle(
                color: isDark ? Colors.white70 : Colors.black54, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'video'),
              child: Text(isRtl ? 'فيديو واحد فقط' : 'Single video',
                  style: const TextStyle(
                      color: Colors.blue, fontWeight: FontWeight.bold)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'playlist'),
              child: Text(isRtl ? 'قائمة التشغيل كاملة' : 'Entire playlist',
                  style: const TextStyle(
                      color: Colors.red, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (choice == 'playlist') {
        final result = await YoutubePlaylistSheet.show(context, tabUrl);
        if (!mounted) return;
        if (result != null) {
          ThemedSnackbar.show(
            context,
            message: isRtl
                ? 'تمت إضافة ${result.selectedVideos.length} فيديو إلى قائمة الانتظار'
                : '${result.selectedVideos.length} videos enqueued from "${result.playlistTitle}"',
            color: AppTheme.neonGreen,
            icon: Icons.playlist_add_check,
            isDarkMode: isDark,
          );
        }
        return;
      } else if (choice != 'video') {
        return;
      }
    } else if (isPlaylist) {
      final result = await YoutubePlaylistSheet.show(context, tabUrl);
      if (!mounted) return;
      if (result != null) {
        ThemedSnackbar.show(
          context,
          message: isRtl
              ? 'تمت إضافة ${result.selectedVideos.length} فيديو إلى قائمة الانتظار'
              : '${result.selectedVideos.length} videos enqueued from "${result.playlistTitle}"',
          color: AppTheme.neonGreen,
          icon: Icons.playlist_add_check,
          isDarkMode: isDark,
        );
      }
      return;
    }

    final stream = await YoutubeQualitySheet.show(context, tabUrl);
    if (!mounted) return;
    if (stream != null) {
      final title = stream['title'] as String? ?? 'YouTube video';
      final ext = stream['ext'] as String? ?? 'mp4';
      _startDirectDownload(
        stream['src'] as String,
        suggestedName: '$title.$ext',
        type: 'video',
        audioUrl: stream['audioSrc'] as String?,
        videoSize: stream['videoSize'] as int?,
        audioSize: stream['audioSize'] as int?,
      );
    }
  }

  void _openBookmarks() async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    triggerHaptic(settings);
    final url = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const BookmarkManagerScreen()),
    );
    if (url != null && url.isNotEmpty && mounted) {
      _navigateToUrl(url);
    }
  }

  void _openHistory() async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    triggerHaptic(settings);
    final url = await BrowserHistorySheet.show(context);
    if (url != null && url.isNotEmpty && mounted) {
      _navigateToUrl(url);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newProvider = Provider.of<DownloadProvider>(context);
    if (_downloadProvider != newProvider) {
      _downloadProvider?.removeListener(_onDownloadProviderChanged);
      _downloadProvider = newProvider;
      _downloadProvider?.addListener(_onDownloadProviderChanged);
    }
  }

  void _onDownloadProviderChanged() {
    final urlToLoad = _downloadProvider?.browserUrlToLoad;
    if (urlToLoad != null) {
      _downloadProvider?.clearBrowserUrlToLoad();
      _navigateToUrl(urlToLoad);
    }
  }

  Widget _buildDownloadFab(BuildContext context, SettingsProvider settings) {
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final activeTab = _tabs[_currentTabIndex];

    if (_isYoutubeHost(activeTab.url)) {
      return _buildDefaultDownloadFab(isDark, accent, settings, activeTab);
    }

    if (_mediaScanFailed[activeTab.id] == true) {
      return _SignalFab(
        color: Colors.orange,
        icon: Icons.refresh_rounded,
        label: 'Scan failed (retry)',
        pulse: false,
        isDark: isDark,
        onPressed: () {
          triggerHaptic(settings);
          _scanPageMedia(activeTab);
        },
      );
    }

    final detectedSources = _detectedMediaSources[activeTab.id] ?? [];
    final isPlaylist = _detectedPlaylistUrls.containsKey(activeTab.id);
    final playlistCount = _detectedPlaylistUrls[activeTab.id] ?? 0;

    if (isPlaylist) {
      return _SignalFab(
        color: Colors.red,
        icon: Icons.playlist_play_rounded,
        label: 'Playlist${playlistCount > 0 ? ' ($playlistCount)' : ''}',
        pulse: true,
        isDark: isDark,
        onPressed: () async {
          triggerHaptic(settings);
          final result =
              await YoutubePlaylistSheet.show(context, activeTab.url);
          if (result != null && context.mounted) {
            ThemedSnackbar.show(
              context,
              message:
                  '${result.selectedVideos.length} videos enqueued from "${result.playlistTitle}"',
              color: AppTheme.neonGreen,
              icon: Icons.playlist_add_check,
              isDarkMode: isDark,
            );
          }
        },
      );
    }

    if (YoutubeService.isExtractableMediaUrl(activeTab.url) &&
        detectedSources.isNotEmpty) {
      return _SignalFab(
        color: Colors.red,
        icon: Icons.play_circle_filled,
        label: detectedSources.length > 1
            ? 'Media (${detectedSources.length})'
            : 'Media',
        pulse: true,
        isDark: isDark,
        onPressed: () async {
          triggerHaptic(settings);
          if (detectedSources.length > 1) {
            _showDetectedMediaSheet(context, activeTab.id);
          } else {
            final stream =
                await YoutubeQualitySheet.show(context, activeTab.url);
            if (stream != null && context.mounted) {
              final title = stream['title'] as String? ?? 'Media video';
              final ext = stream['ext'] as String? ?? 'mp4';
              _startDirectDownload(
                stream['src'] as String,
                suggestedName: '$title.$ext',
                type: 'video',
                audioUrl: stream['audioSrc'] as String?,
                videoSize: stream['videoSize'] as int?,
                audioSize: stream['audioSize'] as int?,
              );
            }
          }
        },
      );
    }

    if (YoutubeService.isYoutubeVideoUrl(activeTab.url) &&
        _ytDetectionFailed.containsKey(activeTab.url)) {
      return _SignalFab(
        color: Colors.red.withValues(alpha: 0.6),
        icon: Icons.refresh_rounded,
        label: 'YouTube (retry)',
        pulse: false,
        isDark: isDark,
        onPressed: () async {
          triggerHaptic(settings);
          setState(() {
            _ytDetectionFailed.remove(activeTab.url);
          });
          _scanPageMedia(activeTab);
        },
      );
    }

    return _SignalFab(
      color: accent,
      icon: Icons.download_rounded,
      label: detectedSources.length > 1
          ? 'Downloads (${detectedSources.length})'
          : 'Download',
      pulse: detectedSources.isNotEmpty,
      isDark: isDark,
      onPressed: () {
        triggerHaptic(settings);
        if (detectedSources.length > 1) {
          _showDetectedMediaSheet(context, activeTab.id);
        } else {
          final url = detectedSources.isNotEmpty
              ? detectedSources.first['src']
              : _detectedDownloadUrls[activeTab.id];
          if (url == null) return;
          final title = detectedSources.isNotEmpty
              ? detectedSources.first['title'] as String?
              : null;
          final ext = detectedSources.isNotEmpty
              ? detectedSources.first['ext'] as String?
              : null;
          String? filename;
          if (title != null && title.isNotEmpty) {
            filename = ext != null ? "$title.$ext" : title;
          }
          BrowserDownloadSheet.show(
            context,
            url,
            suggestedName: filename,
            onQuality: () => _showQualityPicker(activeTab.id, fallbackUrl: url),
            downloadPageUrl: activeTab.isHome ? null : activeTab.url,
          );
        }
      },
    );
  }

  Widget _buildDefaultDownloadFab(
    bool isDark,
    Color accent,
    SettingsProvider settings,
    BrowserTab activeTab,
  ) {
    final url = _detectedDownloadUrls[activeTab.id];
    return _SignalFab(
      color: accent,
      icon: Icons.download_rounded,
      label: 'Download',
      pulse: false,
      isDark: isDark,
      onPressed: () {
        triggerHaptic(settings);
        if (url != null) {
          BrowserDownloadSheet.show(
            context,
            url,
            onQuality: () => _showQualityPicker(activeTab.id, fallbackUrl: url),
            downloadPageUrl: activeTab.isHome ? null : activeTab.url,
          );
        }
      },
    );
  }

  Future<void> _startDirectDownload(
    String url, {
    String? suggestedName,
    String? type,
    String? downloadPageUrl,
    String? audioUrl,
    int? videoSize,
    int? audioSize,
  }) async {
    final settingsProvider =
        Provider.of<SettingsProvider>(context, listen: false);
    final isRtl = L10n.isRtl(context);
    final isDark = settingsProvider.isDarkMode;

    final result = await _interceptor.startDirectDownload(
      url,
      suggestedName: suggestedName,
      type: type,
      downloadPageUrl: downloadPageUrl,
      audioUrl: audioUrl,
      videoSize: videoSize,
      audioSize: audioSize,
    );

    if (!mounted) return;

    switch (result.status) {
      case InterceptDownloadStatus.alreadyCompleted:
        ThemedSnackbar.show(context,
            message: isRtl
                ? 'هذا التنزيل مكتمل بالفعل'
                : 'This download is already completed.',
            color: AppTheme.neonGreen,
            icon: Icons.check_circle_outline,
            isDarkMode: isDark);
      case InterceptDownloadStatus.alreadyInProgress:
        ThemedSnackbar.show(context,
            message: isRtl
                ? 'هذا التنزيل قيد التشغيل بالفعل'
                : 'This download is already in progress.',
            color: AppTheme.neonBlue,
            icon: Icons.info_outline,
            isDarkMode: isDark);
      case InterceptDownloadStatus.resumed:
        ThemedSnackbar.show(context,
            message: isRtl ? 'تم استئناف التنزيل' : 'Download resumed.',
            color: AppTheme.neonBlue,
            icon: Icons.play_arrow,
            isDarkMode: isDark);
      case InterceptDownloadStatus.queued:
        ThemedSnackbar.show(context,
            message: isRtl
                ? 'تم إنشاء الاتصال. القنوات متصلة.'
                : 'Download queued successfully.',
            color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
            icon: Icons.rocket_launch_outlined,
            isDarkMode: isDark);
      case InterceptDownloadStatus.failed:
        ThemedSnackbar.show(context,
            message: result.errorMessage ?? 'Download failed.',
            color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
            icon: Icons.error_outline,
            isDarkMode: isDark);
      case InterceptDownloadStatus.skipped:
        break;
    }
  }

  Future<void> _quitBrowser() async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    triggerHaptic(settings);
    try {
      final persistable = <SavedBrowserTab>[];
      var position = 0;
      for (var i = 0; i < _tabs.length; i++) {
        final t = _tabs[i];
        if (t.isIncognito) continue;
        persistable.add(
          SavedBrowserTab(
            id: t.id,
            url: t.url.isNotEmpty ? t.url : 'about:blank',
            title: t.title,
            isActive: i == _currentTabIndex,
            position: position++,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
      await context.read<DatabaseService>().saveOpenTabs(persistable);
      _quitPersisted = true;
    } catch (e) {
      _log.warning('[DMX Browser] Failed to persist tabs on quit: $e');
    }

    _teardownBrowserServices();

    if (!mounted) return;
    if (Navigator.canPop(context)) {
      Navigator.pop(context);
    } else {
      context.read<DownloadProvider>().setActiveTabIndex(0);
    }
  }

  void _teardownBrowserServices() {
    for (final timer in _pendingTimers) {
      timer.cancel();
    }
    _pendingTimers.clear();
    for (final timer in _mediaScanTimers.values) {
      timer.cancel();
    }
    _mediaScanTimers.clear();
    _detectedDownloadUrls.clear();
    _detectedPlaylistUrls.clear();
    _detectedMediaSources.clear();
    _ytDetectionFailed.clear();
    _lastYoutubeAuthTimes.clear();

    for (final tab in _tabs) {
      try {
        tab.dispose();
      } catch (e, st) {
        Logger('browser_screen')
            .warning('[browser_screen] operation failed', e, st);
      }
    }
    _tabs.clear();
    _currentTabIndex = 0;
    _quitPersisted = false;
  }
}

class _LiveDot extends StatefulWidget {
  final Color color;
  const _LiveDot({required this.color});
  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200));
    _c.forward().then((_) {
      if (mounted) {
        _c.reverse().then((_) {
          if (mounted) {
            _c.forward().then((_) {
              if (mounted) _c.reverse();
            });
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(alpha: 0.3 + _c.value * 0.4),
              blurRadius: 4 + _c.value * 4,
            ),
          ],
        ),
      ),
    );
  }
}

class _PulsingIconBadge extends StatefulWidget {
  final IconData icon;
  final Color color;
  final bool isDark;
  const _PulsingIconBadge(
      {required this.icon, required this.color, required this.isDark});
  @override
  State<_PulsingIconBadge> createState() => _PulsingIconBadgeState();
}

class _PulsingIconBadgeState extends State<_PulsingIconBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1600));
    _runTwoCycles();
  }

  void _runTwoCycles() {
    _c.forward().then((_) {
      if (mounted) {
        _c.reverse().then((_) {
          if (mounted) {
            _c.forward().then((_) {
              if (mounted) _c.reverse();
            });
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) => Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 44 + _c.value * 10,
            height: 44 + _c.value * 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: widget.color.withValues(alpha: 0.35 * (1 - _c.value)),
                width: 1.2,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: widget.color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(widget.icon, color: widget.color, size: 20),
          ),
        ],
      ),
    );
  }
}

class _CornerBracketBox extends StatelessWidget {
  final Widget child;
  final Color color;
  final bool isDark;
  const _CornerBracketBox(
      {required this.child, required this.color, required this.isDark});
  @override
  Widget build(BuildContext context) {
    final bracket = BorderSide(color: color.withValues(alpha: 0.6), width: 1.5);
    return Stack(
      children: [
        Container(
          width: double.infinity,
          margin: const EdgeInsets.all(6),
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: (isDark ? AppTheme.background : AppTheme.lightBackground)
                .withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color:
                    isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                width: 0.7),
          ),
          child: child,
        ),
        Positioned(
            top: 0,
            left: 0,
            child: _Corner(side: _CornerSide.tl, border: bracket)),
        Positioned(
            top: 0,
            right: 0,
            child: _Corner(side: _CornerSide.tr, border: bracket)),
        Positioned(
            bottom: 0,
            left: 0,
            child: _Corner(side: _CornerSide.bl, border: bracket)),
        Positioned(
            bottom: 0,
            right: 0,
            child: _Corner(side: _CornerSide.br, border: bracket)),
      ],
    );
  }
}

enum _CornerSide { tl, tr, bl, br }

class _Corner extends StatelessWidget {
  final _CornerSide side;
  final BorderSide border;
  const _Corner({required this.side, required this.border});
  @override
  Widget build(BuildContext context) {
    const s = 12.0;
    return CustomPaint(
        size: const Size(s, s),
        painter: _CornerPainter(side: side, border: border));
  }
}

class _CornerPainter extends CustomPainter {
  final _CornerSide side;
  final BorderSide border;
  _CornerPainter({required this.side, required this.border});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = border.toPaint();
    final w = size.width;
    final h = size.height;
    switch (side) {
      case _CornerSide.tl:
        canvas.drawLine(Offset(0, h), const Offset(0, 0), paint);
        canvas.drawLine(const Offset(0, 0), Offset(w, 0), paint);
        break;
      case _CornerSide.tr:
        canvas.drawLine(Offset(w, h), Offset(w, 0), paint);
        canvas.drawLine(Offset(w, 0), const Offset(0, 0), paint);
        break;
      case _CornerSide.bl:
        canvas.drawLine(const Offset(0, 0), Offset(0, h), paint);
        canvas.drawLine(Offset(0, h), Offset(w, h), paint);
        break;
      case _CornerSide.br:
        canvas.drawLine(Offset(w, 0), Offset(w, h), paint);
        canvas.drawLine(Offset(w, h), Offset(0, h), paint);
        break;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ScanlineProgress extends StatefulWidget {
  final double progress;
  final bool isDark;
  const _ScanlineProgress({required this.progress, required this.isDark});
  @override
  State<_ScanlineProgress> createState() => _ScanlineProgressState();
}

class _ScanlineProgressState extends State<_ScanlineProgress>
    with
        SingleTickerProviderStateMixin,
        WidgetsBindingObserver,
        PausableLoopAnimation<_ScanlineProgress> {
  late AnimationController _c;
  @override
  AnimationController get loopController => _c;
  bool _allowed = true;
  @override
  bool get loopWanted => _allowed;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    _allowed = modernAnimationsAllowed(context, respectSystemMotion: false);
    startPausableLoop();
  }

  @override
  void dispose() {
    stopPausableLoop();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final allowed = modernAnimationsAllowed(context, listen: true);
    if (allowed != _allowed) {
      _allowed = allowed;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) syncPausableLoop();
      });
    }

    if (!allowed) {
      return LinearProgressIndicator(
        value: widget.progress,
        minHeight: 3,
        backgroundColor: Colors.transparent,
        color: accent.withValues(alpha: 0.85),
      );
    }

    return SizedBox(
      height: 3,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) => Stack(
          children: [
            LinearProgressIndicator(
              value: widget.progress,
              minHeight: 3,
              backgroundColor: Colors.transparent,
              color: accent.withValues(alpha: 0.85),
            ),
            Positioned(
              left: (widget.progress *
                      MediaQuery.of(context).size.width *
                      _c.value) -
                  30,
              child: Container(
                width: 30,
                height: 3,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    Colors.transparent,
                    accent.withValues(alpha: 0.9)
                  ]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RadarSweep extends StatefulWidget {
  final Color color;
  final bool active;
  const _RadarSweep({required this.color, required this.active});
  @override
  State<_RadarSweep> createState() => _RadarSweepState();
}

class _RadarSweepState extends State<_RadarSweep>
    with
        SingleTickerProviderStateMixin,
        WidgetsBindingObserver,
        PausableLoopAnimation<_RadarSweep> {
  late AnimationController _c;
  @override
  AnimationController get loopController => _c;
  bool _allowed = true;
  @override
  bool get loopWanted => widget.active && _allowed;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 3));
    _allowed = modernAnimationsAllowed(context, respectSystemMotion: false);
    startPausableLoop();
  }

  @override
  void didUpdateWidget(_RadarSweep old) {
    super.didUpdateWidget(old);
    syncPausableLoop();
  }

  @override
  void dispose() {
    stopPausableLoop();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allowed = modernAnimationsAllowed(context, listen: true);
    if (allowed != _allowed) {
      _allowed = allowed;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) syncPausableLoop();
      });
    }

    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) => CustomPaint(
        size: const Size(72, 72),
        painter: _RadarPainter(
          sweep: allowed ? _c.value * 2 * pi : 0,
          color: widget.color,
          active: widget.active,
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  final double sweep;
  final Color color;
  final bool active;
  _RadarPainter(
      {required this.sweep, required this.color, required this.active});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2;
    final ringPaint = Paint()
      ..color = color.withValues(alpha: active ? 0.25 : 0.1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    for (final r in [maxR * 0.4, maxR * 0.7, maxR]) {
      canvas.drawCircle(center, r, ringPaint);
    }
    canvas.drawLine(Offset(center.dx - maxR, center.dy),
        Offset(center.dx + maxR, center.dy), ringPaint);
    canvas.drawLine(Offset(center.dx, center.dy - maxR),
        Offset(center.dx, center.dy + maxR), ringPaint);

    if (active) {
      final sweepPaint = Paint()
        ..shader = SweepGradient(
          startAngle: sweep - 0.9,
          endAngle: sweep,
          colors: [Colors.transparent, color.withValues(alpha: 0.35)],
        ).createShader(Rect.fromCircle(center: center, radius: maxR));
      canvas.drawArc(Rect.fromCircle(center: center, radius: maxR), sweep - 0.9,
          0.9, true, sweepPaint);

      final linePaint = Paint()
        ..color = color.withValues(alpha: 0.8)
        ..strokeWidth = 1.2;
      canvas.drawLine(
          center,
          Offset(center.dx + maxR * cos(sweep), center.dy + maxR * sin(sweep)),
          linePaint);

      final blipPaint = Paint()
        ..color = color.withValues(alpha: 0.7)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);
      canvas.drawCircle(
          Offset(center.dx + maxR * 0.55 * cos(sweep - 0.5),
              center.dy + maxR * 0.55 * sin(sweep - 0.5)),
          2,
          blipPaint);
      canvas.drawCircle(
          Offset(center.dx + maxR * 0.8 * cos(sweep - 1.2),
              center.dy + maxR * 0.8 * sin(sweep - 1.2)),
          1.5,
          blipPaint);
    }

    final dotPaint = Paint()
      ..color = color.withValues(alpha: active ? 0.9 : 0.3);
    canvas.drawCircle(center, 2.5, dotPaint);
  }

  @override
  bool shouldRepaint(covariant _RadarPainter old) =>
      old.sweep != sweep || old.active != active;
}

class _SnifferRadarCard extends StatelessWidget {
  final SettingsProvider settings;
  final bool isEnabled;
  final ValueChanged<bool> onToggle;
  const _SnifferRadarCard(
      {required this.settings,
      required this.isEnabled,
      required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final green = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final statusClr = isEnabled
        ? green
        : (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted);

    return GlassCard(
      borderRadius: 20,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      isDarkMode: isDark,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _RadarSweep(color: isEnabled ? green : accent, active: isEnabled),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isRtl ? 'كاشف الملفات (Sniffer)' : 'Stream sniffer',
                  style: TextStyle(
                      fontFamily: 'Space Grotesk',
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      letterSpacing: 0.3,
                      color: accent),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    _LiveDot(color: statusClr),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isEnabled
                            ? (isRtl
                                ? 'الاعتراض التلقائي نشط'
                                : 'AUTO-INTERCEPT ACTIVE')
                            : (isRtl
                                ? 'الاعتراض التلقائي متوقف'
                                : 'AUTO-INTERCEPT DEACTIVATED'),
                        style: TextStyle(
                            fontFamily: 'Space Grotesk',
                            fontWeight: FontWeight.w800,
                            color: isDark
                                ? AppTheme.textPrimary
                                : AppTheme.lightTextPrimary,
                            fontSize: 12.5,
                            letterSpacing: 0.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  isRtl
                      ? 'يكتشف روابط التحميل المباشرة والوسائط تلقائياً'
                      : 'Sniffs media files and documents dynamically',
                  style: TextStyle(
                      fontFamily: 'Inter',
                      color:
                          isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                      fontSize: 10.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Transform.scale(
            scale: 0.82,
            child: Switch(
              value: isEnabled,
              activeThumbColor: Colors.white,
              activeTrackColor: green,
              inactiveThumbColor:
                  isDark ? const Color(0xFF7F7F90) : const Color(0xFF94A3B8),
              inactiveTrackColor:
                  isDark ? const Color(0x1AFFFFFF) : const Color(0x0D000000),
              trackOutlineColor: WidgetStateProperty.resolveWith(
                  (states) => Colors.transparent),
              onChanged: onToggle,
            ),
          ),
        ],
      ),
    );
  }
}

class _SignalFab extends StatefulWidget {
  final Color color;
  final IconData icon;
  final String label;
  final bool pulse;
  final bool isDark;
  final VoidCallback onPressed;
  const _SignalFab(
      {required this.color,
      required this.icon,
      required this.label,
      required this.pulse,
      required this.isDark,
      required this.onPressed});
  @override
  State<_SignalFab> createState() => _SignalFabState();
}

class _SignalFabState extends State<_SignalFab>
    with
        SingleTickerProviderStateMixin,
        WidgetsBindingObserver,
        PausableLoopAnimation<_SignalFab> {
  late AnimationController _c;
  @override
  AnimationController get loopController => _c;
  bool _allowed = true;
  @override
  bool get loopWanted => widget.pulse && _allowed;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400));
    _allowed = modernAnimationsAllowed(context, respectSystemMotion: false);
    startPausableLoop();
  }

  @override
  void didUpdateWidget(_SignalFab old) {
    super.didUpdateWidget(old);
    syncPausableLoop();
  }

  @override
  void dispose() {
    stopPausableLoop();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allowed = modernAnimationsAllowed(context, listen: true);
    if (allowed != _allowed) {
      _allowed = allowed;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) syncPausableLoop();
      });
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        if (widget.pulse && allowed)
          AnimatedBuilder(
            animation: _c,
            builder: (context, child) => Container(
              width: 52 + _c.value * 22,
              height: 52 + _c.value * 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: widget.color.withValues(alpha: 0.5 * (1 - _c.value)),
                  width: 1.5,
                ),
              ),
            ),
          ),
        FloatingActionButton.extended(
          heroTag: null,
          backgroundColor: widget.color,
          foregroundColor: Colors.white,
          elevation: 4,
          onPressed: widget.onPressed,
          icon: Icon(widget.icon),
          label: Text(widget.label,
              style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                  fontFamily: 'Space Grotesk',
                  fontSize: 12)),
        ),
      ],
    );
  }
}

class _YouTubeGrabButton extends StatelessWidget {
  final bool isPlaylist;
  final bool isRtl;
  final bool isDark;
  final bool enableGlow;
  final VoidCallback onPressed;
  const _YouTubeGrabButton(
      {required this.isPlaylist,
      required this.isRtl,
      required this.isDark,
      required this.enableGlow,
      required this.onPressed});
  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.2),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.red, width: 1.2),
          boxShadow: enableGlow
              ? [
                  BoxShadow(
                      color: Colors.red.withValues(alpha: 0.4),
                      blurRadius: 6,
                      spreadRadius: 0.5)
                ]
              : null,
        ),
        child: Icon(
            isPlaylist ? Icons.playlist_play_rounded : Icons.download_rounded,
            size: 16,
            color: Colors.white),
      ),
      tooltip: isPlaylist
          ? (isRtl ? 'تحميل قائمة التشغيل' : 'Download Playlist')
          : (isRtl ? 'تحميل الفيديو' : 'Download Video'),
      onPressed: onPressed,
    );
  }
}

class _TabSwitcherAction extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;
  const _TabSwitcherAction(
      {required this.icon,
      required this.color,
      required this.tooltip,
      required this.onPressed});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onPressed,
        child: Tooltip(
          message: tooltip,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border:
                  Border.all(color: color.withValues(alpha: 0.25), width: 0.7),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
        ),
      ),
    );
  }
}

class _JsCssInjectorDialog extends StatefulWidget {
  final String initialJs;
  final String initialCss;
  final Function(String, String) onSave;
  const _JsCssInjectorDialog(
      {required this.initialJs,
      required this.initialCss,
      required this.onSave});
  @override
  State<_JsCssInjectorDialog> createState() => _JsCssInjectorDialogState();
}

class _JsCssInjectorDialogState extends State<_JsCssInjectorDialog> {
  late final TextEditingController _jsController;
  late final TextEditingController _cssController;
  int _activeTab = 0;

  @override
  void initState() {
    super.initState();
    _jsController = TextEditingController(text: widget.initialJs);
    _cssController = TextEditingController(text: widget.initialCss);
  }

  @override
  void dispose() {
    _jsController.dispose();
    _cssController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return AlertDialog(
      backgroundColor: (isDark ? AppTheme.surface : AppTheme.lightSurface)
          .withValues(alpha: 0.95),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Row(
        children: [
          Icon(Icons.code_rounded, color: accent, size: 20),
          const SizedBox(width: 10),
          Text(L10n.of(context, 'browser_js_css_injector'),
              style: TextStyle(
                  color: accent,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0)),
        ],
      ),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.85,
        height: 280,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed)
                        .withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                      size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      L10n.of(context, 'browser_js_css_warning'),
                      style: TextStyle(
                          color:
                              isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                          fontSize: 10,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _tabHeader(0, 'JavaScript')),
              Expanded(child: _tabHeader(1, 'CSS Style'))
            ]),
            const SizedBox(height: 12),
            Expanded(
              child: IndexedStack(
                index: _activeTab,
                children: [
                  _buildCodeEditor(
                      _jsController,
                      '// Write your Custom Javascript here\n// Automatically runs on page loads...',
                      isDark),
                  _buildCodeEditor(
                      _cssController,
                      '/* Write your Custom CSS here */\nbody {\n  /* background-color: #000; */\n}',
                      isDark),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(L10n.of(context, 'cancel_btn_uppercase'))),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: accent, foregroundColor: Colors.black),
          onPressed: () {
            widget.onSave(_jsController.text, _cssController.text);
            Navigator.pop(context);
          },
          child: Text(L10n.of(context, 'browser_apply_uppercase')),
        ),
      ],
    );
  }

  Widget _tabHeader(int index, String label) {
    final isSelected = _activeTab == index;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final accent =
        settings.isDarkMode ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    return GestureDetector(
      onTap: () {
        runHaptic(settings);
        setState(() {
          _activeTab = index;
        });
      },
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
            border: Border(
                bottom: BorderSide(
                    color: isSelected ? accent : Colors.transparent,
                    width: 2))),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected
                ? accent
                : (settings.isDarkMode
                    ? AppTheme.textSecondary
                    : AppTheme.lightTextSecondary),
            fontWeight: FontWeight.bold,
            fontSize: 12,
            fontFamily: 'Space Grotesk',
          ),
        ),
      ),
    );
  }

  Widget _buildCodeEditor(
      TextEditingController controller, String hint, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: (isDark ? AppTheme.background : AppTheme.lightBackground)
            .withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
            width: 0.8),
      ),
      child: TextField(
        controller: controller,
        maxLines: null,
        expands: true,
        keyboardType: TextInputType.multiline,
        style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(
              color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
              fontSize: 10),
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }
}
