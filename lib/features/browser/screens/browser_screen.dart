import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../../core/app_theme.dart';
import '../../../core/services/database/app_database.dart';
import '../../../core/services/database_service.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/services/user_script_manager.dart';
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/mixins/pausable_loop_animation.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../add_download/widgets/youtube_playlist_sheet.dart';
import '../../add_download/widgets/media_quality_sheet.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/bookmark.dart';
import '../models/browser_tab.dart';
import '../services/browser_detector.dart';
import '../services/ad_blocker_delegate.dart';
import '../services/download_interceptor.dart';
import '../services/element_picker_service.dart';
import '../services/history_manager.dart';
import '../services/long_press_parser.dart';
import '../services/media_sniffer.dart';
import '../services/reader_mode_service.dart';
import '../services/tab_manager.dart';
import '../services/redirect_guard.dart';
import '../screens/script_manager_screen.dart';
import '../widgets/bookmark_manager_screen.dart';
import '../widgets/browser_download_sheet.dart';
import '../widgets/browser_history_sheet.dart';
import '../widgets/browser_home_page.dart';
import '../widgets/redirect_sheet.dart';
import 'package:logging/logging.dart';

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});
  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen>
    with HapticHelper, WidgetsBindingObserver {
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
  List<BrowserTab> get _tabs => _tabManager.tabs;
  int get _currentTabIndex => _tabManager.currentIndex;
  set _currentTabIndex(int value) => _tabManager.currentIndex = value;
  final TextEditingController _urlController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _isFocused = false;
  bool _showBars = true;
  double _lastScrollY = 0;

  String _customJs = '';
  String _customCss = '';

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
  // Per-tab YouTube auth cooldown — prevents one tab's auth suppressing others.
  Map<String, DateTime> get _lastYoutubeAuthTimes =>
      _sniffer.lastYoutubeAuthTimes;
  static const _youtubeAuthCooldown = Duration(seconds: 30);
  Map<String, Timer> get _mediaScanTimers => _sniffer.mediaScanTimers;
  bool _quitPersisted = false;
  bool _isRestoring = false;
  final AdBlockerDelegate _adBlocker = AdBlockerDelegate();
  final RedirectGuard _redirectGuard = RedirectGuard.instance;

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

  static const String _kTimerSpeedScript = '''
(function() {
  if (window.__xdmTimerSpeed) return;
  window.__xdmTimerSpeed = true;
  const cap = 250;
  const origSetTimeout = window.setTimeout;
  const origSetInterval = window.setInterval;
  window.setTimeout = function(fn, delay) {
    return origSetTimeout.call(window, fn, (typeof delay === 'number' && delay > cap) ? cap : delay);
  };
  window.setInterval = function(fn, delay) {
    return origSetInterval.call(window, fn, (typeof delay === 'number' && delay > cap) ? cap : delay);
  };
})();
''';

  static const String _kLongPressScript = '''
(function() {
  if (window.__xdmLongPressBound) return;
  window.__xdmLongPressBound = true;
  let touchTimer = null;
  let startX = 0, startY = 0;
  function isMedia(el) {
    if (!el) return null;
    if (el.tagName === 'A' && el.href) {
      return { type: 'link', url: el.href, text: (el.innerText || el.href).slice(0, 200) };
    }
    if (el.tagName === 'IMG' && el.src) {
      return { type: 'image', url: el.src, text: (el.alt || el.src).slice(0, 200) };
    }
    if (el.tagName === 'VIDEO' && (el.src || el.currentSrc)) {
      return { type: 'video', url: el.src || el.currentSrc, text: (el.title || el.src).slice(0, 200) };
    }
    if (el.tagName === 'AUDIO' && (el.src || el.currentSrc)) {
      return { type: 'audio', url: el.src || el.currentSrc, text: (el.title || el.src).slice(0, 200) };
    }
    if (el.tagName === 'SOURCE' && el.src && el.parentElement) {
      const parent = el.parentElement;
      if (parent.tagName === 'VIDEO' || parent.tagName === 'AUDIO') {
        return { type: parent.tagName.toLowerCase(), url: el.src, text: '' };
      }
    }
    return null;
  }
  function notify(url, type, text) {
    if (window.XDM_LongPress) {
      window.XDM_LongPress.postMessage(JSON.stringify({ url: url, type: type, text: text }));
    }
  }
  document.addEventListener('contextmenu', function(e) {
    const target = isMedia(e.target);
    if (target) {
      e.preventDefault();
      notify(target.url, target.type, target.text);
    }
  }, true);
  document.addEventListener('touchstart', function(e) {
    if (e.touches.length !== 1) return;
    startX = e.touches[0].clientX;
    startY = e.touches[0].clientY;
    const target = isMedia(e.target);
    if (target) {
      touchTimer = setTimeout(function() {
        notify(target.url, target.type, target.text);
      }, 600);
    }
  }, { passive: true });
  document.addEventListener('touchend', function() {
    if (touchTimer) { clearTimeout(touchTimer); touchTimer = null; }
  }, true);
  document.addEventListener('touchmove', function(e) {
    if (!touchTimer) return;
    const dx = Math.abs(e.touches[0].clientX - startX);
    const dy = Math.abs(e.touches[0].clientY - startY);
    if (dx > 10 || dy > 10) {
      clearTimeout(touchTimer);
      touchTimer = null;
    }
  }, { passive: true });
})();
''';

  static const String _kDesktopModeScript = '''
(function() {
  if (window.__xdmDesktopModeInjected) return;
  window.__xdmDesktopModeInjected = true;
  try {
    let meta = document.querySelector('meta[name="viewport"]');
    if (!meta) {
      meta = document.createElement('meta');
      meta.name = 'viewport';
      if (document.head) document.head.appendChild(meta);
    }
    if (meta) {
      meta.content = 'width=1280, initial-scale=0.75, minimum-scale=0.25, maximum-scale=5.0, user-scalable=yes';
    }
  } catch(e) {}
  try {
    Object.defineProperty(window, 'outerWidth', { get: () => 1280, configurable: true });
    Object.defineProperty(screen, 'width', { get: () => 1280, configurable: true });
    Object.defineProperty(screen, 'availWidth', { get: () => 1280, configurable: true });
  } catch(e) {}
  try {
    Object.defineProperty(navigator, 'platform', { get: () => 'Win32', configurable: true });
  } catch(e) {}
  try {
    if (navigator.userAgentData) {
      Object.defineProperty(navigator, 'userAgentData', {
        get: () => ({
          brands: [
            { brand: 'Google Chrome', version: '131' },
            { brand: 'Chromium', version: '131' },
            { brand: 'Not_A Brand', version: '24' }
          ],
          mobile: false,
          platform: 'Windows',
          getHighEntropyValues: (hints) => Promise.resolve({
            architecture: 'x86',
            bitness: '64',
            brands: [
              { brand: 'Google Chrome', version: '131' },
              { brand: 'Chromium', version: '131' },
              { brand: 'Not_A Brand', version: '24' }
            ],
            mobile: false,
            model: '',
            platform: 'Windows',
            platformVersion: '15.0.0',
            uaFullVersion: '131.0.0.0'
          })
        }),
        configurable: true
      });
    }
  } catch(e) {}
})();
''';

  // ─────────────────────────────────────────────────────────────
  // Tab persistence
  // ─────────────────────────────────────────────────────────────
  Future<void> _saveTabs() => _tabManager.saveTabs();

  final List<String> _lruTabIds = [];
  final Map<String, Timer> _loadingTimeoutTimers = {};

  void _pauseTabMedia(BrowserTab tab) {
    if (!tab.isHome) {
      try {
        tab.controller.runJavaScript(
          "try { document.querySelectorAll('video,audio').forEach(function(m){m.pause();}); } catch(e){}",
        );
      } catch (e) {
        debugPrint('[Browser] Pause media on switch error: $e');
      }
    }
  }

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
    if (oldIndex >= 0 && oldIndex < _tabs.length && oldIndex != newIndex) {
      final oldTab = _tabs[oldIndex];
      _pauseTabMedia(oldTab);
    }
    if (newIndex >= 0 && newIndex < _tabs.length) {
      final newTab = _tabs[newIndex];
      if (!newTab.isHome &&
          newTab.url.isNotEmpty &&
          newTab.url != 'about:blank') {
        newTab.controller.currentUrl().then((currentUrl) {
          if (mounted &&
              (currentUrl == null ||
                  currentUrl.isEmpty ||
                  currentUrl == 'about:blank')) {
            try {
              newTab.controller.loadRequest(Uri.parse(newTab.url));
            } catch (e, st) {
              Logger('browser_screen')
                  .warning('[browser_screen] operation failed', e, st);
            }
          }
        }).catchError((_) {
          if (mounted) {
            try {
              newTab.controller.loadRequest(Uri.parse(newTab.url));
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
        _showBars = true;
      }
    });
    _onTabSwitched(oldIndex, newIndex);
    _saveTabs();
  }

  Future<void> _restoreTabs() async {
    assert(!_isRestoring, 'restoreTabs re-entered');
    if (_isRestoring) return;
    _isRestoring = true;
    try {
      await _tabManager.restoreTabs();
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
    WidgetsBinding.instance.addObserver(this);
    _focusNode.addListener(() {
      setState(() {
        _isFocused = _focusNode.hasFocus;
      });
      if (_focusNode.hasFocus) {
        _delayed(Duration.zero, () {
          if (_focusNode.hasFocus && mounted) {
            _urlController.selection = TextSelection(
              baseOffset: 0,
              extentOffset: _urlController.text.length,
            );
          }
        });
      }
    });
    _loadSnifferPref();
    _loadCustomJsCss();
    UserScriptManager.instance.load();
    _dashboardScrollController.addListener(_onDashboardScroll);
    _adBlocker.init();
    _redirectGuard.init();
    _resetInactivityTimer();
  }

  static const Duration _kInactivityDuration = Duration(minutes: 5);
  Timer? _inactivityTimer;
  bool _isHibernating = false;

  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    if (_isHibernating) {
      _isHibernating = false;
      debugPrint(
          '[BrowserWatchdog] Browser active — resuming inactivity watchdog.');
    }
    if (!mounted) return;
    _inactivityTimer = Timer(_kInactivityDuration, _onInactivityTimeout);
  }

  void _onInactivityTimeout() {
    if (!mounted || _isHibernating) return;
    _isHibernating = true;
    debugPrint(
      '[BrowserWatchdog] 5 minutes of inactivity reached. Cleaning up browser services & background tab resources to save RAM and battery.',
    );

    for (final tab in _tabs) {
      _pauseTabMedia(tab);
    }

    for (var i = 0; i < _tabs.length; i++) {
      if (i != _currentTabIndex) {
        final tab = _tabs[i];
        if (!tab.isHome) {
          try {
            tab.controller.runJavaScript('try { window.stop(); } catch(e){}');
          } catch (_) {}
        }
      }
    }

    _sniffer.cancelAllScanTimers();

    for (final timer in _loadingTimeoutTimers.values) {
      timer.cancel();
    }
    _loadingTimeoutTimers.clear();

    _saveTabs();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _resetInactivityTimer();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      for (final tab in _tabs) {
        _pauseTabMedia(tab);
      }
    }
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
    final controller = WebViewController();
    final tab = BrowserTab(
      id: tabId,
      controller: controller,
      url: cleanInitialUrl == 'about:blank' ? '' : cleanInitialUrl,
      title: cleanInitialUrl == 'about:blank'
          ? L10n.of(context, 'browser_new_tab')
          : cleanInitialUrl,
      isIncognito: isIncognito,
      isHome: cleanInitialUrl == 'about:blank',
    );
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel(
        _longPressChannel,
        onMessageReceived: (msg) => _handleLongPressMessageForTab(tab, msg),
      )
      ..addJavaScriptChannel(
        _popupsChannel,
        onMessageReceived: (msg) => _handlePopupMessageForTab(tab, msg),
      )
      ..addJavaScriptChannel(
        _pickerChannel,
        onMessageReceived: (msg) => _handlePickerMessageForTab(tab, msg),
      )
      ..setUserAgent(
        _resolveUserAgent(isIncognito: tab.isIncognito, settings: settings),
      )
      ..enableZoom(settings.desktopMode || settings.pinchToZoom)
      ..setNavigationDelegate(
        NavigationDelegate(
          onWebResourceError: (WebResourceError error) {
            debugPrint(
              '[Browser] WebResourceError on tab ${tab.id}: ${error.description}',
            );
            if (mounted && error.isForMainFrame == true) {
              setState(() {
                tab.isLoading = false;
                tab.hasCrashed = true;
              });
            }
          },
          onPageStarted: (url) {
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
              tab.controller.setUserAgent(
                'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
              );
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
                tab.url = _cleanUrl(url);
                if (url != 'about:blank') {
                  tab.isHome = false;
                }
                _showBars = true;
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
            _injectTimerSpeedScript(tab);
            _adBlocker.injectAntiDetect(tab);
            _adBlocker.injectEarly(tab);
            _injectLongPressScriptToTab(tab);
            _injectCustomJsCss(tab);
            _injectDesktopModeScript(tab, settings);
            _updateNavState();
            _delayed(const Duration(milliseconds: 500), _updateNavState);
          },
          onPageFinished: (url) {
            _loadingTimeoutTimers[tab.id]?.cancel();
            _injectDesktopModeScript(tab, settings);
            _adBlocker.injectInto(tab);
            _injectUserScripts(tab, url);
            if (mounted) {
              setState(() {
                tab.isLoading = false;
                tab.isTimedOut = false;
                _detectedDownloadUrls.remove(tab.id);
                _detectedMediaSources.remove(tab.id);
              });
              tab.controller.getTitle().then((t) {
                if (t != null && t.isNotEmpty && mounted) {
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
              tab.controller.runJavaScript('''
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
            _mediaScanTimers[tab.id]?.cancel();
            if (!_isYoutubeHost(tab.url)) {
              _mediaScanTimers[tab.id] = Timer(
                const Duration(milliseconds: 1500),
                () {
                  _scanPageMedia(tab);
                },
              );
            }
          },
          onProgress: (progress) {
            tab.progress = progress / 100;
          },
          onUrlChange: (change) {
            if (change.url != null) {
              final cleanUrl = _cleanUrl(change.url!);
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
                _mediaScanTimers[tab.id]?.cancel();
                if (!_isYoutubeHost(tab.url)) {
                  _mediaScanTimers[tab.id] = Timer(
                    const Duration(milliseconds: 1500),
                    () {
                      _scanPageMedia(tab);
                    },
                  );
                }
                _delayed(const Duration(milliseconds: 1000), () {
                  if (mounted) {
                    tab.controller.getTitle().then((t) {
                      if (t != null && t.isNotEmpty && mounted) {
                        setState(() {
                          tab.title = t;
                        });
                      }
                    });
                  }
                });
                _updateNavState();
                _delayed(const Duration(milliseconds: 500), _updateNavState);
                _delayed(const Duration(milliseconds: 1200), _updateNavState);
              }
            }
          },
          onNavigationRequest: (NavigationRequest request) {
            if (settings.httpsOnly &&
                request.isMainFrame == true &&
                request.url.startsWith('http://')) {
              final upgraded = request.url.replaceFirst('http://', 'https://');
              debugPrint(
                  '[Browser] HTTPS-only: upgrading ${request.url} ? $upgraded');
              tab.controller.loadRequest(Uri.parse(upgraded));
              return NavigationDecision.prevent;
            }
            if (_adBlocker.shouldBlock(request.url)) {
              debugPrint('[AdBlocker] Blocked: ${request.url}');
              return NavigationDecision.prevent;
            }
            if (_interceptor.consumeBypass(request.url)) {
              return NavigationDecision.navigate;
            }
            if (_interceptor.shouldIntercept(
              tabUrl: tab.url,
              requestUrl: request.url,
            )) {
              setState(() {
                _detectedDownloadUrls[tab.id] = request.url;
              });
              _showInterceptionSheet(context, request.url);
              return NavigationDecision.prevent;
            }
            if (_redirectGuard.consumeUserInitiated(request.url)) {
              return NavigationDecision.navigate;
            }
            if (_redirectGuard.isAlwaysNewTab(request.url)) {
              _openInNewTab(request.url, isIncognito: tab.isIncognito);
              return NavigationDecision.prevent;
            }
            if (_redirectGuard.isSuspiciousRedirect(
              currentTabUrl: tab.url,
              targetUrl: request.url,
            )) {
              _handleRedirectIntercept(tab, request.url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..setOnScrollPositionChange((ScrollPositionChange change) {
        if (mounted &&
            _currentTabIndex >= 0 &&
            _currentTabIndex < _tabs.length &&
            _tabs[_currentTabIndex].id == tab.id) {
          _handleScroll(change.y.toDouble());
        }
      });

    if (autoLoad && cleanInitialUrl != 'about:blank') {
      controller.loadRequest(Uri.parse(cleanInitialUrl));
    }
    return tab;
  }

  void _recordHistory(String url, {String? title}) =>
      _historyManager.recordHistory(url, title: title);

  // Domains where injecting the timer-speed and long-press scripts is safe.
  // Restricting to media-heavy sites prevents breaking banking, auth, and
  // WebSocket-heavy apps that rely on accurate timer intervals.
  static const _kMediaDomains = [
    'youtube.com',
    'youtu.be',
    'vimeo.com',
    'dailymotion.com',
    'twitch.tv',
    'bilibili.com',
    'tiktok.com',
    'instagram.com',
    'facebook.com',
    'twitter.com',
    'x.com',
    'reddit.com',
    'streamable.com',
    'rumble.com',
    'odysee.com',
    'peertube',
  ];

  bool _isMediaDomain(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    return _kMediaDomains.any((d) => host.contains(d));
  }

  static bool _isYoutubeHost(String url) => MediaSniffer.isYoutubeHost(url);

  Future<void> _injectTimerSpeedScript(BrowserTab tab) async {
    if (!mounted) return;
    // Only inject on known media-heavy domains to avoid breaking timers on
    // banking, WebSocket, and session-management pages.
    if (!_isMediaDomain(tab.url)) return;
    try {
      await tab.controller.runJavaScript(_kTimerSpeedScript);
    } catch (e) {
      debugPrint('[DMX Browser] Failed to inject timer speed script: $e');
    }
  }

  Future<void> _injectLongPressScriptToTab(BrowserTab tab) async {
    if (!mounted) return;
    // Only override contextmenu on known media sites — prevents breaking
    // right-click / context menus on banking and productivity pages.
    if (!_isMediaDomain(tab.url)) return;
    try {
      await tab.controller.runJavaScript(_kLongPressScript);
    } catch (e) {
      debugPrint('[DMX Browser] Failed to inject long press script: $e');
    }
  }

  /// Removes all per-tab state when a tab is closed or navigated away.
  /// Call this from every tab-close path to prevent unbounded map growth.
  void _cleanupTabState(String tabId) => _sniffer.cleanupTab(tabId);

  static const _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  static const _mobileUserAgent =
      'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
  static const _incognitoUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
      'Mobile/15E148 Safari/604.1';

  String _resolveUserAgent({
    required bool isIncognito,
    required SettingsProvider settings,
  }) {
    if (settings.desktopMode) return _desktopUserAgent;
    if (isIncognito) return _incognitoUserAgent;
    if (settings.customUserAgent.isNotEmpty) return settings.customUserAgent;
    return _mobileUserAgent;
  }

  Future<void> _applyUserAgent(
    BrowserTab tab,
    SettingsProvider settings,
  ) async {
    try {
      await tab.controller.setUserAgent(
        _resolveUserAgent(isIncognito: tab.isIncognito, settings: settings),
      );
    } catch (e) {
      debugPrint('[DMX Browser] UA apply failed for tab ${tab.id}: $e');
    }
  }

  void _injectDesktopModeScript(BrowserTab tab, SettingsProvider settings) {
    if (!settings.desktopMode) return;
    try {
      tab.controller.runJavaScript(_kDesktopModeScript);
    } catch (e) {
      debugPrint('[DMX Browser] Error injecting desktop script: $e');
    }
  }

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
      debugPrint(
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
    if (_adBlocker.shouldBlock(url)) {
      debugPrint('[AdBlocker] Blocked popup: $url');
      return;
    }
    debugPrint('[Browser] Opening popup in new tab: $url');
    _redirectGuard.markUserInitiated(url);
    setState(() {
      final newTab = _createNewTab(
        initialUrl: url,
        isIncognito: parentTab.isIncognito,
      );
      _tabs.add(newTab);
      _currentTabIndex = _tabs.length - 1;
      _urlController.text = url;
      _showBars = true;
    });
    _saveTabs();
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
      debugPrint('[DMX Browser] Failed to decode picker message: $e');
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
        title: const Text('Block element'),
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
            child: const Text('CANCEL'),
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
                  message: 'Element blocked: $selector',
                  color: accent,
                  icon: Icons.block,
                  isDarkMode: settings.isDarkMode,
                );
                if (!tab.isHome) {
                  await tab.controller.reload();
                }
              }
            },
            child: const Text('BLOCK'),
          ),
        ],
      ),
    );
  }

  void _openInNewTab(String url,
      {bool isIncognito = false, bool switchToTab = false}) {
    if (!mounted || url.isEmpty) return;
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
        _showBars = true;
      }
    });
    _saveTabs();
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
        parentTab.controller.loadRequest(Uri.parse(targetUrl));
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
    if (y <= 0) {
      if (!_showBars) {
        setState(() {
          _showBars = true;
        });
        downloadProvider.setNavbarVisible(true);
      }
      _lastScrollY = y;
    } else if (y - _lastScrollY > 40) {
      if (_showBars) {
        setState(() {
          _showBars = false;
        });
        downloadProvider.setNavbarVisible(false);
      }
      _lastScrollY = y;
    } else if (_lastScrollY - y > 40) {
      if (!_showBars) {
        setState(() {
          _showBars = true;
        });
        downloadProvider.setNavbarVisible(true);
      }
      _lastScrollY = y;
    }
  }

  void _delayed(Duration duration, VoidCallback callback) =>
      _tabManager.delayed(duration, callback);

  @override
  void dispose() {
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
    // Clean up ALL per-tab state maps
    for (final tab in _tabs) {
      _cleanupTabState(tab.id);
    }
    for (final tab in _tabs) {
      if (tab.isIncognito) {
        try {
          tab.controller.clearCache();
          tab.controller.clearLocalStorage();
        } catch (e) {
          // ignore
        }
      }
      try {
        tab.progressNotifier.dispose();
      } catch (e) {
        // ignore
      }
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
      debugPrint('[DMX Browser] Failed to load sniffer preference: $e');
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
      debugPrint('[DMX Browser] Failed to save sniffer preference: $e');
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
      debugPrint('[DMX Browser] Failed to load custom JS/CSS: $e');
    }
  }

  Future<void> _updateNavState() async {
    if (!mounted || _tabs.isEmpty) return;
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
    final activeTab = _tabs[_currentTabIndex];
    if (activeTab.isHome && _homeReturnUrl != null) return;
    try {
      final canBack = await activeTab.controller.canGoBack();
      final canForward = await activeTab.controller.canGoForward();
      final currentUrl = await activeTab.controller.currentUrl();
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
    } catch (e) {
      // ignore
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
      unawaited(activeTab.controller.goBack());
      _updateNavState();
    } else if (!activeTab.isHome && activeTab.url.isNotEmpty) {
      if (mounted) {
        _homeReturnUrl = activeTab.url;
        setState(() {
          activeTab.isHome = true;
          activeTab.url = '';
          activeTab.canGoBack = false;
          activeTab.canGoForward = true;
          _urlController.clear();
        });
        // Clear the WebView so stale page content doesn't flash when the
        // user navigates to a new page from the Home dashboard.
        activeTab.controller.loadRequest(Uri.parse('about:blank'));
      }
    }
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
    unawaited(activeTab.controller.goForward());
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
      // Valid URI scheme
    } else if (url.contains(' ') || !url.contains('.')) {
      url = '$searchPrefix${Uri.encodeComponent(input)}';
    } else {
      url = 'https://$url';
    }
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
    final activeTab = _tabs[_currentTabIndex];
    setState(() {
      activeTab.isHome = false;
    });
    final parsed = Uri.tryParse(url);
    if (parsed != null) {
      activeTab.controller.loadRequest(parsed);
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
          await activeTab.controller.reload();
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
          debugPrint('[DMX Browser] Failed to save bookmark: $e');
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
                await t.controller.enableZoom(
                  settings.desktopMode || settings.pinchToZoom,
                );
              } catch (e, st) {
                Logger('browser_screen')
                    .warning('[browser_screen] operation failed', e, st);
              }
            }),
          );
          for (final t in _tabs) {
            if (!t.isHome) {
              try {
                await t.controller.reload();
              } catch (e) {
                debugPrint('[DMX Browser] Reload failed after mode switch: $e');
              }
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
            await activeTab.controller.reload();
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
          if (settings.incognitoEnabled) {
            final cookieManager = WebViewCookieManager();
            await cookieManager.clearCookies();
            for (final t in _tabs) {
              await t.controller.clearCache();
              await t.controller.clearLocalStorage();
            }
          }
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
    final ok = await ReaderModeService.activateReaderMode(
      activeTab.controller,
      (htmlUrl) {
        if (mounted) {
          activeTab.controller
              .loadRequest(Uri.parse(htmlUrl))
              .catchError((e, st) {
            Logger('browser_screen')
                .warning('[browser_screen] reader mode load failed', e, st);
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
          .runJavaScript(ElementPickerService.pickerScript);
    } catch (e) {
      debugPrint('[DMX Browser] Failed to start element picker: $e');
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

    // Build the multi-source list: the long-pressed URL first, then the
    // discovered alternative sources that belong to the same media.
    final discovered = (_detectedMediaSources[tab.id] ?? [])
        .map(MediaSourceItem.fromMap)
        .toList();
    final sources = filterSourcesForTarget(discovered, url, type);

    BrowserDownloadSheet.show(
      context,
      url,
      type: type,
      text: text,
      downloadPageUrl: tab.isHome ? null : tab.url,
      onQuality: hasMultipleQualities
          ? () => _showQualityPicker(tab.id, fallbackUrl: url)
          : null,
      sources: sources,
    );
  }

  // ─────────────────────────────────────────────────────────────
  // INTERCEPTION SHEET — targeting-reticle design
  // ─────────────────────────────────────────────────────────────
  void _showInterceptionSheet(BuildContext context, String downloadUrl) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    triggerHaptic(settings);
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
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
                        // Header with pulsing radar icon
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
                        // URL readout with corner brackets
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
                                  if (_currentTabIndex >= 0 &&
                                      _currentTabIndex < _tabs.length) {
                                    final activeTab = _tabs[_currentTabIndex];
                                    _interceptor.addBypass(downloadUrl);
                                    activeTab.controller.loadRequest(
                                      Uri.parse(downloadUrl),
                                    );
                                  }
                                },
                                child: Text(
                                  L10n.of(context, 'browser_continue_browsing'),
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

  // DOM Page Media Scanner
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

  Future<void> _hideWebViewFingerprints(BrowserTab tab) async {
    const js = r'''
(function() {
  try {
    Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
    delete window.WebViewJavascriptBridge;
    delete window.flutter_inappwebview;
    Object.defineProperty(navigator, 'plugins', {
      get: () => [
        { name: 'Chrome PDF Plugin', filename: 'internal-pdf-viewer' },
        { name: 'Chrome PDF Viewer', filename: 'mhjfbmdgcfjbbpaeojofohoefgiehjai' },
        { name: 'Native Client', filename: 'internal-nacl-plugin' },
      ],
    });
    Object.defineProperty(navigator, 'languages', { get: () => ['en-US', 'en'] });
  } catch(e) {}
})();
''';
    try {
      await tab.controller.runJavaScript(js);
    } catch (e) {
      debugPrint('Failed to inject anti-detection JS: $e');
    }
  }

  Future<void> _injectCustomJsCss(BrowserTab tab) async {
    if (!mounted || tab.isHome) return;
    if (_customJs.isNotEmpty) {
      try {
        final jsWrapper = """
if (!window._xdmCustomJsInjected) {
  window._xdmCustomJsInjected = true;
  (function() {
$_customJs
  })();
}
""";
        await tab.controller.runJavaScript(jsWrapper);
      } catch (e) {
        debugPrint('[DMX Browser] Failed to inject custom JS: $e');
      }
    }
    if (_customCss.isNotEmpty) {
      try {
        final jsonCss = jsonEncode(_customCss);
        final cssScript = """
(function() {
  var style = document.getElementById('xdm-custom-css');
  if (!style) {
    style = document.createElement('style');
    style.id = 'xdm-custom-css';
    document.head.appendChild(style);
  }
  style.textContent = $jsonCss;
})();
""";
        await tab.controller.runJavaScript(cssScript);
      } catch (e) {
        debugPrint('[DMX Browser] Failed to inject custom CSS: $e');
      }
    }
  }

  Future<void> _injectUserScripts(BrowserTab tab, String url) async {
    if (!mounted || tab.isHome || url.isEmpty) return;
    final manager = UserScriptManager.instance;
    if (manager.scripts.isEmpty) return;

    final matches = manager.scriptsForUrl(url);
    for (final script in matches) {
      try {
        if (script.isCss) {
          final jsonCss = jsonEncode(script.code);
          final cssScript = """
(function() {
  var style = document.getElementById('xdm-user-css');
  if (!style) {
    style = document.createElement('style');
    style.id = 'xdm-user-css';
    document.head.appendChild(style);
  }
  style.textContent = $jsonCss;
})();
""";
          await tab.controller.runJavaScript(cssScript);
        } else {
          final marker =
              'xdm_user_script_${script.id.replaceAll(RegExp('[^A-Za-z0-9_]'), '_')}';
          final jsWrapper = """
if (!window['$marker']) {
  window['$marker'] = true;
  (function() {
${script.code}
  })();
}
""";
          await tab.controller.runJavaScript(jsWrapper);
        }
      } catch (e) {
        debugPrint(
          '[DMX Browser] Failed to inject user script "${script.name}": $e',
        );
      }
    }
  }

  Future<void> _savePageOffline(BrowserTab tab) async {
    if (tab.isHome) return;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    triggerHaptic(settings);
    try {
      final result = await tab.controller.runJavaScriptReturningResult(
        "document.documentElement.outerHTML",
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
          title: const Text('Tab Limit Reached (10 Max)'),
          content: const Text(
            'You have reached the limit of 10 tabs. Would you like to close inactive tabs to open a new one?',
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
                      _showBars = true;
                    });
                    _saveTabs();
                  });
                  Navigator.pop(switcherContext);
                }
              },
              child: const Text('Close Oldest Inactive'),
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
                    _showBars = true;
                  });
                  _saveTabs();
                });
                Navigator.pop(switcherContext);
              },
              child: const Text('Close All Other Tabs'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
  }

  // ─────────────────────────────────────────────────────────────
  // TAB SWITCHER — grid with incognito styling
  // ─────────────────────────────────────────────────────────────
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
            return DraggableScrollableSheet(
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
                        color:
                            (isDark ? AppTheme.surface : AppTheme.lightSurface)
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
                                      borderRadius: BorderRadius.circular(10),
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
                                      borderRadius: BorderRadius.circular(8),
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
                                        _showBars = true;
                                        _updateLruOrder();
                                      });
                                      _onTabSwitched(oldIdx, _currentTabIndex);
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
                                        _showBars = true;
                                        _updateLruOrder();
                                      });
                                      _onTabSwitched(oldIdx, _currentTabIndex);
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
                                  final isActive = index == _currentTabIndex;
                                  final tabClr =
                                      tab.isIncognito ? violet : accent;
                                  return GestureDetector(
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
                                                ? const Color(0xFF16121F)
                                                : const Color(0xFFF3EEFA))
                                            : (isDark
                                                ? AppTheme.cardBg
                                                : AppTheme.lightCardBg),
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(
                                          color: isActive
                                              ? tabClr.withValues(alpha: 0.8)
                                              : tabClr.withValues(alpha: 0.15),
                                          width: isActive ? 1.5 : 0.8,
                                        ),
                                        boxShadow: isActive
                                            ? [
                                                BoxShadow(
                                                  color: tabClr.withValues(
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
                                          // Tab header strip
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 8,
                                            ),
                                            decoration: BoxDecoration(
                                              color: tabClr.withValues(
                                                alpha: isActive ? 0.12 : 0.05,
                                              ),
                                              borderRadius:
                                                  const BorderRadius.vertical(
                                                top: Radius.circular(15),
                                              ),
                                            ),
                                            child: Row(
                                              children: [
                                                Icon(
                                                  tab.isIncognito
                                                      ? Icons
                                                          .visibility_off_rounded
                                                      : Icons.language_rounded,
                                                  size: 13,
                                                  color: tabClr,
                                                ),
                                                const Spacer(),
                                                GestureDetector(
                                                  onTap: () {
                                                    triggerHaptic(settings);
                                                    setModalState(() {
                                                      setState(() {
                                                        // Centralised cleanup of all per-tab state.
                                                        _cleanupTabState(
                                                          tab.id,
                                                        );
                                                        tab.dispose();
                                                        _tabs.removeAt(index);
                                                        if (_currentTabIndex >=
                                                            _tabs.length) {
                                                          _currentTabIndex =
                                                              _tabs.length - 1;
                                                        }
                                                        if (_tabs.isEmpty) {
                                                          _tabs.add(
                                                            _createNewTab(),
                                                          );
                                                          _currentTabIndex = 0;
                                                        }
                                                        final activeTab = _tabs[
                                                            _currentTabIndex];
                                                        _urlController.text =
                                                            activeTab.isHome
                                                                ? ''
                                                                : activeTab.url;
                                                      });
                                                      _saveTabs();
                                                    });
                                                  },
                                                  child: Icon(
                                                    Icons.close_rounded,
                                                    size: 15,
                                                    color: isDark
                                                        ? AppTheme.textMuted
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
                                                  const EdgeInsets.symmetric(
                                                horizontal: 10,
                                              ),
                                              child: Text(
                                                tab.title.isEmpty
                                                    ? 'New Tab'
                                                    : tab.title,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: isDark
                                                      ? AppTheme.textPrimary
                                                      : AppTheme
                                                          .lightTextPrimary,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                            ),
                                            child: Text(
                                              tab.isHome
                                                  ? 'Dashboard'
                                                  : tab.url,
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
                                          ),
                                          const SizedBox(height: 10),
                                        ],
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
                );
              },
            );
          },
        );
      },
    );
  }

  // ─────────────────────────────────────────────────────────────
  // HOME DASHBOARD — radar, live stats, speed dial
  // ─────────────────────────────────────────────────────────────
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

          // ── Sniffer Radar Card ──
          _SnifferRadarCard(
            settings: settings,
            isEnabled: _isSnifferEnabled,
            onToggle: (val) {
              triggerHaptic(settings);
              _setSnifferEnabled(val);
            },
          ),
          const SizedBox(height: 16),

          // ── Live Engine Stats ──
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

          // ── Central Search Bar ──
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

          // ── Search Engine Selector ──
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

          // ── Speed Dial ──
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
        tab.controller.enableZoom(settings.pinchToZoom);
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
          final canGoBack = await activeTab.controller.canGoBack();
          if (canGoBack) {
            await _goBack();
          } else {
            downloadProvider.setActiveTabIndex(0);
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
                // ── Cockpit URL Bar ──
                RepaintBoundary(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeInOut,
                    height: _showBars ? (kToolbarHeight + statusBarHeight) : 0,
                    clipBehavior: Clip.hardEdge,
                    decoration: const BoxDecoration(),
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
                              // Address bar with security readout
                              Expanded(
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  height: 38,
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? (_isFocused
                                            ? const Color(0xFF141424)
                                            : const Color(0xFF0F0F16))
                                        : (_isFocused
                                            ? AppTheme.lightNeonBlue.withValues(
                                                alpha: 0.08,
                                              )
                                            : const Color(0xFFF1F5F9)),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: _isFocused
                                          ? (isDark
                                                  ? AppTheme.neonBlue
                                                  : AppTheme.lightNeonBlue)
                                              .withValues(alpha: 0.5)
                                          : (isDark
                                              ? const Color(0x15FFFFFF)
                                              : const Color(0x0D000000)),
                                      width: _isFocused ? 1.2 : 0.8,
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
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
                                  child: Row(
                                    children: [
                                      // Security / mode indicator
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                        ),
                                        child: Icon(
                                          activeTab.isIncognito
                                              ? Icons.visibility_off_rounded
                                              : activeTab.isHome
                                                  ? Icons.search_rounded
                                                  : activeTab.url
                                                          .startsWith('https')
                                                      ? Icons.lock_rounded
                                                      : Icons
                                                          .info_outline_rounded,
                                          size: 14,
                                          color: activeTab.isIncognito
                                              ? (isDark
                                                  ? AppTheme.neonViolet
                                                  : AppTheme.lightNeonViolet)
                                              : activeTab.url
                                                      .startsWith('https')
                                                  ? (isDark
                                                      ? AppTheme.neonGreen
                                                      : AppTheme.lightNeonGreen)
                                                  : _isFocused
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
                                                color: textClr,
                                                fontSize: 13,
                                              ),
                                              decoration: InputDecoration(
                                                isDense: true,
                                                suffixIcon: IconButton(
                                                  padding: EdgeInsets.zero,
                                                  constraints:
                                                      const BoxConstraints(
                                                    minWidth: 32,
                                                    minHeight: 32,
                                                  ),
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
                                                          .runJavaScript(
                                                        'window.stop();',
                                                      );
                                                      setState(() {
                                                        activeTab.isLoading =
                                                            false;
                                                      });
                                                    } else if (_isFocused &&
                                                        value.text.isNotEmpty) {
                                                      _urlController.clear();
                                                    } else {
                                                      if (!activeTab.isHome) {
                                                        activeTab.controller
                                                            .reload();
                                                      }
                                                    }
                                                  },
                                                ),
                                                suffixIconConstraints:
                                                    const BoxConstraints(
                                                  minWidth: 32,
                                                  minHeight: 32,
                                                ),
                                                hintText: isRtl
                                                    ? 'ابحث أو ادخل الرابط...'
                                                    : 'Search or enter URL...',
                                                hintStyle: TextStyle(
                                                  color: isDark
                                                      ? AppTheme.textMuted
                                                      : AppTheme.lightTextMuted,
                                                  fontSize: 11,
                                                ),
                                                filled: false,
                                                border: InputBorder.none,
                                                enabledBorder: InputBorder.none,
                                                focusedBorder: InputBorder.none,
                                                contentPadding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 4,
                                                  vertical: 6,
                                                ),
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
                              // YouTube grab button
                              if (!activeTab.isHome &&
                                  (YoutubeService.isYoutubeVideoUrl(
                                        activeTab.url,
                                      ) ||
                                      YoutubeService.isPlaylistUrl(
                                        activeTab.url,
                                      ))) ...[
                                _YouTubeGrabButton(
                                  isPlaylist: YoutubeService.isPlaylistUrl(
                                    activeTab.url,
                                  ),
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
                              // Tab counter
                              GestureDetector(
                                onTap: () {
                                  triggerHaptic(settings);
                                  _showTabSwitcher(context);
                                },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                  ),
                                  width: 26,
                                  height: 26,
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: textClr,
                                      width: 1.8,
                                    ),
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
                              ),
                              PopupMenuButton<String>(
                                icon: Icon(
                                  Icons.more_vert,
                                  size: 18,
                                  color: textClr,
                                ),
                                color: (isDark
                                    ? AppTheme.surface
                                    : AppTheme.lightSurface),
                                onSelected: (value) async {
                                  triggerHaptic(settings);
                                  await _handleMenuAction(value);
                                },
                                itemBuilder: (_) => [
                                  _menuItem(
                                    Icons.refresh,
                                    'Reload',
                                    'reload',
                                    textClr,
                                  ),
                                  _menuItem(
                                    Icons.bookmark_add_outlined,
                                    'Bookmark this page',
                                    'bookmark',
                                    textClr,
                                  ),
                                  _menuItem(
                                    Icons.bookmarks_outlined,
                                    'Bookmarks Manager',
                                    'show_bookmarks',
                                    textClr,
                                  ),
                                  _menuItem(
                                    Icons.history,
                                    'Browser History',
                                    'show_history',
                                    textClr,
                                  ),
                                  _menuItem(
                                    Icons.copy,
                                    'Copy URL',
                                    'copy',
                                    textClr,
                                  ),
                                  _menuItem(
                                    Icons.share,
                                    'Share URL',
                                    'share',
                                    textClr,
                                  ),
                                  _menuItem(
                                    Icons.save_alt,
                                    'Save Page Offline',
                                    'offline',
                                    textClr,
                                  ),
                                  _menuItem(
                                    Icons.menu_book_outlined,
                                    'Reader Mode',
                                    'reader',
                                    textClr,
                                  ),
                                  _menuItem(
                                    Icons.code,
                                    'Inject JS / CSS',
                                    'injector',
                                    textClr,
                                  ),
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
                                  _menuItem(
                                    Icons.touch_app_outlined,
                                    'Block Element',
                                    'picker',
                                    textClr,
                                  ),
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
                // ── Scanline loading progress ──
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
                // Main browser view
                Expanded(
                  child: Stack(
                    children: [
                      GestureDetector(
                        onTap: () => _focusNode.unfocus(),
                        behavior: HitTestBehavior.translucent,
                        child: _tabs.isEmpty
                            ? const SizedBox.shrink()
                            : Builder(
                                builder: (context) {
                                  _updateLruOrder();
                                  return IndexedStack(
                                    index: _currentTabIndex >= 0 &&
                                            _currentTabIndex < _tabs.length
                                        ? _currentTabIndex
                                        : 0,
                                    children:
                                        _tabs.asMap().entries.map((entry) {
                                      final tabIndex = entry.key;
                                      final tab = entry.value;
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
                                                      MainAxisAlignment.center,
                                                  children: [
                                                    Icon(
                                                      Icons.web,
                                                      size: 48,
                                                      color: (isDark
                                                              ? AppTheme
                                                                  .neonBlue
                                                              : AppTheme
                                                                  .lightNeonBlue)
                                                          .withValues(
                                                              alpha: 0.6),
                                                    ),
                                                    const SizedBox(height: 12),
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
                                                            : Colors.black87,
                                                      ),
                                                      textAlign:
                                                          TextAlign.center,
                                                    ),
                                                    if (tab.url.isNotEmpty) ...[
                                                      const SizedBox(height: 4),
                                                      Padding(
                                                        padding:
                                                            const EdgeInsets
                                                                .symmetric(
                                                          horizontal: 24,
                                                        ),
                                                        child: Text(
                                                          tab.domain.isNotEmpty
                                                              ? tab.domain
                                                              : tab.url,
                                                          style: TextStyle(
                                                            fontSize: 12,
                                                            color: isDark
                                                                ? Colors.white54
                                                                : Colors
                                                                    .black54,
                                                          ),
                                                          maxLines: 1,
                                                          overflow: TextOverflow
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
                                            child: RefreshIndicator(
                                              color: isDark
                                                  ? AppTheme.neonBlue
                                                  : AppTheme.lightNeonBlue,
                                              onRefresh: () async {
                                                tab.hasCrashed = false;
                                                await tab.controller.reload();
                                              },
                                              child: tab.hasCrashed
                                                  ? Container(
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
                                                            const Icon(
                                                              Icons
                                                                  .error_outline_rounded,
                                                              size: 54,
                                                              color: Colors
                                                                  .orangeAccent,
                                                            ),
                                                            const SizedBox(
                                                                height: 12),
                                                            Text(
                                                              'This tab crashed unexpectedly',
                                                              style: TextStyle(
                                                                fontSize: 16,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                                color: isDark
                                                                    ? Colors
                                                                        .white
                                                                    : Colors
                                                                        .black87,
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                                height: 8),
                                                            Text(
                                                              tab.url,
                                                              style: TextStyle(
                                                                fontSize: 12,
                                                                color: isDark
                                                                    ? Colors
                                                                        .white54
                                                                    : Colors
                                                                        .black54,
                                                              ),
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                            ),
                                                            const SizedBox(
                                                                height: 16),
                                                            ElevatedButton.icon(
                                                              style:
                                                                  ElevatedButton
                                                                      .styleFrom(
                                                                backgroundColor: isDark
                                                                    ? AppTheme
                                                                        .neonBlue
                                                                    : AppTheme
                                                                        .lightNeonBlue,
                                                                foregroundColor:
                                                                    Colors
                                                                        .white,
                                                              ),
                                                              onPressed: () {
                                                                setState(() {
                                                                  tab.hasCrashed =
                                                                      false;
                                                                });
                                                                tab.controller
                                                                    .reload();
                                                              },
                                                              icon: const Icon(
                                                                Icons
                                                                    .refresh_rounded,
                                                                size: 18,
                                                              ),
                                                              label: const Text(
                                                                  'Reload Tab'),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    )
                                                  : Stack(
                                                      children: [
                                                        WebViewWidget(
                                                          controller:
                                                              tab.controller,
                                                        ),
                                                        if (tab.isTimedOut &&
                                                            tab.isLoading)
                                                          Positioned(
                                                            top: 0,
                                                            left: 0,
                                                            right: 0,
                                                            child: Container(
                                                              padding:
                                                                  const EdgeInsets
                                                                      .symmetric(
                                                                horizontal: 12,
                                                                vertical: 6,
                                                              ),
                                                              color: Colors
                                                                  .orange
                                                                  .withValues(
                                                                alpha: 0.9,
                                                              ),
                                                              child: Row(
                                                                children: [
                                                                  const Icon(
                                                                    Icons
                                                                        .warning_amber_rounded,
                                                                    size: 16,
                                                                    color: Colors
                                                                        .white,
                                                                  ),
                                                                  const SizedBox(
                                                                    width: 8,
                                                                  ),
                                                                  const Expanded(
                                                                    child: Text(
                                                                      'Page load taking long...',
                                                                      style:
                                                                          TextStyle(
                                                                        fontSize:
                                                                            12,
                                                                        color: Colors
                                                                            .white,
                                                                        fontWeight:
                                                                            FontWeight.bold,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                  GestureDetector(
                                                                    onTap: () {
                                                                      tab.controller
                                                                          .runJavaScript(
                                                                        'window.stop();',
                                                                      );
                                                                      setState(
                                                                          () {
                                                                        tab.isLoading =
                                                                            false;
                                                                        tab.isTimedOut =
                                                                            false;
                                                                      });
                                                                    },
                                                                    child:
                                                                        const Padding(
                                                                      padding:
                                                                          EdgeInsets
                                                                              .symmetric(
                                                                        horizontal:
                                                                            6,
                                                                      ),
                                                                      child:
                                                                          Text(
                                                                        'Stop',
                                                                        style:
                                                                            TextStyle(
                                                                          color:
                                                                              Colors.white,
                                                                          fontWeight:
                                                                              FontWeight.bold,
                                                                          fontSize:
                                                                              12,
                                                                        ),
                                                                      ),
                                                                    ),
                                                                  ),
                                                                  GestureDetector(
                                                                    onTap: () {
                                                                      setState(
                                                                          () {
                                                                        tab.isTimedOut =
                                                                            false;
                                                                      });
                                                                      tab.controller
                                                                          .reload();
                                                                    },
                                                                    child:
                                                                        const Padding(
                                                                      padding:
                                                                          EdgeInsets
                                                                              .symmetric(
                                                                        horizontal:
                                                                            6,
                                                                      ),
                                                                      child:
                                                                          Text(
                                                                        'Reload',
                                                                        style:
                                                                            TextStyle(
                                                                          color:
                                                                              Colors.white,
                                                                          fontWeight:
                                                                              FontWeight.bold,
                                                                          fontSize:
                                                                              12,
                                                                        ),
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ],
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text(
            isRtl ? 'ماذا تريد تحميل؟' : 'What do you want to download?',
            style: TextStyle(
              color: isDark ? Colors.white : Colors.black87,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text(
            isRtl
                ? 'هذا الرابط يحتوي على فيديو وقائمة تشغيل.'
                : 'This link contains both a single video and a playlist.',
            style: TextStyle(
              color: isDark ? Colors.white70 : Colors.black54,
              fontSize: 13,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'video'),
              child: Text(
                isRtl ? 'فيديو واحد فقط' : 'Single video',
                style: const TextStyle(
                  color: Colors.blue,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'playlist'),
              child: Text(
                isRtl ? 'قائمة التشغيل كاملة' : 'Entire playlist',
                style: const TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      );
      if (!mounted) {
        return;
      }
      if (choice == 'playlist') {
        final result = await YoutubePlaylistSheet.show(context, tabUrl);
        if (!mounted) {
          return;
        }
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
      if (!mounted) {
        return;
      }
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
    if (!mounted) {
      return;
    }
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

  // ─────────────────────────────────────────────────────────────
  // DOWNLOAD FAB — with live signal pulse
  // ─────────────────────────────────────────────────────────────
  Widget _buildDownloadFab(BuildContext context, SettingsProvider settings) {
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final activeTab = _tabs[_currentTabIndex];

    // Never show media detection on YouTube
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
          final result = await YoutubePlaylistSheet.show(
            context,
            activeTab.url,
          );
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
            final stream = await YoutubeQualitySheet.show(
              context,
              activeTab.url,
            );
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
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );
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
        ThemedSnackbar.show(
          context,
          message: isRtl
              ? 'هذا التنزيل مكتمل بالفعل'
              : 'This download is already completed.',
          color: AppTheme.neonGreen,
          icon: Icons.check_circle_outline,
          isDarkMode: isDark,
        );
      case InterceptDownloadStatus.alreadyInProgress:
        ThemedSnackbar.show(
          context,
          message: isRtl
              ? 'هذا التنزيل قيد التشغيل بالفعل'
              : 'This download is already in progress.',
          color: AppTheme.neonBlue,
          icon: Icons.info_outline,
          isDarkMode: isDark,
        );
      case InterceptDownloadStatus.resumed:
        ThemedSnackbar.show(
          context,
          message: isRtl ? 'تم استئناف التنزيل' : 'Download resumed.',
          color: AppTheme.neonBlue,
          icon: Icons.play_arrow,
          isDarkMode: isDark,
        );
      case InterceptDownloadStatus.queued:
        ThemedSnackbar.show(
          context,
          message: isRtl
              ? 'تم إنشاء الاتصال. القنوات متصلة.'
              : 'Download queued successfully.',
          color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
          icon: Icons.rocket_launch_outlined,
          isDarkMode: isDark,
        );
      case InterceptDownloadStatus.failed:
        ThemedSnackbar.show(
          context,
          message: result.errorMessage ?? 'Download failed.',
          color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
          icon: Icons.error_outline,
          isDarkMode: isDark,
        );
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
      debugPrint('[DMX Browser] Failed to persist tabs on quit: $e');
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
        tab.progressNotifier.dispose();
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

// ═══════════════════════════════════════════════════════════════
// NEW UI COMPONENTS
// ═══════════════════════════════════════════════════════════════

/// Pulsing live-status dot.
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
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    // Two-cycle pulse on build.
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

/// Icon badge with animated pulse ring — used in sheet headers.
class _PulsingIconBadge extends StatefulWidget {
  final IconData icon;
  final Color color;
  final bool isDark;
  const _PulsingIconBadge({
    required this.icon,
    required this.color,
    required this.isDark,
  });
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
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
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

/// Corner-bracket frame for URL readouts — targeting UI feel.
class _CornerBracketBox extends StatelessWidget {
  final Widget child;
  final Color color;
  final bool isDark;
  const _CornerBracketBox({
    required this.child,
    required this.color,
    required this.isDark,
  });
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
              color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
              width: 0.7,
            ),
          ),
          child: child,
        ),
        // Corner brackets
        Positioned(
          top: 0,
          left: 0,
          child: _Corner(side: _CornerSide.tl, border: bracket),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: _Corner(side: _CornerSide.tr, border: bracket),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          child: _Corner(side: _CornerSide.bl, border: bracket),
        ),
        Positioned(
          bottom: 0,
          right: 0,
          child: _Corner(side: _CornerSide.br, border: bracket),
        ),
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
      painter: _CornerPainter(side: side, border: border),
    );
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

/// Scanline-style loading bar with animated shimmer.
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
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
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
    // Classic / battery-saver / reduce-visuals: plain progress bar with no
    // moving shimmer, so nothing loops while backgrounded.
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
                  gradient: LinearGradient(
                    colors: [Colors.transparent, accent.withValues(alpha: 0.9)],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Animated radar sweep for the sniffer dashboard card.
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
  _RadarPainter({
    required this.sweep,
    required this.color,
    required this.active,
  });
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
    // Crosshair
    canvas.drawLine(
      Offset(center.dx - maxR, center.dy),
      Offset(center.dx + maxR, center.dy),
      ringPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - maxR),
      Offset(center.dx, center.dy + maxR),
      ringPaint,
    );
    if (active) {
      // Sweep wedge
      final sweepPaint = Paint()
        ..shader = SweepGradient(
          startAngle: sweep - 0.9,
          endAngle: sweep,
          colors: [Colors.transparent, color.withValues(alpha: 0.35)],
        ).createShader(Rect.fromCircle(center: center, radius: maxR));
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: maxR),
        sweep - 0.9,
        0.9,
        true,
        sweepPaint,
      );
      // Sweep leading line
      final linePaint = Paint()
        ..color = color.withValues(alpha: 0.8)
        ..strokeWidth = 1.2;
      canvas.drawLine(
        center,
        Offset(center.dx + maxR * cos(sweep), center.dy + maxR * sin(sweep)),
        linePaint,
      );
      // Blips
      final blipPaint = Paint()
        ..color = color.withValues(alpha: 0.7)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);
      canvas.drawCircle(
        Offset(
          center.dx + maxR * 0.55 * cos(sweep - 0.5),
          center.dy + maxR * 0.55 * sin(sweep - 0.5),
        ),
        2,
        blipPaint,
      );
      canvas.drawCircle(
        Offset(
          center.dx + maxR * 0.8 * cos(sweep - 1.2),
          center.dy + maxR * 0.8 * sin(sweep - 1.2),
        ),
        1.5,
        blipPaint,
      );
    }
    // Center dot
    final dotPaint = Paint()
      ..color = color.withValues(alpha: active ? 0.9 : 0.3);
    canvas.drawCircle(center, 2.5, dotPaint);
  }

  @override
  bool shouldRepaint(covariant _RadarPainter old) =>
      old.sweep != sweep || old.active != active;
}

/// Dashboard sniffer card with live radar.
class _SnifferRadarCard extends StatelessWidget {
  final SettingsProvider settings;
  final bool isEnabled;
  final ValueChanged<bool> onToggle;
  const _SnifferRadarCard({
    required this.settings,
    required this.isEnabled,
    required this.onToggle,
  });
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
                    color: accent,
                  ),
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
                          letterSpacing: 0.5,
                        ),
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
                    fontSize: 10.5,
                  ),
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
                (states) => Colors.transparent,
              ),
              onChanged: onToggle,
            ),
          ),
        ],
      ),
    );
  }
}

/// FAB with pulsing signal ring when media is detected.
class _SignalFab extends StatefulWidget {
  final Color color;
  final IconData icon;
  final String label;
  final bool pulse;
  final bool isDark;
  final VoidCallback onPressed;
  const _SignalFab({
    required this.color,
    required this.icon,
    required this.label,
    required this.pulse,
    required this.isDark,
    required this.onPressed,
  });
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
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
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
          label: Text(
            widget.label,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
              fontFamily: 'Space Grotesk',
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }
}

/// YouTube grab button in the URL bar.
class _YouTubeGrabButton extends StatelessWidget {
  final bool isPlaylist;
  final bool isRtl;
  final bool isDark;
  final bool enableGlow;
  final VoidCallback onPressed;
  const _YouTubeGrabButton({
    required this.isPlaylist,
    required this.isRtl,
    required this.isDark,
    required this.enableGlow,
    required this.onPressed,
  });
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
                    spreadRadius: 0.5,
                  ),
                ]
              : null,
        ),
        child: Icon(
          isPlaylist ? Icons.playlist_play_rounded : Icons.download_rounded,
          size: 16,
          color: Colors.white,
        ),
      ),
      tooltip: isPlaylist
          ? (isRtl ? 'تحميل قائمة التشغيل' : 'Download Playlist')
          : (isRtl ? 'تحميل الفيديو' : 'Download Video'),
      onPressed: onPressed,
    );
  }
}

/// Small action button in the tab switcher header.
class _TabSwitcherAction extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;
  const _TabSwitcherAction({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onPressed,
  });
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
              border: Border.all(
                color: color.withValues(alpha: 0.25),
                width: 0.7,
              ),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
        ),
      ),
    );
  }
}

// Stateful Dialog Editor for Injecting CSS & JavaScript
class _JsCssInjectorDialog extends StatefulWidget {
  final String initialJs;
  final String initialCss;
  final Function(String, String) onSave;
  const _JsCssInjectorDialog({
    required this.initialJs,
    required this.initialCss,
    required this.onSave,
  });
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
          Text(
            'JS / CSS INJECTOR',
            style: TextStyle(
              color: accent,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
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
                      .withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      L10n.isRtl(context)
                          ? 'تنبيه: هذا الكود ينفذ على صفحات الويب. لا تدخل بيانات حساسة.'
                          : 'WARNING: Code runs on web pages. Do not enter sensitive data.',
                      style: TextStyle(
                        color:
                            isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _tabHeader(0, 'JavaScript')),
                Expanded(child: _tabHeader(1, 'CSS Style')),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: IndexedStack(
                index: _activeTab,
                children: [
                  _buildCodeEditor(
                    _jsController,
                    '''// Write your Custom Javascript here
// Automatically runs on page loads...''',
                    isDark,
                  ),
                  _buildCodeEditor(
                    _cssController,
                    '''/* Write your Custom CSS here */
body {
  /* background-color: #000; */
}''',
                    isDark,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCEL'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: Colors.black,
          ),
          onPressed: () {
            widget.onSave(_jsController.text, _cssController.text);
            Navigator.pop(context);
          },
          child: const Text('APPLY'),
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
              width: 2,
            ),
          ),
        ),
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
    TextEditingController controller,
    String hint,
    bool isDark,
  ) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: (isDark ? AppTheme.background : AppTheme.lightBackground)
            .withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
          width: 0.8,
        ),
      ),
      child: TextField(
        controller: controller,
        maxLines: null,
        expands: true,
        keyboardType: TextInputType.multiline,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(
            color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
            fontSize: 10,
          ),
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }
}
