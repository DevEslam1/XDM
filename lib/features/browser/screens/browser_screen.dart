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
import '../../../core/services/database_service.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/url_utils.dart';
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
import '../services/ad_blocker.dart';
import '../services/browser_detector.dart';
import '../widgets/bookmark_manager_screen.dart';
import '../widgets/browser_download_sheet.dart';
import '../widgets/browser_history_sheet.dart';
import '../widgets/browser_home_page.dart';

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> with HapticHelper {
  final List<BrowserTab> _tabs = [];
  int _currentTabIndex = 0;

  final TextEditingController _urlController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  bool _isFocused = false;
  bool _showBars = true;
  double _lastScrollY = 0;

  // Custom JS and CSS Injections
  String _customJs = '';
  String _customCss = '';

  // Sniffer and detected media
  final Map<String, String> _detectedDownloadUrls = {}; // tab.id -> url
  final Map<String, List<Map<String, dynamic>>> _detectedMediaSources =
      {}; // tab.id -> sources
  final Map<String, int> _detectedPlaylistUrls = {}; // tab.id -> video count
  final Set<String> _ytDetectionFailed = {}; // tab.url -> yt fetch failed

  DateTime? _lastYoutubeAuthTime;
  static const _youtubeAuthCooldown = Duration(seconds: 30);
  final Map<String, Timer> _mediaScanTimers = {};
  DownloadProvider? _downloadProvider;
  String? _lastHistoryEntryUrl;
  String? _lastHistoryEntryId;
  String? _pendingTitleUpdate;
  final Set<String> _bypassedSniffUrls = {};
  final ScrollController _dashboardScrollController = ScrollController();
  Timer? _navDebounce;
  static const String _snifferPrefKey = 'browserSnifferEnabled';
  bool _isSnifferEnabled = true;
  bool _lastZoomEnabled = false; // Cached to avoid redundant enableZoom calls
  // URL the user was on when they pressed back past the first page (home
  // fallback). Stored so Forward can restore the page without clobbering the
  // native WebView history stack.
  String? _homeReturnUrl;

  static const String _longPressChannel = 'XDM_LongPress';
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

  Future<void> _saveTabs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final List<Map<String, dynamic>> tabList = [];
      int savedIndex = 0;
      int normalTabCount = 0;
      bool currentTabFound = false;

      for (int i = 0; i < _tabs.length; i++) {
        final tab = _tabs[i];
        if (tab.isIncognito) continue;

        if (i == _currentTabIndex) {
          savedIndex = normalTabCount;
          currentTabFound = true;
        }
        tabList.add({
          'url': tab.url,
          'title': tab.title,
          'isIncognito': false,
        });
        normalTabCount++;
      }

      // If current tab was incognito (not found in normal tabs), use last valid index
      if (!currentTabFound && normalTabCount > 0) {
        savedIndex = normalTabCount - 1;
      }
      // Clamp savedIndex to valid range in case all tabs were incognito
      if (normalTabCount > 0) {
        savedIndex = savedIndex.clamp(0, normalTabCount - 1);
      }

      await prefs.setString('persisted_browser_tabs', jsonEncode(tabList));
      await prefs.setInt('persisted_browser_tab_index', savedIndex);
    } catch (e) {
      debugPrint('Error saving tabs: $e');
    }
  }

  Future<void> _restoreTabs() async {
    final prefs = await SharedPreferences.getInstance();
    final String? tabsJson = prefs.getString('persisted_browser_tabs');
    final int savedTabIndex = prefs.getInt('persisted_browser_tab_index') ?? 0;

    final fallbackTitle = mounted ? L10n.of(context, 'browser_new_tab') : 'New Tab';

    if (tabsJson != null && tabsJson.isNotEmpty) {
      try {
        final List<dynamic> decoded = jsonDecode(tabsJson);
        final List<BrowserTab> loadedTabs = [];
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            final String url = item['url'] as String? ?? 'about:blank';
            final String title = item['title'] as String? ?? fallbackTitle;

            // Validate URL scheme to prevent javascript: or file:// injection
            final uri = Uri.tryParse(url);
            final isSafeScheme = uri == null ||
                url == 'about:blank' ||
                url.isEmpty ||
                uri.scheme == 'http' ||
                uri.scheme == 'https';
            if (!isSafeScheme) {
              debugPrint('[Browser] Skipping unsafe restored URL: $url');
              continue;
            }

            final tab = _createNewTab(initialUrl: url, isIncognito: false);
            tab.title = title;
            loadedTabs.add(tab);
          }
        }

        if (loadedTabs.isNotEmpty) {
          if (mounted) {
            setState(() {
              _tabs
                ..clear()
                ..addAll(loadedTabs);
              _currentTabIndex = savedTabIndex.clamp(0, _tabs.length - 1);
              final activeTab = _tabs[_currentTabIndex];
              _urlController.text = activeTab.isHome ? '' : activeTab.url;
            });
            _updateNavState();
            return;
          }
        }
      } catch (e) {
        debugPrint('Error restoring tabs: $e');
      }
    }

    // Fallback: create a new blank tab
    if (mounted) {
      final fallback = _createNewTab();
      setState(() {
        _tabs
          ..clear()
          ..add(fallback);
        _currentTabIndex = 0;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      setState(() {
        _isFocused = _focusNode.hasFocus;
      });
      if (_focusNode.hasFocus) {
        Future.delayed(Duration.zero, () {
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

    _dashboardScrollController.addListener(_onDashboardScroll);

    // Create the first tab
    // Restore tabs from previous session; _restoreTabs() creates tabs as needed
    _restoreTabs();

    // Initialize adblock filters on browser launch
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    if (settings.adBlockerEnabled) {
      AdBlocker.initialize();
      AdBlocker.autoUpdateHosts();
    }
  }

  BrowserTab _createNewTab({
    String initialUrl = 'about:blank',
    bool isIncognito = false,
  }) {
    final cleanInitialUrl = (initialUrl.isEmpty || initialUrl == 'about:blank')
        ? 'about:blank'
        : initialUrl;
    final id =
        '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(9999)}';
    final controller = WebViewController();
    final tab = BrowserTab(
      id: id,
      controller: controller,
      url: cleanInitialUrl == 'about:blank' ? '' : cleanInitialUrl,
      title: cleanInitialUrl == 'about:blank' ? L10n.of(context, 'browser_new_tab') : cleanInitialUrl,
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
        'AdBlockerChannel',
        onMessageReceived: (msg) async {
          try {
            final data = jsonDecode(msg.message);
            final requestId = data['id'];
            final url = data['url'];
            if (requestId != null && url != null) {
              await AdBlocker.initialize();
              final shouldBlock = AdBlocker.shouldBlock(url);
              final jsToRun =
                  "if (window._adBlockPromiseResolvers && window._adBlockPromiseResolvers['$requestId']) { window._adBlockPromiseResolvers['$requestId']($shouldBlock); delete window._adBlockPromiseResolvers['$requestId']; }";
              tab.controller.runJavaScript(jsToRun);
            }
          } catch (e) {
            debugPrint('Error handling AdBlocker channel message: $e');
          }
        },
      )
      ..setUserAgent(
        tab.isIncognito
            ? (settings.desktopMode
                  ? 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
                  : 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36')
            : (settings.desktopMode
                  ? 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
                  : (settings.customUserAgent.isNotEmpty
                        ? settings.customUserAgent
                        : 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36')),
      )
      ..enableZoom(settings.pinchToZoom)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
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

                // Update URL text field if this is the active tab
                if (_currentTabIndex >= 0 &&
                    _currentTabIndex < _tabs.length &&
                    _tabs[_currentTabIndex].id == tab.id) {
                  _urlController.text = tab.url;
                }

                // Clear stale detected download and media links from previous page
                _detectedDownloadUrls.remove(tab.id);
                _detectedPlaylistUrls.remove(tab.id);
                _detectedMediaSources.remove(tab.id);
                _mediaScanTimers[tab.id]?.cancel();
              });
              downloadProvider.setNavbarVisible(true);
            }
            _injectLongPressScriptToTab(tab);
            _injectAdBlocker(tab);
            _injectCustomJsCss(tab);
            _updateNavState();
            // Re-check after 500 ms and 1200 ms: back/forward navigations need
            // extra time for the WebView history stack to settle.
            Future.delayed(const Duration(milliseconds: 500), _updateNavState);
            Future.delayed(const Duration(milliseconds: 1200), _updateNavState);
          },
          onPageFinished: (url) {
            if (mounted) {
              setState(() {
                tab.isLoading = false;
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

            // Inject CSS + JS on Google sign-in pages to ensure the
            // form/Next button is not hidden behind the on-screen keyboard.
            if (url.contains('accounts.google.com') ||
                url.contains('google.com/ServiceLogin') ||
                url.contains('google.com/accounts')) {
              tab.controller.runJavaScript('''
                (function() {
                  // Add generous bottom padding so the page can scroll
                  // past the area the keyboard will cover.
                  var style = document.createElement('style');
                  style.textContent = 'body, html { padding-bottom: 350px !important; }';
                  document.head.appendChild(style);

                  // When any input/button gets focus, scroll it into view
                  // after a short delay (keyboard animation takes ~250ms).
                  document.addEventListener('focusin', function(e) {
                    if (e.target && e.target.scrollIntoView) {
                      setTimeout(function() {
                        e.target.scrollIntoView({behavior:'smooth', block:'center'});
                      }, 350);
                    }
                  });

                  // Also watch for the visual viewport resize (keyboard
                  // opening) and re-scroll the active element into view.
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
                // Short cooldown (30s) so sign-in retries work quickly
                if (_lastYoutubeAuthTime == null ||
                    now.difference(_lastYoutubeAuthTime!) >
                        _youtubeAuthCooldown) {
                  _lastYoutubeAuthTime = now;
                  YoutubeService.authenticateFromBrowser();
                }
              }
            }

            _updateNavState();
            Future.delayed(const Duration(milliseconds: 500), _updateNavState);
            Future.delayed(const Duration(milliseconds: 1200), _updateNavState);

            // Trigger background DOM media scanner
            _mediaScanTimers[tab.id]?.cancel();
            _mediaScanTimers[tab.id] = Timer(const Duration(milliseconds: 1500), () {
              _scanPageMedia(tab);
            });
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
                  if (cleanUrl != 'about:blank') {
                    tab.isHome = false;
                  }
                  if (_currentTabIndex >= 0 &&
                      _currentTabIndex < _tabs.length &&
                      _tabs[_currentTabIndex].id == tab.id) {
                    _urlController.text = tab.url;
                  }
                });

                // Clear cached download/playlist tags on dynamic navigation
                _detectedDownloadUrls.remove(tab.id);
                _detectedPlaylistUrls.remove(tab.id);
                _detectedMediaSources.remove(tab.id);
                _ytDetectionFailed.remove(tab.url);

                // Re-scan media for SPA pages (YouTube, etc.)
                _mediaScanTimers[tab.id]?.cancel();
                _mediaScanTimers[tab.id] = Timer(const Duration(milliseconds: 1500), () {
                  _scanPageMedia(tab);
                });

                Future.delayed(const Duration(milliseconds: 1000), () {
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
                Future.delayed(const Duration(milliseconds: 500), _updateNavState);
                Future.delayed(const Duration(milliseconds: 1200), _updateNavState);
              }
            }
          },
          onNavigationRequest: (NavigationRequest request) {
            if (settings.adBlockerEnabled &&
                AdBlocker.shouldBlock(request.url)) {
              return NavigationDecision.prevent;
            }
            if (_bypassedSniffUrls.contains(request.url)) {
              _bypassedSniffUrls.remove(request.url);
              return NavigationDecision.navigate;
            }
            if (BrowserDetector.isAutoDownloadable(request.url)) {
              setState(() {
                _detectedDownloadUrls[tab.id] = request.url;
              });
              _showInterceptionSheet(context, request.url);
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

    if (cleanInitialUrl != 'about:blank') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          controller.loadRequest(Uri.parse(cleanInitialUrl));
        }
      });
    }

    return tab;
  }

  void _recordHistory(String url, {String? title}) {
    if (url.isEmpty || url == 'about:blank') return;
    final clean = _cleanUrl(url);
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    if (settings.incognitoEnabled) return;

    final now = DateTime.now();

    if (clean == _lastHistoryEntryUrl) {
      if (title != null && title.isNotEmpty && title != clean) {
        if (_lastHistoryEntryId != null) {
          try {
            final db = Provider.of<DatabaseService>(context, listen: false);
            db.updateBrowserHistoryTitle(_lastHistoryEntryId!, title);
          } catch (e) {
            // Fails silently if DB is busy/uninitialized, which is safe to ignore for best-effort title updating.
            debugPrint('[DMX Browser] Failed to update browser history title: $e');
          }
        } else {
          _pendingTitleUpdate = title;
        }
      }
      return;
    }

    _lastHistoryEntryUrl = clean;
    _lastHistoryEntryId = null;
    _pendingTitleUpdate = title;

    try {
      final db = Provider.of<DatabaseService>(context, listen: false);
      db
          .addBrowserHistory({
            'url': clean,
            'title': (title != null && title.isNotEmpty) ? title : clean,
            'visitedAt': now.toIso8601String(),
          })
          .then((id) {
            if (!mounted) return;
            if (clean == _lastHistoryEntryUrl) {
              _lastHistoryEntryId = id;
              if (_pendingTitleUpdate != null &&
                  _pendingTitleUpdate!.isNotEmpty &&
                  _pendingTitleUpdate != clean) {
                db.updateBrowserHistoryTitle(id, _pendingTitleUpdate!);
              }
            }
          });
    } catch (e) {
      debugPrint('[DMX Browser] Failed to add browser history: $e');
    }
  }

  Future<void> _injectLongPressScriptToTab(BrowserTab tab) async {
    if (!mounted) return;
    try {
      await tab.controller.runJavaScript(_kLongPressScript);
    } catch (e) {
      // WebView controller might not be fully initialized or page already closed
      debugPrint('[DMX Browser] Failed to inject long press script: $e');
    }
  }

  Future<void> _injectAdBlocker(BrowserTab tab) async {
    if (!mounted || tab.isHome) return;
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    if (settings.adBlockerEnabled) {
      try {
        await tab.controller.runJavaScript(AdBlocker.adBlockJavaScript);
      } catch (e) {
        debugPrint('AdBlocker script injection failed: $e');
      }
    }
  }

  void _handleLongPressMessageForTab(
    BrowserTab tab,
    JavaScriptMessage message,
  ) {
    if (!mounted) return;
    try {
      final raw = message.message;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final url = data['url'] as String? ?? '';
      final type = data['type'] as String? ?? 'link';
      if (url.isEmpty) return;
      final settings = Provider.of<SettingsProvider>(context, listen: false);
      triggerHaptic(settings);
      _showLongPressSheet(context, url, type);
    } catch (e) {
      debugPrint('[DMX Browser] Failed to decode/handle long press message: $e');
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
      // URL bar stays visible; only hide bottom navbar on scroll down
      if (_showBars) {
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

  @override
  void dispose() {
    for (final tab in _tabs) {
      try {
        tab.controller.clearCache();
        tab.controller.clearLocalStorage();
      } catch (e) {
        // Safe to ignore if controller is already disposed or uninitialized
      }
      try {
        tab.progressNotifier.dispose();
      } catch (e) {
        // Safe to ignore if notifier is already disposed
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

    // Skip native state sync when in virtual home state (set by _goBack fallback)
    if (activeTab.isHome && _homeReturnUrl != null) return;

    try {
      final canBack = await activeTab.controller.canGoBack();
      final canForward = await activeTab.controller.canGoForward();
      final currentUrl = await activeTab.controller.currentUrl();

      if (mounted) {
        setState(() {
          if (currentUrl != null && currentUrl.isNotEmpty) {
            final clean = _cleanUrl(currentUrl);
            // Only update url/isHome when NOT in the virtual home state.
            // When isHome was set by _goBack()'s fallback (without loading
            // about:blank), currentUrl still returns the last real page URL.
            // We must NOT overwrite isHome=true in that case.
            final isBlank = clean == 'about:blank' || clean.isEmpty;
            if (!activeTab.isHome || isBlank) {
              // Normal case: sync url and isHome from the actual WebView URL.
              activeTab.url = clean;
              activeTab.isHome = isBlank;
              if (_tabs[_currentTabIndex].id == activeTab.id) {
                _urlController.text = isBlank ? '' : clean;
              }
            }
            if (activeTab.isHome) {
              // On the home screen the native back must stay disabled so that
              // pressing Back doesn't re-enter old pages shown as "forward".
              // Forward is allowed: _homeReturnUrl tracks where to go.
              activeTab.canGoBack = false;
              activeTab.canGoForward = _homeReturnUrl != null && _homeReturnUrl!.isNotEmpty;
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
      // Normal if webview controller is not attached yet during navigation/load
    }
  }

  Future<void> _goBack() async {
    if (_tabs.isEmpty || _currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
    final activeTab = _tabs[_currentTabIndex];
    // Trust the cached canGoBack state (set by _updateNavState) to avoid a
    // redundant async round-trip that can race with an in-progress page load.
    if (activeTab.canGoBack) {
      _homeReturnUrl = null; // Entering real WebView history — clear home return
      await activeTab.controller.goBack();
      // Give the WebView enough time to commit the history navigation before
      // we query canGoBack/canGoForward again (150 ms was too short).
      await Future.delayed(const Duration(milliseconds: 400));
      await _updateNavState();
    } else if (!activeTab.isHome && activeTab.url.isNotEmpty) {
      // Show the home screen WITHOUT loading about:blank into the WebView.
      // Loading about:blank would push a new entry onto the history stack and
      // destroy the forward stack. Instead, we just flip the Flutter state and
      // remember the current URL so Forward can restore the page later.
      if (mounted) {
        _homeReturnUrl = activeTab.url; // remember where we came from
        setState(() {
          activeTab.isHome = true;
          activeTab.url = '';
          activeTab.canGoBack = false;
          // Forward stays enabled so the user can return to the last page.
          activeTab.canGoForward = true;
          _urlController.clear();
        });
        // No loadRequest here — the WebView history is left intact.
      }
    }
  }

  Future<void> _goForward() async {
    if (_tabs.isEmpty || _currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
    final activeTab = _tabs[_currentTabIndex];
    if (!activeTab.canGoForward) return;

    if (activeTab.isHome && _homeReturnUrl != null && _homeReturnUrl!.isNotEmpty) {
      // We're on the virtual home screen (no about:blank was loaded).
      // Restore the last page by navigating to it directly.
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

    // Normal forward navigation in the WebView history stack.
    await activeTab.controller.goForward();
    // Give the WebView enough time to commit the history navigation.
    await Future.delayed(const Duration(milliseconds: 400));
    await _updateNavState();
  }

  void _navigateToUrl(String input) {
    var url = input.trim();
    if (url.isEmpty) return;

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
    activeTab.controller.loadRequest(Uri.parse(url));
    Future.delayed(const Duration(milliseconds: 300), _updateNavState);
  }

  String _cleanUrl(String url) {
    if (url == 'about:blank') return '';
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return url;
    var clean = uri.toString();
    // Remove trailing slash for any path, not just root, to ensure
    // consistent history deduplication (https://example.com/path/ ->
    // https://example.com/path).
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
      child: Row(
        children: [
          Icon(icon, size: 16, color: textClr),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: textClr, fontSize: 12)),
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
              color: settings.isDarkMode ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
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
              color: settings.isDarkMode ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
              icon: Icons.copy,
              isDarkMode: settings.isDarkMode,
            );
          }
        }
        break;
      case 'share':
        final url = _urlController.text.trim();
        if (url.isNotEmpty) {
          await SharePlus.instance.share(ShareParams(text: url, subject: activeTab.title));
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
            color: settings.isDarkMode ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
            icon: Icons.desktop_windows,
            isDarkMode: settings.isDarkMode,
          );

          for (final t in _tabs) {
            await t.controller.setUserAgent(
              settings.desktopMode
                  ? 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
                  : (t.isIncognito
                        ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'
                        : (settings.customUserAgent.isNotEmpty ? settings.customUserAgent : null)),
            );
            if (!t.isHome) {
              await t.controller.reload();
            }
          }
        }
        break;
      case 'adblock':
        await settings.setAdBlockerEnabled(!settings.adBlockerEnabled);
        if (mounted) {
          ThemedSnackbar.show(
            context,
            message: settings.adBlockerEnabled
                ? L10n.of(context, 'browser_ad_blocker_on')
                : L10n.of(context, 'browser_ad_blocker_off'),
            color: settings.isDarkMode ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
            icon: settings.adBlockerEnabled ? Icons.check_circle_outline : Icons.block,
            isDarkMode: settings.isDarkMode,
          );
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
            color: settings.isDarkMode ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
            icon: _isSnifferEnabled ? Icons.check_circle_outline : Icons.block,
            isDarkMode: settings.isDarkMode,
          );
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
            color: settings.isDarkMode ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
            icon: Icons.security,
            isDarkMode: settings.isDarkMode,
          );
          if (settings.incognitoEnabled) {
            // Clear current tabs cookies, cache, local storage
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
      case 'offline':
        _savePageOffline(activeTab);
        break;
    }
  }

  void _showLongPressSheet(BuildContext context, String url, String type) {
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
    final activeTab = _tabs[_currentTabIndex];
    final hasMultipleQualities = _detectedMediaSources[activeTab.id]?.isNotEmpty ?? false;
    BrowserDownloadSheet.show(
      context,
      url,
      type: type,
      downloadPageUrl: activeTab.isHome ? null : activeTab.url,
      onQuality: hasMultipleQualities ? () => _showQualityPicker(activeTab.id, fallbackUrl: url) : null,
    );
  }

  void _showInterceptionSheet(BuildContext context, String downloadUrl) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    triggerHaptic(settings);
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);

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
                      .withValues(alpha: 0.85),
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
                    left: BorderSide(
                      color: isDark
                          ? AppTheme.glassBorder
                          : AppTheme.lightGlassBorder,
                      width: 0.8,
                    ),
                    right: BorderSide(
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
                              color:
                                  (isDark
                                          ? AppTheme.textMuted
                                          : AppTheme.lightTextMuted)
                                      .withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color:
                                    (isDark
                                            ? AppTheme.neonBlue
                                            : AppTheme.lightNeonBlue)
                                        .withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Icon(
                                Icons.download_for_offline_outlined,
                                color: isDark
                                    ? AppTheme.neonBlue
                                    : AppTheme.lightNeonBlue,
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              isRtl
                                  ? L10n.of(context, 'browser_intercepted_signal')
                                  : L10n.of(context, 'browser_intercepted_signal'),
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: isDark
                                        ? AppTheme.neonBlue
                                        : AppTheme.lightNeonBlue,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.0,
                                  ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          isRtl
                              ? L10n.of(context, 'browser_xdm_scanner')
                              : L10n.of(context, 'browser_xdm_scanner'),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: isDark
                                    ? AppTheme.textSecondary
                                    : AppTheme.lightTextSecondary,
                              ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color:
                                (isDark
                                        ? AppTheme.background
                                        : AppTheme.lightBackground)
                                    .withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isDark
                                  ? AppTheme.glassBorder
                                  : AppTheme.lightGlassBorder,
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            downloadUrl,
                            style: TextStyle(
                              color: isDark
                                  ? AppTheme.textPrimary
                                  : AppTheme.lightTextPrimary,
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
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
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                ),
                                onPressed: () {
                                  Navigator.pop(context);
                                  if (_currentTabIndex >= 0 && _currentTabIndex < _tabs.length) {
                                    final activeTab = _tabs[_currentTabIndex];
                                    _bypassedSniffUrls.add(downloadUrl);
                                    activeTab.controller.loadRequest(
                                      Uri.parse(downloadUrl),
                                    );
                                  }
                                },
                                child: Text(
                                  isRtl ? L10n.of(context, 'browser_continue_browsing') : L10n.of(context, 'browser_continue_browsing'),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: NeonGlowButton(
                                isFilled: true,
                                color: isDark
                                    ? AppTheme.neonBlue
                                    : AppTheme.lightNeonBlue,
                                onPressed: () {
                                  Navigator.pop(context);
                                  _startDirectDownload(downloadUrl);
                                },
                                text: isRtl ? L10n.of(context, 'browser_download_btn') : L10n.of(context, 'browser_download_btn'),
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
  Future<void> _scanPageMedia(BrowserTab tab) async {
    if (!mounted || !_tabs.contains(tab) || tab.isHome || !_isSnifferEnabled) return;

    final scannedUrl = tab.url;

    // Clean up stale media sources from removed tabs
    final activeIds = _tabs.map((t) => t.id).toSet();
    final staleKeys = _detectedMediaSources.keys
        .where((key) => !activeIds.contains(key))
        .toList();
    for (final key in staleKeys) {
      _detectedMediaSources.remove(key);
    }

    // YouTube Playlist detection — do this first before single video
    if (YoutubeService.isPlaylistUrl(scannedUrl)) {
      try {
        final info = await YoutubeService.getPlaylistInfo(scannedUrl);
        if (info != null && mounted && tab.url == scannedUrl) {
          final count = info['videoCount'] as int? ?? 0;
          setState(() {
            _detectedPlaylistUrls[tab.id] = count;
            // Also set a download URL so the FAB shows
            _detectedDownloadUrls[tab.id] = scannedUrl;
          });
        }
      } catch (e) {
        debugPrint('YouTube playlist scan error: $e');
      }
      // If it also has a video ID (e.g. watch?v=xxx&list=yyy),
      // still try to fetch the single video streams too
      if (YoutubeService.isYoutubeVideoUrl(scannedUrl)) {
        try {
          final youtubeStreams = await YoutubeService.getStreams(scannedUrl);
          if (youtubeStreams.isNotEmpty && mounted && tab.url == scannedUrl) {
            setState(() {
              _detectedMediaSources[tab.id] = youtubeStreams;
            });
          }
        } catch (e) {
          debugPrint('YouTube single stream scan error after playlist: $e');
        }
      }
      return;
    }

    // Direct YouTube single video streams capture
    if (YoutubeService.isYoutubeVideoUrl(scannedUrl)) {
      try {
        final youtubeStreams = await YoutubeService.getStreams(scannedUrl);
        if (youtubeStreams.isNotEmpty && mounted && tab.url == scannedUrl) {
          setState(() {
            _detectedMediaSources[tab.id] = youtubeStreams;
            _ytDetectionFailed.remove(scannedUrl);
            if (_detectedDownloadUrls[tab.id] == null) {
              _detectedDownloadUrls[tab.id] = youtubeStreams.first['src'];
            }
          });
          return; // Skip normal DOM scanning since we retrieved streams via YouTube API
        }
      } catch (e) {
        debugPrint('YouTube stream detection error: $e');
      }
      if (mounted && tab.url == scannedUrl) {
        if (_ytDetectionFailed.length > 100) {
          _ytDetectionFailed.remove(_ytDetectionFailed.first);
        }
        setState(() {
          _ytDetectionFailed.add(scannedUrl);
        });
      }
    }

    try {
      final result = await tab.controller.runJavaScriptReturningResult('''
        (function() {
          var sources = [];
          var videos = document.getElementsByTagName('video');
          for (var i = 0; i < videos.length; i++) {
            var v = videos[i];
            if (v.src && v.src.trim() !== '' && !v.src.startsWith('blob:')) {
              sources.push({ src: v.src, label: 'Video Stream (Default)' });
            }
            var childSources = v.getElementsByTagName('source');
            for (var j = 0; j < childSources.length; j++) {
              var s = childSources[j];
              if (s.src && s.src.trim() !== '' && !s.src.startsWith('blob:')) {
                var label = s.getAttribute('label') || s.getAttribute('res') || s.getAttribute('type') || ('Resolution ' + (j + 1));
                sources.push({ src: s.src, label: label });
              }
            }
            
            // Scan for poster images
            var poster = v.getAttribute('poster');
            if (poster && poster.trim() !== '') {
              sources.push({ src: poster, label: 'Video Poster Image' });
            }
          }
          var audios = document.getElementsByTagName('audio');
          for (var i = 0; i < audios.length; i++) {
            var a = audios[i];
            if (a.src && a.src.trim() !== '' && !a.src.startsWith('blob:')) {
              sources.push({ src: a.src, label: 'Audio Stream' });
            }
          }
          
          // Scan for lazy-loaded video sources
          var lazyVideos = document.querySelectorAll('[data-src],[data-video-src]');
          for (var i = 0; i < lazyVideos.length; i++) {
            var src = lazyVideos[i].getAttribute('data-src') || lazyVideos[i].getAttribute('data-video-src');
            if (src && src.trim() !== '' && !src.startsWith('blob:') && (src.includes('.mp4') || src.includes('.webm') || src.includes('.m3u8'))) {
              sources.push({ src: src, label: 'Lazy-Loaded Video' });
            }
          }
          
          // Scan for iframe embedded videos
          var iframes = document.getElementsByTagName('iframe');
          for (var i = 0; i < iframes.length; i++) {
            var src = iframes[i].src;
            if (src && src.trim() !== '') {
              if (src.includes('youtube.com/embed/') || src.includes('player.vimeo.com/video/') || src.includes('.mp4') || src.includes('.m3u8')) {
                sources.push({ src: src, label: 'Embedded Video' });
              }
            }
          }
          
          return JSON.stringify(sources);
        })();
      ''');

      if (result is String && result.isNotEmpty && result != 'null') {
        var cleanResult = result;
        if (cleanResult.startsWith('"') && cleanResult.endsWith('"')) {
          try {
            cleanResult = jsonDecode(cleanResult);
          } catch (_) {
            // Expected fallback if result is a raw quoted string rather than a JSON structure
            if (cleanResult.length > 2) {
              cleanResult = cleanResult.substring(1, cleanResult.length - 1);
            }
          }
        }
        final List<dynamic> parsed = jsonDecode(cleanResult);
        final safeSources = parsed.where((e) {
          final src = (e as Map)['src'] as String? ?? '';
          final uri = Uri.tryParse(src);
          return uri != null &&
              (uri.scheme == 'http' || uri.scheme == 'https') &&
              uri.host.isNotEmpty;
        }).toList();
        if (safeSources.isNotEmpty) {
          setState(() {
            _detectedMediaSources[tab.id] = safeSources
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
            if (_detectedDownloadUrls[tab.id] == null) {
              _detectedDownloadUrls[tab.id] = safeSources.first['src'];
            }
          });
        }
      }
    } catch (e) {
      // Occurs if the page is currently redirecting or WebView is not fully ready
      debugPrint('[DMX Browser] Failed to run media scan JavaScript: $e');
    }
  }

  // Show dialog to choose quality
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
                            color:
                                (isDark
                                        ? AppTheme.textMuted
                                        : AppTheme.lightTextMuted)
                                    .withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Text(
                        L10n.of(context, 'browser_select_video_quality'),
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: accent,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.0,
                            ),
                      ),
                      const SizedBox(height: 16),
                      if (detectedSources.isNotEmpty) ...[
                        ...detectedSources.map((src) {
                          final label =
                              src['label'] as String? ?? L10n.of(context, 'browser_alternative_stream');
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
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          child: Text(
                            L10n.isRtl(context)
                                ? L10n.of(context, 'browser_no_alternative_streams')
                                : L10n.of(context, 'browser_no_alternative_streams'),
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
    return ListTile(
      leading: Icon(
        Icons.video_settings,
        color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
      ),
      title: Text(
        label,
        style: TextStyle(
          color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
      onTap: () {
        Navigator.pop(context);
        _startDirectDownload(streamUrl, type: 'video');
      },
    );
  }

  // Shows all detected streams from FAB
  void _showDetectedMediaSheet(BuildContext context, String tabId) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final detectedSources = _detectedMediaSources[tabId] ?? [];
    final downloadPageUrl = _tabs
        .where((t) => t.id == tabId)
        .map((t) => t.url)
        .firstOrNull;

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
                            color:
                                (isDark
                                        ? AppTheme.textMuted
                                        : AppTheme.lightTextMuted)
                                    .withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Text(
                        L10n.of(context, 'browser_detected_media'),
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: accent,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.0,
                            ),
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
                            final label =
                                src['label'] as String? ??
                                '${L10n.of(context, 'browser_media_stream')} ${i + 1}';
                            final srcUrl = src['src'] as String? ?? '';
                            return ListTile(
                              leading: Icon(
                                Icons.play_circle_fill,
                                color: accent,
                              ),
                              title: Text(
                                label,
                                style: TextStyle(
                                  color: isDark
                                      ? AppTheme.textPrimary
                                      : AppTheme.lightTextPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              subtitle: Text(
                                srcUrl,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: isDark
                                      ? AppTheme.textMuted
                                      : AppTheme.lightTextMuted,
                                  fontSize: 10,
                                ),
                              ),
                              trailing: Icon(
                                Icons.download,
                                size: 18,
                                color: accent,
                              ),
                              onTap: () {
                                Navigator.pop(context);
                                final title = src['title'] as String?;
                                final ext = src['ext'] as String?;
                                final label =
                                    src['label'] as String? ??
                                    '${L10n.of(context, 'browser_media_stream')} ${i + 1}';
                                String? filename;
                                if (title != null && title.isNotEmpty) {
                                  filename = ext != null
                                      ? "$title.$ext"
                                      : title;
                                }
                                BrowserDownloadSheet.show(
                                  context,
                                  srcUrl,
                                  suggestedName: filename,
                                  type: label.toLowerCase().contains('audio')
                                      ? 'audio'
                                      : 'video',
                                  onQuality: () => _showQualityPicker(tabId, fallbackUrl: srcUrl),
                                  downloadPageUrl: downloadPageUrl,
                                );
                              },
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

  // JS/CSS Injector Dialog
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

            // Apply immediately to the active tab
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
        final cssScript =
            """
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

  // Save Page Offline
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
          } catch (_) {
            // Expected fallback if result is a raw quoted string rather than a JSON structure
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
            color: settings.isDarkMode ? AppTheme.neonRed : AppTheme.lightNeonRed,
            icon: Icons.error_outline,
            isDarkMode: settings.isDarkMode,
          );
        }
        return;
      }

      final offlineTitle = mounted ? L10n.of(context, 'browser_offline_page') : 'Offline Page';
      String title = tab.title.isNotEmpty ? tab.title : offlineTitle;
      title = title.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();

      final path = settings.customDownloadPath?.isNotEmpty == true
          ? settings.customDownloadPath!
          : await PermissionService().defaultDownloadDirectory();

      final filePath = p.join(path, "$title.html");
      final file = File(filePath);
      await file.writeAsString(rawHtml);

      // Create a finished DownloadTask in local Hive database
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

      // Reload provider tasks
      if (mounted) {
        await context.read<DownloadProvider>().load(
          pauseOrphanDownloads: false,
        );
        if (mounted) {
          ThemedSnackbar.show(
            context,
            message: '${L10n.of(context, 'browser_page_saved')} - $title.html',
            color: settings.isDarkMode ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
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

  void _showTabSwitcher(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
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
                            // Header
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24.0,
                                vertical: 16.0,
                              ),
                              child: Row(
                                children: [
                                  Text(
                                    L10n.of(context, 'active_tabs'),
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                          color: accent,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 1.0,
                                        ),
                                  ),
                                  const Spacer(),
                                  // New Incognito Tab button
                                  IconButton(
                                    icon: Icon(
                                      Icons.visibility_off,
                                      color: isDark
                                          ? AppTheme.neonViolet
                                          : AppTheme.lightNeonViolet,
                                    ),
                                    tooltip: L10n.of(context, 'browser_new_incognito_tab'),
                                    onPressed: () {
                                      triggerHaptic(settings);
                                      if (_tabs.length >= 10) {
                                        ThemedSnackbar.show(
                                          context,
                                          message: L10n.of(context, 'browser_max_tabs'),
                                          color: Colors.red,
                                          icon: Icons.warning_amber_rounded,
                                          isDarkMode: isDark,
                                        );
                                        return;
                                      }
                                      setState(() {
                                        final tab = _createNewTab(
                                          isIncognito: true,
                                        );
                                        _tabs.add(tab);
                                        _currentTabIndex = _tabs.length - 1;
                                        _urlController.text = '';
                                        _showBars = true;
                                      });
                                      _saveTabs();
                                      Navigator.pop(context);
                                    },
                                  ),
                                  const SizedBox(width: 8),
                                  // New Tab button
                                  IconButton(
                                    icon: Icon(Icons.add, color: accent),
                                    tooltip: L10n.of(context, 'browser_new_tab'),
                                    onPressed: () {
                                      triggerHaptic(settings);
                                      if (_tabs.length >= 10) {
                                        ThemedSnackbar.show(
                                          context,
                                          message: L10n.of(context, 'browser_max_tabs'),
                                          color: Colors.red,
                                          icon: Icons.warning_amber_rounded,
                                          isDarkMode: isDark,
                                        );
                                        return;
                                      }
                                      setState(() {
                                        final tab = _createNewTab();
                                        _tabs.add(tab);
                                        _currentTabIndex = _tabs.length - 1;
                                        _urlController.text = '';
                                        _showBars = true;
                                      });
                                      _saveTabs();
                                      Navigator.pop(context);
                                    },
                                  ),
                                ],
                              ),
                            ),

                            // Grid of tabs
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

                                  return GestureDetector(
                                    onTap: () {
                                      triggerHaptic(settings);
                                      setState(() {
                                        _currentTabIndex = index;
                                        _urlController.text = tab.isHome
                                            ? ''
                                            : tab.url;
                                        _showBars = true;
                                      });
                                      _saveTabs();
                                      Navigator.pop(context);
                                    },
                                    child: GlassCard(
                                      borderRadius: 16,
                                      padding: const EdgeInsets.all(16),
                                      isDarkMode: isDark,
                                      border: isActive
                                          ? Border.all(
                                              color: tab.isIncognito
                                                  ? (isDark
                                                        ? AppTheme.neonViolet
                                                        : AppTheme
                                                              .lightNeonViolet)
                                                  : accent,
                                              width: 2,
                                            )
                                          : null,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Icon(
                                                tab.isIncognito
                                                    ? Icons.visibility_off
                                                    : Icons.language,
                                                size: 14,
                                                color: tab.isIncognito
                                                    ? (isDark
                                                          ? AppTheme.neonViolet
                                                          : AppTheme
                                                                .lightNeonViolet)
                                                    : accent,
                                              ),
                                              const Spacer(),
                                              IconButton(
                                                icon: const Icon(
                                                  Icons.close,
                                                  size: 16,
                                                ),
                                                padding: EdgeInsets.zero,
                                                constraints:
                                                    const BoxConstraints(),
                                                  onPressed: () {
                                                  triggerHaptic(settings);
                                                  _mediaScanTimers[tab.id]
                                                      ?.cancel();
                                                  _mediaScanTimers
                                                      .remove(tab.id);
                                                  setModalState(() {
                                                    setState(() {
                                                      _detectedDownloadUrls
                                                          .remove(tab.id);
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
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 12),
                                          Expanded(
                                            child: Text(
                                              tab.title.isEmpty
                                                  ? 'New Tab'
                                                  : tab.title,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: isDark
                                                    ? AppTheme.textPrimary
                                                    : AppTheme.lightTextPrimary,
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            tab.isHome ? 'Dashboard' : tab.url,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: isDark
                                                  ? AppTheme.textMuted
                                                  : AppTheme.lightTextMuted,
                                              fontSize: 9,
                                            ),
                                          ),
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

  Widget _buildHomeDashboard(BuildContext context, SettingsProvider settings, {ScrollController? scrollController}) {
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accentColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return SingleChildScrollView(
      controller: scrollController,
      padding: const EdgeInsets.all(24.0),
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
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

          // Central Search Bar
          GlassCard(
            borderRadius: 24,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            isDarkMode: isDark,
            child: Row(
              children: [
                Icon(
                  Icons.search,
                  color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: isRtl ? 'ابحث في الويب...' : 'Search the web...',
                      hintStyle: TextStyle(
                        color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                        fontSize: 14,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    style: TextStyle(
                      color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
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

          // Search Engine Selector
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                isRtl ? 'محرك البحث:' : 'Search Engine:',
                style: TextStyle(
                  color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: settings.searchEngine,
                dropdownColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
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
          const SizedBox(height: 24),

          // Sniffer Toggle Card
          GlassCard(
            borderRadius: 20,
            padding: const EdgeInsets.all(16),
            isDarkMode: isDark,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isRtl
                            ? 'حالة كاشف الملفات (Sniffer)'
                            : 'STREAM SNIFFER STATUS',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: accentColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 9,
                          letterSpacing: 1.0,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _isSnifferEnabled
                            ? (isRtl
                                  ? 'الاعتراض التلقائي نشط'
                                  : 'AUTO-INTERCEPT ACTIVE')
                            : (isRtl
                                  ? 'الاعتراض التلقائي متوقف'
                                  : 'AUTO-INTERCEPT DEACTIVATED'),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: isDark
                              ? AppTheme.textPrimary
                              : AppTheme.lightTextPrimary,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isRtl
                            ? 'يكتشف روابط التحميل المباشرة والوسائط تلقائياً'
                            : 'Sniffs media files and documents dynamically',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: isDark
                              ? AppTheme.textMuted
                              : AppTheme.lightTextMuted,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _isSnifferEnabled,
                  activeThumbColor: accentColor,
                  onChanged: (val) {
                    triggerHaptic(settings);
                    _setSnifferEnabled(val);
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 30),

          Text(
            isRtl ? 'إشارات سريعة (روابط)' : 'QUICK SIGNALS (BOOKMARKS)',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: isDark
                  ? AppTheme.textSecondary
                  : AppTheme.lightTextSecondary,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 2.2,
            children: [
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
                url: 'https://tiktok.com',
                icon: Icons.music_note,
                color: isDark
                    ? const Color(0xFFFE2C55)
                    : const Color(0xFFE01E43),
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
  }) {
    final isDark = settings.isDarkMode;
    final textPrimary = isDark
        ? AppTheme.textPrimary
        : AppTheme.lightTextPrimary;

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
            final activeTab = _tabs[_currentTabIndex];
            setState(() {
              activeTab.isHome = false;
            });
            _navigateToUrl(url);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color, size: 20),
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
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        url.replaceAll('https://', ''),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: isDark
                              ? AppTheme.textMuted
                              : AppTheme.lightTextMuted,
                          fontSize: 9,
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
    final downloadProvider = Provider.of<DownloadProvider>(context, listen: false);
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final statusBarHeight = MediaQuery.of(context).padding.top;

    if (_tabs.isEmpty || _currentTabIndex < 0 || _currentTabIndex >= _tabs.length) {
      return const SizedBox.shrink();
    }
    final activeTab = _tabs[_currentTabIndex];
    final showFab =
        !activeTab.isHome &&
        (_detectedDownloadUrls[activeTab.id] != null ||
            (_detectedMediaSources[activeTab.id]?.isNotEmpty ?? false) ||
            _detectedPlaylistUrls.containsKey(activeTab.id));

    // Reactively ensure zoom configuration matches settings changes
    if (settings.pinchToZoom != _lastZoomEnabled) {
      _lastZoomEnabled = settings.pinchToZoom;
      for (final tab in _tabs) {
        tab.controller.enableZoom(settings.pinchToZoom);
      }
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (_tabs.isEmpty || _currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
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
          // Let the WebView's native Android view handle keyboard
          // scrolling. If Flutter resizes the Scaffold body when the
          // keyboard appears, the platform view re-layouts and loses
          // focus, causing an infinite show/hide keyboard cycle.
          resizeToAvoidBottomInset: false,

          floatingActionButton: showFab
              ? _buildDownloadFab(context, settings)
              : null,
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          body: Column(
            children: [
              // Custom collapsing App Bar
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
                          ? (isDark ? AppTheme.surface : AppTheme.lightSurface)
                          : (isDark ? AppTheme.surface : AppTheme.lightSurface)
                                .withValues(alpha: 0.5),
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
                          // Close Browser Button
                          IconButton(
                            icon: Icon(
                              Icons.close,
                              size: 20,
                              color: textClr,
                            ),
                            tooltip: isRtl ? 'إغلاق المتصفح' : 'Close browser',
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

                          // Address bar
                          Expanded(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              height: 36,
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
                                borderRadius: BorderRadius.circular(24),
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
                                boxShadow:
                                    (_isFocused &&
                                        isDark &&
                                        settings.enableGlow)
                                    ? [
                                        BoxShadow(
                                          color:
                                              (isDark
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
                                  if (activeTab.isIncognito) ...[
                                    const SizedBox(width: 8),
                                    Icon(
                                      Icons.visibility_off,
                                      size: 14,
                                      color: isDark
                                          ? AppTheme.neonViolet
                                          : AppTheme.lightNeonViolet,
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                  Expanded(
                                    child: ValueListenableBuilder<TextEditingValue>(
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
                                            prefixIcon: Icon(
                                              activeTab.isHome
                                                  ? Icons.search
                                                  : Icons.language,
                                              color: _isFocused
                                                  ? (isDark
                                                        ? AppTheme.neonBlue
                                                        : AppTheme.lightNeonBlue)
                                                  : (isDark
                                                        ? AppTheme.textSecondary
                                                        : AppTheme
                                                              .lightTextSecondary),
                                              size: 16,
                                            ),
                                            prefixIconConstraints:
                                                const BoxConstraints(
                                                  minWidth: 32,
                                                  minHeight: 32,
                                                ),
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
                                                    : (_isFocused && value.text.isNotEmpty
                                                          ? Icons.clear
                                                          : Icons.refresh),
                                                size: 16,
                                                color: _isFocused
                                                    ? (isDark
                                                          ? AppTheme.neonBlue
                                                          : AppTheme.lightNeonBlue)
                                                    : (isDark
                                                          ? AppTheme.textSecondary
                                                          : AppTheme.lightTextSecondary),
                                              ),
                                              tooltip: activeTab.isLoading
                                                  ? (isRtl
                                                        ? 'إلغاء التحميل'
                                                        : 'Stop loading')
                                                  : (_isFocused && value.text.isNotEmpty
                                                        ? (isRtl ? 'مسح' : 'Clear')
                                                        : (isRtl
                                                              ? 'إعادة تحميل الصفحة'
                                                              : 'Refresh page')),
                                              onPressed: () {
                                                triggerHaptic(settings);
                                                if (activeTab.isLoading) {
                                                  activeTab.controller
                                                      .runJavaScript('window.stop();');
                                                  setState(() {
                                                    activeTab.isLoading = false;
                                                  });
                                                } else if (_isFocused && value.text.isNotEmpty) {
                                                  _urlController.clear();
                                                } else {
                                                  if (!activeTab.isHome) {
                                                    activeTab.controller.reload();
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
                                                : 'SEARCH OR SCAN SIGNAL...',
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
                                                  horizontal: 8,
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

                          // YouTube download button in appbar
                          if (!activeTab.isHome &&
                              (YoutubeService.isYoutubeVideoUrl(
                                    activeTab.url,
                                  ) ||
                                  YoutubeService.isPlaylistUrl(
                                    activeTab.url,
                                  ))) ...[
                            IconButton(
                              icon: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: Colors.red.withValues(alpha: 0.2),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.red,
                                    width: 1.2,
                                  ),
                                  boxShadow: settings.enableGlow
                                      ? [
                                          BoxShadow(
                                            color: Colors.red.withValues(
                                              alpha: 0.4,
                                            ),
                                            blurRadius: 6,
                                            spreadRadius: 0.5,
                                          ),
                                        ]
                                      : null,
                                ),
                                child: Icon(
                                  YoutubeService.isPlaylistUrl(activeTab.url)
                                      ? Icons.playlist_play_rounded
                                      : Icons.download_rounded,
                                  size: 16,
                                  color: Colors.white,
                                ),
                              ),
                              tooltip:
                                  YoutubeService.isPlaylistUrl(activeTab.url)
                                  ? (isRtl
                                        ? 'تحميل قائمة التشغيل'
                                        : 'Download Playlist')
                                  : (isRtl
                                        ? 'تحميل الفيديو'
                                        : 'Download Video'),
                              onPressed: () async {
                                triggerHaptic(settings);
                                final tabUrl = activeTab.url;
                                final isPlaylist = YoutubeService.isPlaylistUrl(tabUrl);
                                final isVideo = YoutubeService.isYoutubeVideoUrl(tabUrl);
                                final isMixed = isPlaylist && isVideo;

                                if (isMixed) {
                                  // Mixed URL: ask user whether to download single video or full playlist
                                  final choice = await showDialog<String>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                                      title: Text(isRtl ? 'ماذا تريد تحميل؟' : 'What do you want to download?',
                                          style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontSize: 16, fontWeight: FontWeight.bold)),
                                      content: Text(isRtl ? 'هذا الرابط يحتوي على فيديو وقائمة تشغيل.' : 'This link contains both a single video and a playlist.',
                                          style: TextStyle(color: isDark ? Colors.white70 : Colors.black54, fontSize: 13)),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(ctx, 'video'),
                                          child: Text(isRtl ? 'فيديو واحد فقط' : 'Single Video',
                                              style: const TextStyle(color: Colors.blue, fontWeight: FontWeight.bold)),
                                        ),
                                        TextButton(
                                          onPressed: () => Navigator.pop(ctx, 'playlist'),
                                          child: Text(isRtl ? 'قائمة التشغيل كاملة' : 'Entire Playlist',
                                              style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (!context.mounted) return;
                                  if (choice == 'playlist') {
                                    final result = await YoutubePlaylistSheet.show(context, tabUrl);
                                    if (result != null && context.mounted) {
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
                                    return; // dismissed
                                  }
                                  // choice == 'video': fall through to single-video download
                                } else if (isPlaylist) {
                                  // Pure playlist URL
                                  final result = await YoutubePlaylistSheet.show(context, tabUrl);
                                  if (result != null && context.mounted) {
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

                                // Single-video download
                                final stream = await YoutubeQualitySheet.show(context, tabUrl);
                                if (stream != null && context.mounted) {
                                  final title = stream['title'] as String? ?? 'YouTube Video';
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
                              },
                            ),
                            const SizedBox(width: 4),
                          ],

                          // Back navigation
                          IconButton(
                            icon: Icon(
                              Icons.arrow_back_ios_new,
                              size: 15,
                              color: (activeTab.canGoBack || !activeTab.isHome)
                                  ? textClr
                                  : (isDark
                                        ? AppTheme.textMuted
                                        : AppTheme.lightTextMuted),
                            ),
                            onPressed: (activeTab.canGoBack || !activeTab.isHome)
                                ? () async {
                                    triggerHaptic(settings);
                                    await _goBack();
                                  }
                                : null,
                          ),
                          // Forward navigation
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

                          // Tab Switcher Button
                          GestureDetector(
                            onTap: () {
                              triggerHaptic(settings);
                              _showTabSwitcher(context);
                            },
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 6),
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                border: Border.all(color: textClr, width: 1.8),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                '${_tabs.length}',
                                style: TextStyle(
                                  color: textClr,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),

                          // More menu options
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
                                settings.adBlockerEnabled
                                    ? Icons.shield
                                    : Icons.shield_outlined,
                                settings.adBlockerEnabled
                                    ? 'Ad blocker: ON'
                                    : 'Ad blocker: OFF',
                                'adblock',
                                textClr,
                              ),
                              _menuItem(
                                _isSnifferEnabled
                                    ? Icons.radar
                                    : Icons.radar_outlined,
                                _isSnifferEnabled
                                    ? (L10n.isRtl(context) ? 'كاشف الوسائط: مفعل' : 'Media detector: ON')
                                    : (L10n.isRtl(context) ? 'كاشف الوسائط: معطل' : 'Media detector: OFF'),
                                'sniffer',
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
                            ],
                            onOpened: () {
                              // Helper logic: since bookmarks & history sheets are pushed separately,
                              // we handle their callbacks when they are selected.
                            },
                          ),
                        ],
                      ),
                    ),
              ),
            ),
          ),
              ),

              // Loading Progress line
              if (activeTab.isLoading && !activeTab.isHome)
                ValueListenableBuilder<double>(
                  valueListenable: activeTab.progressNotifier,
                  builder: (context, progressValue, child) {
                    return LinearProgressIndicator(
                      value: progressValue,
                      minHeight: 2.0,
                      backgroundColor: Colors.transparent,
                      color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                    );
                  },
                ),

              // Main browser view (preserving controllers state with IndexedStack)
              Expanded(
                child: Stack(
                  children: [
                    GestureDetector(
                      onTap: () => _focusNode.unfocus(),
                      behavior: HitTestBehavior.translucent,
                      child: _tabs.isEmpty
                          ? const SizedBox.shrink()
                          : IndexedStack(
                              index: _currentTabIndex >= 0 && _currentTabIndex < _tabs.length
                                  ? _currentTabIndex
                                  : 0,
                              children: _tabs.asMap().entries.map((entry) {
                                final tabIndex = entry.key;
                                final tab = entry.value;
                                final isActiveTab = tabIndex == _currentTabIndex;
                                if (tab.isHome) {
                                  return SizedBox(
                                    width: double.infinity,
                                    height: double.infinity,
                                    // Only pass the shared ScrollController to the
                                    // active tab's dashboard. Passing it to every
                                    // isHome tab in the IndexedStack would attach
                                    // the same controller to multiple ScrollViews
                                    // and crash with the '_positions.length == 1'
                                    // assertion.
                                    child: _buildHomeDashboard(
                                      context,
                                      settings,
                                      scrollController: isActiveTab ? _dashboardScrollController : null,
                                    ),
                                  );
                                } else {
                                  return SizedBox(
                                    width: double.infinity,
                                    height: double.infinity,
                                    child: RepaintBoundary(
                                      child: RefreshIndicator(
                                        color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                                        onRefresh: () async {
                                          await tab.controller.reload();
                                        },
                                        child: WebViewWidget(controller: tab.controller),
                                      ),
                                    ),
                                  );
                                }
                              }).toList(),
                            ),
                    ),

                    // Left edge gesture zone (Swipe edge -> Go Back)
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

                    // Right edge gesture zone (Swipe edge -> Go Forward)
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
    );
  }

  // Intercept bookmark and history opens from popups
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

  // Handle manual navigation callbacks
  Widget _buildDownloadFab(BuildContext context, SettingsProvider settings) {
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final activeTab = _tabs[_currentTabIndex];
    final detectedSources = _detectedMediaSources[activeTab.id] ?? [];
    final isPlaylist = _detectedPlaylistUrls.containsKey(activeTab.id);
    final playlistCount = _detectedPlaylistUrls[activeTab.id] ?? 0;

    // YouTube Playlist FAB
    if (isPlaylist) {
      return FloatingActionButton.extended(
        heroTag: null,
        backgroundColor: Colors.red,
        foregroundColor: Colors.white,
        elevation: 4,
        onPressed: () async {
          triggerHaptic(settings);
          final result = await YoutubePlaylistSheet.show(
            context,
            activeTab.url,
          );
          if (result != null && context.mounted) {
            ThemedSnackbar.show(
              context,
              message: '${result.selectedVideos.length} videos enqueued from "${result.playlistTitle}"',
              color: AppTheme.neonGreen,
              icon: Icons.playlist_add_check,
              isDarkMode: isDark,
            );
          }
        },
        icon: const Icon(Icons.playlist_play_rounded),
        label: Text('PLAYLIST${playlistCount > 0 ? ' ($playlistCount)' : ''}'),
      );
    }

    // Single video / media — show quality picker directly
    if (YoutubeService.isExtractableMediaUrl(activeTab.url) &&
        detectedSources.isNotEmpty) {
      return FloatingActionButton.extended(
        heroTag: null,
        backgroundColor: Colors.red,
        foregroundColor: Colors.white,
        elevation: 4,
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
              final title = stream['title'] as String? ?? 'Media Video';
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
        icon: const Icon(Icons.play_circle_filled),
        label: Text(
          detectedSources.length > 1
              ? 'MEDIA (${detectedSources.length})'
              : 'MEDIA',
        ),
      );
    }

    // YouTube detected but stream fetch failed — show retry FAB
    if (YoutubeService.isYoutubeVideoUrl(activeTab.url) &&
        _ytDetectionFailed.contains(activeTab.url)) {
      return FloatingActionButton.extended(
        heroTag: null,
        backgroundColor: Colors.red.withValues(alpha: 0.6),
        foregroundColor: Colors.white70,
        elevation: 4,
        onPressed: () async {
          triggerHaptic(settings);
          setState(() {
            _ytDetectionFailed.remove(activeTab.url);
          });
          _scanPageMedia(activeTab);
        },
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: const Text('YOUTUBE (RETRY)'),
      );
    }

    // Normal download FAB
    return FloatingActionButton.extended(
      heroTag: null,
      backgroundColor: accent,
      foregroundColor: Colors.black,
      elevation: 4,
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
      icon: const Icon(Icons.download_rounded),
      label: Text(
        detectedSources.length > 1
            ? 'DOWNLOADS (${detectedSources.length})'
            : 'DOWNLOAD',
      ),
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
    final downloadProvider = Provider.of<DownloadProvider>(
      context,
      listen: false,
    );
    final settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );
    final isRtl = L10n.isRtl(context);
    final isDark = settingsProvider.isDarkMode;

    // 1. Check if the exact same URL is already present in task list
    final existingTasks = downloadProvider.tasks
        .where((t) => t.url == url)
        .toList();
    if (existingTasks.isNotEmpty) {
      final existingTask = existingTasks.first;
      if (existingTask.status == DownloadStatus.completed) {
        ThemedSnackbar.show(
          context,
          message: isRtl
              ? 'هذا التنزيل مكتمل بالفعل'
              : 'This download is already completed.',
          color: AppTheme.neonGreen,
          icon: Icons.check_circle_outline,
          isDarkMode: isDark,
        );
      } else if (existingTask.status == DownloadStatus.downloading ||
          existingTask.status == DownloadStatus.queued) {
        ThemedSnackbar.show(
          context,
          message: isRtl
              ? 'هذا التنزيل قيد التشغيل بالفعل'
              : 'This download is already in progress.',
          color: AppTheme.neonBlue,
          icon: Icons.info_outline,
          isDarkMode: isDark,
        );
      } else {
        downloadProvider.resumeTask(existingTask.id);
        ThemedSnackbar.show(
          context,
          message: isRtl ? 'تم استئناف التنزيل' : 'Download resumed.',
          color: AppTheme.neonBlue,
          icon: Icons.play_arrow,
          isDarkMode: isDark,
        );
      }
      return;
    }

    // 2. Resolve default filename
    String finalFileName = suggestedName ?? '';
    if (finalFileName.isEmpty) {
      if (url.startsWith('magnet:')) {
        final parsed = parseMagnetUrl(url);
        finalFileName = parsed['name'] ?? 'Torrent Download';
      } else {
        finalFileName = fileNameFromUrl(url);
      }
    }

    // 3. Deduplicate filename to prevent conflicts
    String numberedName = finalFileName;
    final ext = p.extension(finalFileName);
    final base = p.basenameWithoutExtension(finalFileName);
    var counter = 1;
    while (downloadProvider.tasks.any(
      (t) => t.fileName.toLowerCase() == numberedName.toLowerCase(),
    )) {
      numberedName = '${base}_$counter$ext';
      counter++;
    }
    finalFileName = numberedName;

    // 4. Determine category
    String resolvedCategory = '';
    if (type == 'video') {
      resolvedCategory = 'Video';
    } else if (type == 'audio') {
      resolvedCategory = 'Audio';
    } else if (type == 'image') {
      resolvedCategory = 'Image';
    } else {
      resolvedCategory = categoryFromFileName(finalFileName);
    }

    // 5. Trigger download in background
    try {
      if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
      final activeTab = _tabs[_currentTabIndex];
      final resolvedOriginUrl =
          downloadPageUrl ?? (activeTab.isHome ? null : activeTab.url);
      await downloadProvider.addDownload(
        name: finalFileName,
        url: url,
        size: videoSize ?? 0,
        category: resolvedCategory,
        savePath: '', // Falls back to default directory
        downloadPageUrl: resolvedOriginUrl,
        mergedAudioUrl: audioUrl,
        audioSize: audioSize ?? 0,
      );

      if (mounted) {
        if (downloadProvider.lastError != null) {
          ThemedSnackbar.show(
            context,
            message: downloadProvider.lastError!,
            color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
            icon: Icons.error_outline,
            isDarkMode: isDark,
          );
        } else {
          ThemedSnackbar.show(
            context,
            message: isRtl
                ? 'تم إنشاء الاتصال. القنوات متصلة.'
                : 'TRANSMISSION ESTABLISHED. CHANNELS CONNECTED.',
            color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
            icon: Icons.rocket_launch_outlined,
            isDarkMode: isDark,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ThemedSnackbar.show(
          context,
          message: e.toString(),
          color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
          icon: Icons.error_outline,
          isDarkMode: isDark,
        );
      }
    }
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
  int _activeTab = 0; // 0: JS, 1: CSS

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
      title: Text(
        'JS / CSS INJECTOR',
        style: TextStyle(
          color: accent,
          fontSize: 14,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.0,
        ),
      ),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.85,
        height: 280,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed).withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      L10n.isRtl(context)
                          ? 'تنبيه: هذا الكود يُنفذ على صفحات الويب. لا تُدخل بيانات حساسة.'
                          : 'WARNING: Code runs on web pages. Do not enter sensitive data.',
                      style: TextStyle(
                        color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
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
                    '// Write your Custom Javascript here\n// Automatically runs on page loads...',
                    isDark,
                  ),
                  _buildCodeEditor(
                    _cssController,
                    '/* Write your Custom CSS here */\nbody {\n  /* background-color: #000; */\n}',
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
    final accent = settings.isDarkMode
        ? AppTheme.neonBlue
        : AppTheme.lightNeonBlue;
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
