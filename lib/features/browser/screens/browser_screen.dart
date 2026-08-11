import 'browser_settings_screen.dart';
import '../widgets/shortcuts_grid_widget.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
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
import 'package:uuid/uuid.dart';
import '../../../core/app_theme.dart';
import '../../../core/services/database/app_database.dart';
import '../../../core/services/database_service.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/services/user_script_manager.dart' hide UserScript;
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/file_opener.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/url_utils.dart';
import 'package:url_launcher/url_launcher.dart';
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
import '../../../core/services/redirect_guard.dart';
import '../services/page_intent_classifier.dart';
import '../services/site_settings_store.dart';
import '../screens/script_manager_screen.dart';
import '../widgets/bookmark_manager_screen.dart';
import '../widgets/browser_download_sheet.dart';
import '../widgets/browser_history_sheet.dart';
import '../widgets/browser_home_page.dart';
import '../widgets/link_options_sheet.dart';
import '../widgets/redirect_sheet.dart';
import '../widgets/smart_url_bar.dart';
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
    with HapticHelper, WidgetsBindingObserver, SingleTickerProviderStateMixin {
  Timer? _navStateDebounceTimer;
  SettingsProvider? _cachedSettings;
  SettingsProvider get _settings =>
      _cachedSettings ?? Provider.of<SettingsProvider>(context, listen: false);
  final List<Map<String, String>> _userCustomShortcuts = [];

  Future<void> _showAddShortcutDialog() async {
    final titleC = TextEditingController();
    final urlC = TextEditingController();
    final isDark = context.read<SettingsProvider>().isDarkMode;
    final isRtl = L10n.isRtl(context);

    final res = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            isRtl ? 'إضافة اختصار جديد' : 'Add Custom Shortcut',
            style: TextStyle(
                color:
                    isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleC,
                decoration: InputDecoration(
                  labelText: isRtl ? 'العنوان' : 'Title',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: urlC,
                decoration: InputDecoration(
                  labelText: isRtl ? 'الرابط (URL)' : 'URL',
                ),
                keyboardType: TextInputType.url,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(isRtl ? 'إلغاء' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(isRtl ? 'إضافة' : 'Add'),
            ),
          ],
        );
      },
    );

    if (res == true) {
      final title = titleC.text.trim();
      var url = urlC.text.trim();
      if (url.isNotEmpty) {
        if (!url.startsWith('http://') && !url.startsWith('https://')) {
          url = 'https://$url';
        }
        setState(() {
          _userCustomShortcuts.add({
            'title': title.isNotEmpty ? title : url,
            'url': url,
          });
        });
        _saveCustomShortcuts(); // Bug #8 fix: persist to SharedPreferences
      }
    }
  }

  Future<void> _saveCustomShortcuts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'browser_custom_shortcuts', jsonEncode(_userCustomShortcuts));
    } catch (e) {
      _log.warning('Failed to save custom shortcuts: $e');
    }
  }

  Future<void> _loadCustomShortcuts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('browser_custom_shortcuts');
      if (raw != null) {
        final list = jsonDecode(raw) as List<dynamic>;
        if (mounted) {
          setState(() {
            _userCustomShortcuts.clear();
            for (final item in list) {
              if (item is Map<String, dynamic>) {
                _userCustomShortcuts
                    .add(item.map((k, v) => MapEntry(k, v.toString())));
              } else if (item is Map) {
                _userCustomShortcuts.add(
                  item.map((k, v) => MapEntry(k.toString(), v.toString())),
                );
              }
            }
          });
        }
      }
    } catch (e) {
      _log.warning('Failed to load custom shortcuts: $e');
    }
  }

  Future<void> _removeCustomShortcut(Map<String, String> shortcut) async {
    final isDark = context.read<SettingsProvider>().isDarkMode;
    final isRtl = L10n.isRtl(context);

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            isRtl ? 'حذف الاختصار' : 'Remove Shortcut',
            style: TextStyle(
                color:
                    isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary),
          ),
          content: Text(
            isRtl
                ? 'هل تريد حذف هذا الاختصار؟'
                : 'Remove "${shortcut['title']}" from your shortcuts?',
            style: TextStyle(
                color: isDark
                    ? AppTheme.textSecondary
                    : AppTheme.lightTextSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(isRtl ? 'إلغاء' : 'Cancel'),
            ),
            ElevatedButton(
              style:
                  ElevatedButton.styleFrom(backgroundColor: AppTheme.neonRed),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(isRtl ? 'حذف' : 'Remove',
                  style: const TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      setState(() {
        _userCustomShortcuts.remove(shortcut);
      });
      _saveCustomShortcuts(); // Bug #8 fix: persist removal to SharedPreferences
    }
  }

  static final _log = Logger('BrowserScreen');

  late final TabManager _tabManager = TabManager(
    isActive: () => mounted,
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
  final Set<String> _recentDownloadUrls = {};

  void _markUrlAsDownloaded(String url) {
    _recentDownloadUrls.add(url);
    Future.delayed(const Duration(seconds: 4), () {
      _recentDownloadUrls.remove(url);
    });
  }

  List<BrowserTab> get _tabs => _tabManager.tabs;
  int get _currentTabIndex => _tabManager.currentIndex;
  set _currentTabIndex(int value) {
    if (value >= 0 && value < _tabs.length) {
      final oldActiveTab =
          _tabs.length > _currentTabIndex && _currentTabIndex >= 0
              ? _tabs[_currentTabIndex]
              : null;
      if (oldActiveTab != null && oldActiveTab.id != _tabs[value].id) {
        if (_tabIdHistory.isEmpty || _tabIdHistory.last != oldActiveTab.id) {
          _tabIdHistory.add(oldActiveTab.id);
          if (_tabIdHistory.length > 50) {
            _tabIdHistory.removeAt(0);
          }
        }
      }
    }
    _tabManager.currentIndex = value;
  }

  final TextEditingController _urlController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _isFocused = false;
  final ValueNotifier<bool> _showBarsNotifier = ValueNotifier<bool>(true);
  final ScrollController _tabStripScrollController = ScrollController();
  double _lastScrollY = 0;
  String _customJs = '';
  String _customCss = '';

  // E6: Element Picker State
  bool _isPickerModeActive = false;
  bool _scriptsInjectedSnackbarShown = false;
  void _notifyScriptsInjected() {
    if (!_scriptsInjectedSnackbarShown && mounted) {
      _scriptsInjectedSnackbarShown = true;
      final settings = _settings;
      final isRtl = L10n.isRtl(context);
      ThemedSnackbar.show(
        context,
        message: isRtl
            ? 'تم تطبيق البرامج النصية والأنماط المخصصة'
            : 'Custom JS/CSS applied',
        color: settings.isDarkMode ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
        icon: Icons.code_rounded,
        isDarkMode: settings.isDarkMode,
      );
    }
  }

  // Fix #10: Per-tab blocked-ad and blocked-popup counters.
  // Using ValueNotifier per tab so increments in shouldInterceptRequest do NOT call setState.
  static final ValueNotifier<int> _zeroNotifier = ValueNotifier<int>(0);
  String? _zeroNotifierTabId;
  final Map<String, ValueNotifier<int>> _blockedAdsNotifiers = {};
  final Map<String, int> _blockedAdsPerTab = {};
  final Map<String, int> _blockedPopupsPerTab = {};

  /// ValueNotifier for the currently-active tab's blocked-ad count.
  ValueNotifier<int> get _activeBlockedAdsNotifier {
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) {
      if (_zeroNotifierTabId != null) {
        _zeroNotifierTabId = null;
        _zeroNotifier.value = 0;
      }
      return _zeroNotifier;
    }
    final tabId = _tabs[_currentTabIndex].id;
    final existing = _blockedAdsNotifiers[tabId];
    if (existing != null) {
      return existing;
    }
    final count = _blockedAdsPerTab[tabId] ?? 0;
    if (_zeroNotifierTabId != tabId) {
      _zeroNotifierTabId = tabId;
      _zeroNotifier.value = count;
    }
    return _zeroNotifier;
  }

  /// Blocked popups for the currently-active tab.
  // ignore: unused_element — tracked for future snackbar/badge display.
  int get _blockedPopupCount {
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return 0;
    return _blockedPopupsPerTab[_tabs[_currentTabIndex].id] ?? 0;
  }

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

  /// Tracks when a back/forward navigation is in progress so that
  /// [shouldOverrideUrlLoading] doesn't intercept it. Without this,
  /// back/forward to certain pages (e.g. Google search) gets intercepted
  /// by the classifier and either blocked or opened in a new background
  /// tab, effectively "dismissing" the page.
  final Map<String, bool> _navigatingBackForwardTabIds = {};

  final AdBlockerDelegate _adBlocker = AdBlockerDelegate();
  final RedirectGuard _redirectGuard = RedirectGuard();

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
    isIncognito: () => _settings.incognitoEnabled,
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
  String? _lastLongPressSheetUrl;
  DateTime? _lastLongPressSheetAt;

  // UX 3.1: Find-in-page state
  bool _findPanelVisible = false;
  int _findActiveMatch = 0;
  int _findMatchCount = 0;
  final TextEditingController _findTextController = TextEditingController();

  // UX 3.2: Reader-mode controls state
  ReaderArticle? _readerArticle;
  String?
      _readerTabId; // Bug #16 fix: track the specific tab where reader mode was activated
  bool _readerControlsVisible = false;
  double _readerFontSize = 16.0;
  String _readerTheme = 'light';
  String _readerFontFamily = 'serif';

  // UX 3.5: Recently closed tabs
  static const int _maxRecentClosedTabs = 10;
  final List<_ClosedTab> _recentlyClosedTabs = [];

  // UX 3.12: Full-page screenshot guard
  bool _capturingPage = false;

  // UX 3.15: Incognito banner (dismissed per session)
  bool _incognitoBannerDismissed = false;

  // UX 3.19: Form autofill JS channel
  static const String _autofillChannel = 'XDM_Autofill';

  // UX 3.20: Keyboard shortcuts only on desktop-class platforms
  bool get _shortcutsActive =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static const String _longPressChannel = 'XDM_LongPress';
  static const String _popupsChannel = 'XDM_Popups';
  static const String _pickerChannel = 'XdmPickerChannel';

  /// Fallback used by [onLongPressHitTestResult] when the OS hit test gives no
  /// URL. It resolves the element at the point stored by the injected
  /// long-press script (window.__xdmLastTouch) and returns {url, type}.
  static const String _longPressTargetFallbackJs = '''
(function() {
  try {
    var sel = window.getSelection();
    if (sel && sel.rangeCount > 0) {
      var anchor = sel.anchorNode ? (sel.anchorNode.nodeType === 3 ? sel.anchorNode.parentNode : sel.anchorNode) : null;
      var a = anchor ? anchor.closest('a[href]') : null;
      if (a && a.href) return JSON.stringify({ url: a.href, type: 'link' });
    }
  } catch (e) {}
  try {
    var p = window.__xdmLastTouch;
    if (p && typeof p.x === 'number' && typeof p.y === 'number') {
      var el = document.elementFromPoint(p.x, p.y);
      if (el) {
        var a2 = el.closest('a[href]') || el.closest('area[href]');
        if (a2 && a2.href) return JSON.stringify({ url: a2.href, type: 'link' });
        var img = el.closest('img');
        if (img) return JSON.stringify({ url: img.currentSrc || img.src || '', type: 'image' });
        var v = el.closest('video');
        if (v) return JSON.stringify({ url: v.currentSrc || v.src || '', type: 'video' });
        var au = el.closest('audio');
        if (au) return JSON.stringify({ url: au.currentSrc || au.src || '', type: 'audio' });
      }
    }
  } catch (e) {}
  return '';
})()
''';

  // ─────────────────────────────────────────────────────────────
  // Tab persistence
  // ─────────────────────────────────────────────────────────────
  Future<void> _saveTabs() => _tabManager.saveTabs();

  final List<String> _lruTabIds = [];
  final Map<String, Timer> _loadingTimeoutTimers = {};
  Timer? _siteSettingsReloadTimer;

  void _debouncedSiteSettingsReload(BrowserTab tab) {
    _siteSettingsReloadTimer?.cancel();
    _siteSettingsReloadTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) {
        tab.controller?.reload();
      }
    });
  }

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
    final settings = _settings;
    final cap = (settings.maxTabs ~/ 4).clamp(3, 6);
    if (_lruTabIds.length > cap) {
      _lruTabIds.removeRange(cap, _lruTabIds.length);
    }
  }

  void _onTabSwitched(int oldIndex, int newIndex) {
    _scriptsInjectedSnackbarShown = false;
    // Fix #10: Counters are now per-tab Maps, so we only need to trigger a
    // rebuild so the URL bar badge reads the new tab's values. No reset needed.
    setState(() {});

    if (oldIndex >= 0 && oldIndex < _tabs.length && oldIndex != newIndex) {
      final oldTab = _tabs[oldIndex];
      _pauseTabMedia(oldTab);
    }
    if (newIndex >= 0 && newIndex < _tabs.length) {
      final newTab = _tabs[newIndex];
      newTab.lastVisitedAt = DateTime.now().millisecondsSinceEpoch;
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

  void _scrollToActiveTabStrip() {
    if (!_tabStripScrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tabStripScrollController.hasClients) return;
      final maxExtent = _tabStripScrollController.position.maxScrollExtent;
      final targetOffset = (_currentTabIndex * 100.0).clamp(0.0, maxExtent);
      _tabStripScrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  void _switchTab(int newIndex) {
    if (newIndex == _currentTabIndex && _tabs.isNotEmpty) return;
    final oldIndex = _currentTabIndex;
    setState(() {
      _currentTabIndex = newIndex;
      _homeReturnUrl = null; // Clear stale URL from previous tab's back-to-home
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
    _scrollToActiveTabStrip();
    _saveTabs();
    _suspendBackgroundTabs();
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

  bool _showTabTooltip = false;

  void _checkOnboardingTooltip() async {
    final prefs = await SharedPreferences.getInstance();
    final hasSeen = prefs.getBool('has_seen_tab_tooltip') ?? false;
    if (!hasSeen && mounted) {
      setState(() => _showTabTooltip = true);
    }
  }

  void _dismissTabTooltip() async {
    if (_showTabTooltip) {
      setState(() => _showTabTooltip = false);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('has_seen_tab_tooltip', true);
    }
  }

  void _animateFlyingStar() {
    if (!mounted) return;
    final overlayState = Overlay.of(context);
    final size = MediaQuery.of(context).size;
    final startOffset = Offset(size.width - 60, 60.0);
    final endOffset = Offset(size.width * 0.5, size.height - 80.0);

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) {
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 650),
          curve: Curves.easeInOutCubic,
          onEnd: () => entry.remove(),
          builder: (context, val, child) {
            final currentX =
                startOffset.dx + (endOffset.dx - startOffset.dx) * val;
            final currentY = startOffset.dy +
                (endOffset.dy - startOffset.dy) * val +
                sin(val * pi) * -80.0;
            final scale = 1.4 - (val * 0.6);
            final opacity = (1.0 - (val * 0.3)).clamp(0.0, 1.0);

            return Positioned(
              left: currentX,
              top: currentY,
              child: IgnorePointer(
                child: Opacity(
                  opacity: opacity,
                  child: Transform.scale(
                    scale: scale,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: const BoxDecoration(
                        color: Colors.amber,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.amberAccent,
                            blurRadius: 16,
                            spreadRadius: 4,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.star_rounded,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    overlayState.insert(entry);
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
    _loadCustomShortcuts(); // Bug #8 fix: load persisted shortcuts on startup
    UserScriptManager.instance.load();
    _checkOnboardingTooltip();

    _dashboardScrollController.addListener(_onDashboardScroll);
    unawaited(_adBlocker.init());
  }

  Future<void> _updateAdBlockSettings() async {
    if (!mounted) return;
    for (final tab in _tabs) {
      if (tab.controller != null) {
        try {
          final currentSettings = await tab.controller!.getSettings();
          if (currentSettings != null) {
            currentSettings.contentBlockers = _adBlocker.contentBlockers;
            currentSettings.incognito = tab.isIncognito;
            await tab.controller!.setSettings(settings: currentSettings);
          } else {
            await tab.controller!.setSettings(
              settings: InAppWebViewSettings(
                contentBlockers: _adBlocker.contentBlockers,
                incognito: tab.isIncognito,
                userAgent: _settings.desktopMode
                    ? FingerprintManager.desktopUserAgent
                    : _resolveUserAgent(
                        isIncognito: tab.isIncognito, settings: _settings),
              ),
            );
          }
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

  DateTime? _lastInactivityReset;

  void _resetInactivityTimer({bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        _lastInactivityReset != null &&
        now.difference(_lastInactivityReset!).inMilliseconds < 1000) {
      return;
    }
    _lastInactivityReset = now;
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
    TabOrigin origin = TabOrigin.userDirect,
  }) {
    final settings = _settings;
    var cleanInitialUrl = (initialUrl.isEmpty || initialUrl == 'about:blank')
        ? 'about:blank'
        : initialUrl;
    if (settings.httpsOnly && cleanInitialUrl.startsWith('http://')) {
      cleanInitialUrl = cleanInitialUrl.replaceFirst('http://', 'https://');
    }
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
      origin: origin,
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

  Future<void> _applySiteSettings(BrowserTab tab, String url) async {
    if (tab.controller == null) return;
    final settings = _settings;
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    final siteSettings = await SiteSettingsStore.getForHost(host);
    final isDesktop = siteSettings.desktopMode ?? settings.desktopMode;
    final isAdBlock =
        siteSettings.adBlockEnabled ?? AdBlockerService.instance.isEnabled;
    final userAgent = isDesktop
        ? FingerprintManager.desktopUserAgent
        : _resolveUserAgent(isIncognito: tab.isIncognito, settings: settings);
    await tab.controller?.setSettings(
      settings: InAppWebViewSettings(
        useShouldOverrideUrlLoading: true,
        useOnDownloadStart: true,
        userAgent: userAgent,
        supportZoom: isDesktop || settings.pinchToZoom,
        incognito: tab.isIncognito,
        contentBlockers: isAdBlock ? _adBlocker.contentBlockers : [],
        javaScriptEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        supportMultipleWindows: true,
        javaScriptCanOpenWindowsAutomatically: true,
      ),
    );
  }

  void _configureController(BrowserTab tab, InAppWebViewController controller) {
    tab.controller = controller;

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
        if (msg == 'cancel') {
          setState(() {
            _isPickerModeActive = false;
          });
          return;
        }
        _handlePickerMessageForTab(tab, JavaScriptMessage(message: msg));
      },
    );

    // UX 3.19: Form autofill — persist submitted form values per host.
    controller.addJavaScriptHandler(
      handlerName: _autofillChannel,
      callback: (args) {
        final msg = args.isNotEmpty ? args.first.toString() : '';
        _handleAutofillMessage(tab, msg);
      },
    );

    _applySiteSettings(tab, tab.url);
  }

  Future<void> _handleAutofillMessage(BrowserTab tab, String message) async {
    final settings = _settings;
    if (!settings.formAutofill || message.isEmpty) return;
    try {
      final data = jsonDecode(message) as Map<String, dynamic>;
      final fields = data['fields'] as Map<String, dynamic>?;
      final url = data['url'] as String? ?? tab.url;
      if (fields == null || fields.isEmpty) return;
      final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
      if (host.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      final key = 'browser_autofill_$host';
      final existing = prefs.getString(key);
      final Map<String, dynamic> stored =
          existing == null ? {} : jsonDecode(existing) as Map<String, dynamic>;
      for (final entry in fields.entries) {
        final name = entry.key.toLowerCase();
        final value = entry.value.toString();
        if (value.length > 200 || value.length < 2) continue;
        if (name.contains('password') ||
            name.contains('token') ||
            name.contains('secret')) {
          continue;
        }
        if (name.contains('email') ||
            name.contains('user') ||
            name.contains('name')) {
          stored[name] = value;
        } else if (stored.length < 12) {
          stored[name] = value;
        }
      }
      if (stored.isNotEmpty) {
        await prefs.setString(key, jsonEncode(stored));
      }
    } catch (e, st) {
      Logger('browser_screen')
          .warning('[browser_screen] autofill save failed', e, st);
    }
  }

  void _showSiteSettingsSheet(BrowserTab tab) async {
    if (tab.isHome || tab.url.isEmpty) return;
    final uri = Uri.tryParse(tab.url);
    if (uri == null || uri.host.isEmpty) return;
    final host = uri.host.toLowerCase();

    final settings = _settings;
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    final siteSettings = await SiteSettingsStore.getForHost(host);
    bool siteDesktop = siteSettings.desktopMode ?? settings.desktopMode;
    bool siteAdBlock =
        siteSettings.adBlockEnabled ?? AdBlockerService.instance.isEnabled;

    if (!mounted) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                host,
                style: TextStyle(
                  fontFamily: 'Space Grotesk',
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color:
                      isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Site settings overrides',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                ),
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                title: const Text('Desktop Site'),
                subtitle: const Text('Force desktop version of this site'),
                value: siteDesktop,
                activeThumbColor: accent,
                onChanged: (val) async {
                  setSheetState(() => siteDesktop = val);
                  await SiteSettingsStore.updateForHost(
                      host,
                      SiteSettings(
                        desktopMode: siteDesktop,
                        adBlockEnabled: siteAdBlock,
                      ));
                  await _applySiteSettings(tab, tab.url);
                  if (mounted) setState(() {});
                  _debouncedSiteSettingsReload(tab);
                },
              ),
              SwitchListTile(
                title: const Text('AdBlocker'),
                subtitle: const Text('Block ads and trackers on this site'),
                value: siteAdBlock,
                activeThumbColor: accent,
                onChanged: (val) async {
                  setSheetState(() => siteAdBlock = val);
                  await SiteSettingsStore.updateForHost(
                      host,
                      SiteSettings(
                        desktopMode: siteDesktop,
                        adBlockEnabled: siteAdBlock,
                      ));
                  await _applySiteSettings(tab, tab.url);
                  if (mounted) setState(() {});
                  _debouncedSiteSettingsReload(tab);
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  void _onPageStart(BrowserTab tab, String url) async {
    // Do NOT reset (_navigatingBackForwardTabIds[tab.id] ?? false) here. Page lifecycle callbacks
    // (onLoadStart/onLoadStop/onUrlChange) fire BEFORE client-side redirects
    // (e.g. Google search meta-refresh / JS redirects). Resetting the flag
    // here causes shouldOverrideUrlLoading to intercept the redirect and
    // dismiss the page the user is trying to navigate back/forward to.
    // The flag is managed solely by the timed reset in _goBack/_goForward.
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
    } else {
      // Fix #20: Restore the correct UA when navigating away from Google login
      // pages. Without this, the Pixel 8 UA set for accounts.google.com
      // persisted permanently for all subsequent pages in the same tab.
      final settings = _settings;
      unawaited(_applyUserAgent(tab, settings));
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
        if (_currentTabIndex >= 0 &&
            _currentTabIndex < _tabs.length &&
            _tabs[_currentTabIndex].id == tab.id) {
          _urlController.text = tab.url;
        }
        _detectedDownloadUrls.remove(tab.id);
        _detectedPlaylistUrls.remove(tab.id);
        _detectedMediaSources.remove(tab.id);
        _mediaScanFailed.remove(tab.id);
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

    final settings = _settings;
    _injectDesktopModeScript(tab, settings);
    // Fix #4: Re-apply per-site settings on every navigation so that
    // site-specific desktop mode and ad-blocker overrides take effect
    // when the user navigates to a different domain within the same tab.
    unawaited(_applySiteSettings(tab, url));

    _updateNavState();
    _delayed(const Duration(milliseconds: 500), _updateNavState);
  }

  void _onPageStop(BrowserTab tab, String url) {
    _navStateDebounceTimer?.cancel();
    _navStateDebounceTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _updateNavState();
    });
    _loadingTimeoutTimers[tab.id]?.cancel();
    // Do NOT reset _navigatingBackForwardTabIds here. onLoadStop fires BEFORE
    // client-side redirects (meta-refresh, JS redirects). Resetting the flag
    // here causes shouldOverrideUrlLoading to intercept those redirects and
    // dismiss the page the user is navigating back/forward to.
    // The flag is managed solely by the timed reset in _goBack/_goForward.
    final settings = _settings;
    unawaited(_injectAllScripts(tab, url));
    // UX 3.6: Tab favicons — fetch after page load.
    unawaited(_fetchFavicon(tab));
    // UX 3.19: Autofill saved form data for this host.
    unawaited(_autofillFormFields(tab));

    // Fix #6: Corrected operator precedence — previously evaluated as
    // (mounted && _customJs.isNotEmpty) || _customCss.isNotEmpty, which
    // showed the snackbar even when unmounted if CSS was non-empty.
    if (mounted && (_customJs.isNotEmpty || _customCss.isNotEmpty)) {
      _notifyScriptsInjected();
    }

    if (mounted) {
      setState(() {
        tab.isLoading = false;
        tab.isTimedOut = false;
        _detectedDownloadUrls.remove(tab.id);
        _detectedMediaSources.remove(tab.id);
      });
      tab.controller?.getTitle().then((t) {
        if (t != null && t.isNotEmpty && mounted) {
          // Fix #5: Always update the title and record history regardless of
          // whether the title changed. The old `t != tab.title` guard silently
          // skipped history for SPAs and sites where consecutive pages share
          // the same title (e.g. news article feeds with a constant site name).
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
      ''').catchError((_) => null);
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
      // Bug #12 fix: capture the OLD url before setState overwrites tab.url.
      // After the setState below, tab.url == cleanUrl (the new URL), so using
      // tab.url here would remove the new URL's failure entry instead of the
      // old one — a minor memory leak that accumulates stale entries.
      final previousUrl = tab.url;
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
      _mediaScanFailed.remove(tab.id);
      _ytDetectionFailed.remove(previousUrl);

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

  final Map<String, Timer> _mediaScanDebouncePerTab = {};

  void _scheduleMediaScan(BrowserTab tab) {
    // per-tab media scan debounce used
    final tabId = tab.id;
    _mediaScanDebouncePerTab[tabId]?.cancel();
    _mediaScanDebouncePerTab[tabId] = Timer(const Duration(seconds: 3), () {
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
      // Fix #3: Keep recently-used tabs (top 3 in the LRU list) alive.
      // Only suspend tabs that haven't been visited recently, so switching
      // back to a recent tab is instant rather than requiring a full reload.
      if (_lruTabIds.contains(tab.id)) continue;
      try {
        tab.controller?.evaluateJavascript(source: '''
          try { window.stop(); } catch(e) {}
          var media = document.querySelectorAll('video, audio');
          for (var m = 0; m < media.length; m++) { try { media[m].pause(); } catch(e) {} }
          if (window.__xdmScrollFixInterval) { clearInterval(window.__xdmScrollFixInterval); window.__xdmScrollFixInterval = null; }
          if (window.__xdmYtAdInterval) { clearInterval(window.__xdmYtAdInterval); window.__xdmYtAdInterval = null; }
        ''').catchError((_) => null);
      } catch (_) {}
      tab.isSuspended = true;
      tab.controller = null;
      // Bug #3 fix: null out the PRC so that _resumeTab's ?= guard
      // re-creates a fresh controller. Without this, the framework disposes
      // the PRC when the InAppWebView widget is unmounted, but the stale
      // (disposed) reference remains, causing
      // "AndroidPullToRefreshController was used after being disposed".
      tab.pullToRefreshController = null;
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
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        setState(() {
          _restoringTabId = null;
        });
      }
    });

    _safeReloadTab(tab);
  }

  Future<void> _injectAllScripts(BrowserTab tab, String url) async {
    final settings = _settings;
    await _scriptInjector.injectAllScripts(
      tab,
      url,
      settings: settings,
      adBlocker: AdBlockerService.instance,
      customJs: _customJs,
      customCss: _customCss,
    );
  }

  /// UX 3.6: Resolves the tab's favicon URL and downloads its bytes so the
  /// tab switcher / strip can render a favicon instead of a generic icon.
  Future<void> _fetchFavicon(BrowserTab tab) async {
    if (tab.isHome || tab.isIncognito) return;
    final controller = tab.controller;
    if (controller == null) return;
    String? faviconUrl;
    try {
      final favicons = await controller.getFavicons();
      if (favicons.isNotEmpty) {
        faviconUrl = favicons.first.url.toString();
      }
    } catch (_) {}
    if (faviconUrl == null) {
      try {
        final res = await controller.evaluateJavascript(source: '''
          (function() {
            var l = document.querySelector('link[rel~="icon"]') ||
                    document.querySelector('link[rel="shortcut icon"]');
            return l ? (l.href || '') : '';
          })();
        ''');
        final s = res?.toString().trim() ?? '';
        if (s.isNotEmpty && s != 'null') {
          if (s.startsWith('//')) {
            faviconUrl = 'https:$s';
          } else if (s.startsWith('/')) {
            final base = Uri.tryParse(tab.url);
            if (base != null && base.host.isNotEmpty) {
              faviconUrl = '${base.scheme}://${base.host}$s';
            } else {
              faviconUrl = s;
            }
          } else {
            faviconUrl = s;
          }
        }
      } catch (_) {}
    }
    if (faviconUrl == null || faviconUrl.isEmpty) return;
    tab.faviconUrl = faviconUrl;
    HttpClient? httpClient;
    try {
      httpClient = HttpClient()..connectionTimeout = const Duration(seconds: 4);
      final req = await httpClient.getUrl(Uri.parse(faviconUrl));
      final resp = await req.close().timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final chunks = await resp
            .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
        final bytes = Uint8List.fromList(chunks);
        if (bytes.isNotEmpty && mounted) {
          setState(() {
            tab.faviconBytes = bytes;
          });
        }
      }
    } catch (_) {
      // Favicon download is best-effort; the tab falls back to the globe icon.
    } finally {
      // Always close the HttpClient — even if an exception was thrown —
      // to prevent socket/connection leaks across many page loads.
      httpClient?.close(force: false);
    }
  }

  /// UX 3.19: Injects saved autofill data (if any) into the current page.
  Future<void> _autofillFormFields(BrowserTab tab) async {
    final settings = _settings;
    if (!settings.formAutofill || tab.isHome || tab.url.isEmpty) return;
    final host = Uri.tryParse(tab.url)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('browser_autofill_$host');
      if (raw == null || raw.isEmpty) return;
      final stored = jsonDecode(raw) as Map<String, dynamic>;
      final fields = stored.map((k, v) => MapEntry(k, v.toString()));
      if (fields.isEmpty) return;
      final script = ScriptInjector.buildAutofillScript(fields);
      if (script.isEmpty) return;
      await tab.controller?.evaluateJavascript(source: script);
    } catch (e, st) {
      Logger('browser_screen')
          .warning('[browser_screen] autofill injection failed', e, st);
    }
  }

  void _cleanupTabState(String tabId) {
    _mediaScanDebouncePerTab[tabId]?.cancel();
    _mediaScanDebouncePerTab.remove(tabId);
    _navigatingBackForwardTabIds.remove(tabId);
    _sniffer.cleanupTab(tabId);
    _detectedDownloadUrls.remove(tabId);
    _detectedMediaSources.remove(tabId);
    _mediaScanFailed.remove(tabId);
    _loadingTimeoutTimers[tabId]?.cancel();
    _loadingTimeoutTimers.remove(tabId);
    // Fix #10: Clean up per-tab counter maps when a tab is closed.
    final adNotifier = _blockedAdsNotifiers[tabId];
    _blockedAdsNotifiers.remove(tabId);
    _blockedAdsPerTab.remove(tabId);
    _blockedPopupsPerTab.remove(tabId);
    if (adNotifier != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => adNotifier.dispose());
    }

    final tabIndex = _tabs.indexWhere((t) => t.id == tabId);
    if (tabIndex != -1) {
      final tab = _tabs[tabIndex];
      if (tab.isIncognito) {
        // Defer cleanup to the next frame so the WebView widget is still alive
        // when the platform-channel calls are made. Calling clearAllCache() or
        // evaluateJavascript() synchronously while the InAppWebView widget is
        // being removed from the tree causes MissingPluginException.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          try {
            InAppWebViewController.clearAllCache();
          } catch (_) {}
          try {
            tab.controller
                ?.evaluateJavascript(
                    source:
                        'window.localStorage.clear(); window.sessionStorage.clear();')
                .catchError((_) => null);
          } catch (_) {}
          if (tab.url.isNotEmpty && tab.url != 'about:blank') {
            try {
              CookieManager.instance().deleteCookies(url: WebUri(tab.url));
            } catch (_) {}
          }
        });
      }
    }
  }

  /// UX 3.5: Pushes a recently-closed tab onto the bounded history list.
  void _recordClosedTab(BrowserTab tab) {
    if (tab.isHome || tab.url.isEmpty || tab.url == 'about:blank') return;
    _recentlyClosedTabs.insert(
      0,
      _ClosedTab(
        url: tab.url,
        title: tab.title,
        isIncognito: tab.isIncognito,
        closedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (_recentlyClosedTabs.length > _maxRecentClosedTabs) {
      _recentlyClosedTabs.removeRange(
          _maxRecentClosedTabs, _recentlyClosedTabs.length);
    }
  }

  /// UX 3.5: Bottom sheet listing tabs closed during this session.
  void _showRecentlyClosedSheet() {
    final settings = _settings;
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final isRtl = L10n.isRtl(context);

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          Icon(Icons.restore_rounded, color: accent, size: 18),
                          const SizedBox(width: 10),
                          Text(
                            isRtl
                                ? 'التبويبات المغلقة مؤخراً'
                                : 'Recently closed tabs',
                            style: TextStyle(
                              color: isDark
                                  ? AppTheme.textPrimary
                                  : AppTheme.lightTextPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          if (_recentlyClosedTabs.isNotEmpty)
                            TextButton(
                              onPressed: () {
                                setSheetState(() {
                                  _recentlyClosedTabs.clear();
                                });
                              },
                              child: Text(
                                isRtl ? 'مسح' : 'Clear',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_recentlyClosedTabs.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(32),
                        child: Center(
                          child: Text(
                            isRtl
                                ? 'لا توجد تبويبات مغلقة'
                                : 'No closed tabs yet',
                            style: TextStyle(
                              color: isDark
                                  ? AppTheme.textMuted
                                  : AppTheme.lightTextMuted,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      )
                    else
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: _recentlyClosedTabs.length,
                          itemBuilder: (context, index) {
                            final closed = _recentlyClosedTabs[index];
                            return ListTile(
                              leading: Icon(
                                closed.isIncognito
                                    ? Icons.visibility_off_rounded
                                    : Icons.web_asset_rounded,
                                color: closed.isIncognito
                                    ? AppTheme.neonViolet
                                    : accent,
                                size: 20,
                              ),
                              title: Text(
                                closed.title.isEmpty
                                    ? closed.url
                                    : closed.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                              subtitle: Text(
                                closed.url,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 11, fontFamily: 'monospace'),
                              ),
                              trailing: const Icon(Icons.restore_rounded,
                                  size: 18, color: AppTheme.neonBlue),
                              onTap: () {
                                Navigator.pop(sheetContext);
                                setSheetState(() {
                                  _recentlyClosedTabs.removeAt(index);
                                });
                                _openInNewTab(
                                  closed.url,
                                  isIncognito: closed.isIncognito,
                                  switchToTab: true,
                                  origin: TabOrigin.userDirect,
                                );
                              },
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
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
      final settings = _settings;
      triggerHaptic(settings);
      _showLongPressSheet(context, url, type,
          text: payload.text, tabId: tab.id);
    } catch (e) {
      _log.warning(
        '[DMX Browser] Failed to decode/handle long press message: $e',
      );
    }
  }

  /// Parses the {url, type} JSON returned by [_longPressTargetFallbackJs].
  static (String, String)? _parseLongPressTarget(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.isEmpty || s == 'null') return null;
    try {
      final decoded = jsonDecode(s);
      if (decoded is Map<String, dynamic>) {
        final url = (decoded['url'] as String?)?.trim() ?? '';
        if (url.isEmpty) return null;
        return (url, (decoded['type'] as String?) ?? 'link');
      }
    } on FormatException {
      // Some platforms return the string quoted, unwrap it.
    }
    try {
      final unquoted = jsonDecode(s.substring(1, s.length - 1));
      if (unquoted is Map<String, dynamic>) {
        final url = (unquoted['url'] as String?)?.trim() ?? '';
        if (url.isEmpty) return null;
        return (url, (unquoted['type'] as String?) ?? 'link');
      }
    } catch (_) {}
    return null;
  }

  void _handlePopupMessageForTab(
    BrowserTab parentTab,
    JavaScriptMessage message,
  ) {
    if (!mounted) return;
    final url = message.message.trim();
    if (url.isEmpty || url == 'about:blank') return;

    if (_recentDownloadUrls.contains(url)) {
      _log.info(
          '[Browser] Popup URL ignored because it was already handled as a download: $url');
      return;
    }

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
      // Fix #8: Increment the per-tab popup counter so the badge in the URL
      // bar reflects the number of blocked popups for this tab.
      setState(() {
        final tabId = parentTab.id;
        _blockedPopupsPerTab[tabId] = (_blockedPopupsPerTab[tabId] ?? 0) + 1;
      });
      _followAndInterceptAdRedirect(url, parentTab);
      return;
    }

    // 4. Open popup URL in background tab (Popup Blocking Disabled).
    // We intentionally do NOT switch focus — ad/popup tabs must not
    // interrupt the page the user is currently reading.
    _log.info('[Browser] Opening popup URL in background tab: $url');
    _evictStaleAdTabs();
    setState(() {
      final newTab = _createNewTab(
        initialUrl: url,
        isIncognito: parentTab.isIncognito,
        origin: TabOrigin.adOrPopup,
      );
      _redirectGuard.reset(newTab.id);
      _tabs.add(newTab);
    });
    _saveTabs();
    if (mounted) {
      final settings = _settings;
      final isDark = settings.isDarkMode;
      final isRtl = L10n.isRtl(context);
      ThemedSnackbar.show(
        context,
        message: isRtl
            ? 'تم فتح علامة تبويب في الخلفية'
            : 'Opened in background tab',
        color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
        icon: Icons.tab_rounded,
        isDarkMode: isDark,
      );
    }
  }

  /// Silently follows HTTP redirects from a blocked ad popup URL.
  /// If the redirect chain ends at a downloadable file (APK, ZIP, video, etc.)
  /// the XDM download sheet is shown instead of opening a tab.
  /// If it ends at a download gateway host/page, opens it in a tab.
  Future<void> _followAndInterceptAdRedirect(
      String adUrl, BrowserTab parentTab) async {
    try {
      final referer = parentTab.url.isNotEmpty ? parentTab.url : adUrl;
      final check =
          await _interceptor.verifyContentType(adUrl, referer: referer);
      final finalUrl = check.finalUrl;
      final contentType = check.contentType;
      final contentDisposition = check.contentDisposition;

      final isDownload = contentDisposition.contains('attachment') ||
          contentType.contains('application/octet-stream') ||
          contentType.contains('application/vnd.android.package-archive') ||
          contentType.contains('application/zip') ||
          contentType.contains('application/x-zip') ||
          contentType.contains('application/x-rar') ||
          contentType.contains('video/') ||
          contentType.contains('audio/') ||
          BrowserDetector.isAutoDownloadable(finalUrl) ||
          BrowserDetector.isAutoDownloadable(adUrl) ||
          _interceptor.shouldIntercept(
              tabUrl: parentTab.url, requestUrl: finalUrl);

      if (isDownload && mounted) {
        _log.info(
            '[Browser] Ad redirect resolved to download: $finalUrl (type: $contentType)');
        _showInterceptionSheet(context, finalUrl);
        return;
      }

      // Allowlist check: if allowlisted, bypass ad blocking and open in tab
      final service = AdBlockerService.instance;
      final isAllowlisted =
          service.isAllowListed(finalUrl) || service.isAllowListed(adUrl);

      // 3. If popup landed on an ad page or blocked domain, drop it (unless allowlisted)
      final isAdBlocked = !isAllowlisted &&
          (_adBlocker.shouldBlock(finalUrl) || _adBlocker.shouldBlock(adUrl));
      if (isAdBlocked) {
        _log.info(
            '[Browser] Ad redirect resolved to blocked ad page: $finalUrl');
        return;
      }

      // 4. If popup landed on a legitimate file host / download gateway, open in tab
      final lowerFinal = finalUrl.toLowerCase();
      final isKnownFileHost = lowerFinal.contains('dlhaven') ||
          lowerFinal.contains('mediafire') ||
          lowerFinal.contains('mega.nz') ||
          lowerFinal.contains('pixeldrain') ||
          lowerFinal.contains('gofile') ||
          lowerFinal.contains('workupload') ||
          lowerFinal.contains('1fichier');

      if (isKnownFileHost && mounted) {
        _log.info(
            '[Browser] Ad redirect was legitimate file host, opening background tab: $finalUrl');
        _evictStaleAdTabs();
        setState(() {
          final newTab = _createNewTab(
            initialUrl: finalUrl,
            isIncognito: parentTab.isIncognito,
            origin: TabOrigin.redirect,
          );
          _redirectGuard.reset(newTab.id);
          _tabs.add(newTab);
        });
        _saveTabs();
        if (mounted) {
          final settings = _settings;
          final isDark = settings.isDarkMode;
          final isRtl = L10n.isRtl(context);
          ThemedSnackbar.show(
            context,
            message: isRtl
                ? 'تم فتح علامة تبويب في الخلفية'
                : 'Opened in background tab',
            color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
            icon: Icons.tab_rounded,
            isDarkMode: isDark,
          );
        }
      }
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
    setState(() {
      _isPickerModeActive = false;
    });
    _confirmBlockElement(tab, selector.trim());
  }

  void _confirmBlockElement(BrowserTab tab, String selector) {
    final settings = _settings;
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

  void _openInNewTab(
    String url, {
    bool isIncognito = false,
    bool switchToTab = false,
    TabOrigin origin = TabOrigin.userDirect,
  }) {
    if (!mounted || url.isEmpty) return;
    if (url.startsWith('magnet:') || isMagnetUrl(url)) {
      _log.info('[Browser] Intercepted magnet URL in _openInNewTab: $url');
      AddDownloadDialog.show(context, prefilledUrl: url);
      return;
    }
    setState(() {
      final newTab = _createNewTab(
        initialUrl: url,
        isIncognito: isIncognito,
        origin: origin,
      );
      _redirectGuard.reset(newTab.id);
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
    final settings = _settings;
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
    final settings = _settings;
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

  /// Maximum number of never-visited ad/popup/redirect background tabs allowed
  /// before the oldest one is silently evicted.
  static const int _maxUnvisitedAdTabs = 3;

  /// Silently removes the oldest [TabOrigin.adOrPopup] / [TabOrigin.redirect]
  /// background tabs when their count is at or above [_maxUnvisitedAdTabs],
  /// ensuring ad popups cannot fill all available tab slots.
  ///
  /// [TabOrigin.userDirect] tabs are NEVER touched by this method.
  ///
  /// Call this inside or just before the [setState] that adds a new
  /// ad/popup/redirect tab.
  void _evictStaleAdTabs() {
    final activeId = (_currentTabIndex >= 0 && _currentTabIndex < _tabs.length)
        ? _tabs[_currentTabIndex].id
        : null;

    // Collect background ad/redirect tabs, sorted oldest-first.
    final candidates = _tabs
        .where((t) =>
            (t.origin == TabOrigin.adOrPopup ||
                t.origin == TabOrigin.redirect) &&
            t.id != activeId)
        .toList()
      ..sort((a, b) => a.lastVisitedAt.compareTo(b.lastVisitedAt));

    while (candidates.length >= _maxUnvisitedAdTabs) {
      final oldest = candidates.removeAt(0);
      _log.info('[Browser] Evicting stale ad/popup tab: ${oldest.url}');
      _cleanupTabState(oldest.id);
      // Bug #6 fix: if the evicted tab was BEFORE the current index, the
      // remaining tabs shift left by one, so we must decrement the index.
      // The old code only handled the case where currentTabIndex was past
      // the end of the list (tabs removed after current).
      final evictedIndex = _tabs.indexOf(oldest);
      _tabs.remove(oldest);
      if (evictedIndex >= 0 && evictedIndex < _currentTabIndex) {
        // Shift current index down to keep pointing at the same tab.
        _currentTabIndex = _currentTabIndex - 1;
      } else if (_currentTabIndex >= _tabs.length) {
        _currentTabIndex = _tabs.length - 1;
      }
      // Dispose AFTER the frame so the InAppWebView widget has already
      // been unmounted — prevents double-dispose of pullToRefreshController.
      WidgetsBinding.instance.addPostFrameCallback((_) => oldest.dispose());
    }
  }

  void _onDashboardScroll() {
    if (!_dashboardScrollController.hasClients) return;
    final y = _dashboardScrollController.offset;
    _handleScroll(y);
  }

  int _lastScrollTimeMs = 0;
  bool? _lastNavbarVisible;

  void _handleScroll(double y) {
    if (!mounted) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastScrollTimeMs < 16) return;
    _lastScrollTimeMs = now;

    final downloadProvider = Provider.of<DownloadProvider>(
      context,
      listen: false,
    );
    if (downloadProvider.activeTabIndex != 1) return;

    _showBarsNotifier.value = true;
    bool shouldShow = true;
    if (y <= 0 || y < _lastScrollY) {
      shouldShow = true;
    } else if (y - _lastScrollY > 40) {
      shouldShow = false;
    }

    if (_lastNavbarVisible != shouldShow) {
      _lastNavbarVisible = shouldShow;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          downloadProvider.setNavbarVisible(shouldShow);
        }
      });
    }
    _lastScrollY = y;
  }

  void _delayed(Duration duration, VoidCallback callback) =>
      _tabManager.delayed(duration, callback);

  @override
  void dispose() {
    _siteSettingsReloadTimer?.cancel();
    _showBarsNotifier.dispose();
    _tabStripScrollController.dispose();
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
          tab.controller
              ?.evaluateJavascript(
                  source:
                      'window.localStorage.clear(); window.sessionStorage.clear();')
              .catchError((_) => null);
        } catch (_) {/* ignore: clearing cache/storage on close */}
      }
      try {
        tab.dispose();
      } catch (_) {/* ignore: disposing tab may already be disposed */}
    }

    _tabManager.clearAllTabs();
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
      // Bug #4 fix: the widget may be disposed while awaiting SharedPreferences.
      // Guard with mounted (matching the pattern used by _loadSnifferPref).
      if (!mounted) return;
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

  /// Unified back handler — single source of truth for both the toolbar back
  /// button and [PopScope.onPopInvokedWithResult].
  ///
  /// Decision order:
  /// (a) WebView can go back → go back in it.
  /// (b) Tab has no history AND origin != userDirect → close the tab, return
  ///     to the previous tab, show an Undo snackbar.
  /// (c) Tab is not Home → navigate to the tab's Home dashboard.
  /// (d) Already Home → no-op (handled by the PopScope exit logic).
  ///
  /// Returns `true` if it handled the back action, `false` if the caller
  /// should fall through to exit/switch logic.
  Future<bool> _goBack() async {
    if (_tabs.isEmpty ||
        _currentTabIndex < 0 ||
        _currentTabIndex >= _tabs.length) {
      return false;
    }
    final activeTab = _tabs[_currentTabIndex];

    // (a) WebView can go back.
    if (activeTab.canGoBack && activeTab.controller != null) {
      _homeReturnUrl = null;
      if (_tabs.isNotEmpty &&
          _currentTabIndex >= 0 &&
          _currentTabIndex < _tabs.length) {
        _navigatingBackForwardTabIds[_tabs[_currentTabIndex].id] = true;
      }
      unawaited(activeTab.controller?.goBack() ?? Future.value());
      Future.delayed(const Duration(seconds: 5), () {
        if (mounted) {
          if (_tabs.isNotEmpty &&
              _currentTabIndex >= 0 &&
              _currentTabIndex < _tabs.length) {
            _navigatingBackForwardTabIds[_tabs[_currentTabIndex].id] = false;
          }
        }
      });
      _updateNavState();
      return true;
    }

    // Also async-check with the controller in case the cached flag is stale.
    final webCanGoBack = await activeTab.controller?.canGoBack() ?? false;
    if (webCanGoBack && activeTab.controller != null) {
      _homeReturnUrl = null;
      if (_tabs.isNotEmpty &&
          _currentTabIndex >= 0 &&
          _currentTabIndex < _tabs.length) {
        _navigatingBackForwardTabIds[_tabs[_currentTabIndex].id] = true;
      }
      unawaited(activeTab.controller?.goBack() ?? Future.value());
      Future.delayed(const Duration(seconds: 5), () {
        if (mounted) {
          if (_tabs.isNotEmpty &&
              _currentTabIndex >= 0 &&
              _currentTabIndex < _tabs.length) {
            _navigatingBackForwardTabIds[_tabs[_currentTabIndex].id] = false;
          }
        }
      });
      _updateNavState();
      return true;
    }

    // (b) No WebView history AND this is an ad/popup/redirect tab → close it.
    if (!activeTab.isHome && activeTab.origin != TabOrigin.userDirect) {
      final closedUrl = activeTab.url;
      final closedIsIncognito = activeTab.isIncognito;
      final closedOrigin = activeTab.origin;
      final closedIdx = _currentTabIndex;

      final tabToDispose = activeTab;
      setState(() {
        _recordClosedTab(tabToDispose);
        _cleanupTabState(tabToDispose.id);
        _tabs.removeAt(closedIdx);
        if (_currentTabIndex >= _tabs.length) {
          _tabManager.currentIndex = _tabs.length - 1;
        }
        if (_tabs.isEmpty) {
          _tabs.add(_createNewTab());
          _tabManager.currentIndex = 0;
        }
        final nowActive = _tabs[_currentTabIndex];
        _urlController.text = nowActive.isHome ? '' : nowActive.url;
      });
      // Dispose AFTER the frame — widget is now unmounted, no double-dispose.
      WidgetsBinding.instance
          .addPostFrameCallback((_) => tabToDispose.dispose());
      _switchToPreviousTab();
      _saveTabs();

      // Undo snackbar — re-creates the tab at the same URL if tapped.
      if (mounted) {
        final settings = context.read<SettingsProvider>();
        final isDark = settings.isDarkMode;
        final isRtl = L10n.isRtl(context);
        ThemedSnackbar.show(
          context,
          message: isRtl ? 'تم إغلاق علامة التبويب' : 'Tab closed',
          color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
          icon: Icons.tab_rounded,
          isDarkMode: isDark,
          actionLabel: isRtl ? 'تراجع' : 'UNDO',
          onAction: () {
            if (!mounted) return;
            _evictStaleAdTabs();
            setState(() {
              final restored = _createNewTab(
                initialUrl: closedUrl,
                isIncognito: closedIsIncognito,
                origin: closedOrigin,
              );
              _redirectGuard.reset(restored.id);
              _tabs.add(restored);
              _currentTabIndex = _tabs.length - 1;
              _urlController.text = closedUrl;
              _showBarsNotifier.value = true;
            });
            _saveTabs();
          },
        );
      }
      return true;
    }

    // (c) Not Home → send tab to its Home dashboard.
    // Keep the URL intact so forward navigation can restore the page
    // without needing _homeReturnUrl to reload it from scratch.
    if (!activeTab.isHome && activeTab.url.isNotEmpty) {
      if (mounted) {
        _homeReturnUrl = activeTab.url;
        setState(() {
          activeTab.isHome = true;
          activeTab.canGoBack = false;
          activeTab.canGoForward = true;
          activeTab.controller = null;
          _urlController.clear();
        });
      }
      return true;
    }

    // (d) Already Home — caller handles exit / tab-switch fallback.
    return false;
  }

  bool _switchToPreviousTab() {
    _tabIdHistory.removeWhere((id) => !_tabs.any((t) => t.id == id));
    if (_tabIdHistory.isNotEmpty) {
      final prevId = _tabIdHistory.removeLast();
      final idx = _tabs.indexWhere((t) => t.id == prevId);
      if (idx != -1) {
        _switchTab(
            idx); // Fix: Delegate to _switchTab to handle all side effects
        return true;
      }
    }
    return false;
  }

  void _switchToTabRelative(int offset) {
    if (_tabs.length <= 1) return;
    final settings = _settings;
    triggerHaptic(settings);
    // Bug #1 fix: Dart's % operator returns negative values for negative
    // operands (e.g. (-1) % 3 == -1). Double-modulo ensures a positive index
    // so swiping left on tab 0 correctly wraps to the last tab.
    final newIndex =
        ((_currentTabIndex + offset) % _tabs.length + _tabs.length) %
            _tabs.length;
    _switchTab(
        newIndex); // Fix: Delegate to _switchTab to handle all side effects
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
      _homeReturnUrl = null;
      if (mounted) {
        _redirectGuard.reset(activeTab.id);
        setState(() {
          activeTab.isHome = false;
          _urlController.text = activeTab.url;
        });
        _delayed(const Duration(milliseconds: 300), _updateNavState);
      }
      return;
    }

    if (_tabs.isNotEmpty &&
        _currentTabIndex >= 0 &&
        _currentTabIndex < _tabs.length) {
      _navigatingBackForwardTabIds[_tabs[_currentTabIndex].id] = true;
    }
    unawaited(activeTab.controller?.goForward() ?? Future.value());
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) {
        if (_tabs.isNotEmpty &&
            _currentTabIndex >= 0 &&
            _currentTabIndex < _tabs.length) {
          _navigatingBackForwardTabIds[_tabs[_currentTabIndex].id] = false;
        }
      }
    });
    _updateNavState();
  }

  void _navigateToUrl(String input) {
    if (_tabs.isNotEmpty &&
        _currentTabIndex >= 0 &&
        _currentTabIndex < _tabs.length) {
      _navigatingBackForwardTabIds[_tabs[_currentTabIndex].id] = false;
    }
    var url = input.trim();
    if (url.isEmpty) return;

    final settings = _settings;
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
      url = '$searchPrefix${Uri.encodeComponent(url)}';
    } else {
      url = 'https://$url';
    }

    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
    final activeTab = _tabs[_currentTabIndex];
    _redirectGuard.reset(activeTab.id);
    final parsed = Uri.tryParse(url);
    var targetUrl = parsed != null ? parsed.toString() : url;
    if (settings.httpsOnly && targetUrl.startsWith('http://')) {
      targetUrl = targetUrl.replaceFirst('http://', 'https://');
    }

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
      case 'browser_settings':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => BrowserSettingsScreen(
              isSnifferEnabled: _isSnifferEnabled,
              onSnifferChanged: (val) =>
                  setState(() => _isSnifferEnabled = val),
            ),
          ),
        );
        break;
      case 'bookmark':
        final currentUrl = _urlController.text.trim();
        if (currentUrl.isEmpty) return;
        try {
          mediumPulse(settings);
          _animateFlyingStar();
          final db = context.read<DatabaseService>();
          await db.saveBookmark(
            Bookmark(
              id: const Uuid().v4(),
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
        // Fix #22: Share the actual current page URL, not the URL bar text.
        // _urlController.text may contain a half-typed query that has not been
        // navigated to yet; activeTab.url is always the committed page URL.
        final url = activeTab.url.isNotEmpty
            ? activeTab.url
            : _urlController.text.trim();
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
          // Fix #15: Apply UA to all tabs so future requests use the right agent,
          // but only reload the active tab. Background tabs will reload naturally
          // on next activation and _applySiteSettings will re-evaluate desktop mode.
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
          if (!activeTab.isHome) {
            await _safeReloadTab(activeTab);
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
      case 'block_images':
        await settings.setBlockImages(!settings.blockImages);
        if (mounted) {
          ThemedSnackbar.show(
            context,
            message: settings.blockImages
                ? 'Images blocked — reloading page'
                : 'Images visible — reloading page',
            color: settings.isDarkMode
                ? AppTheme.neonViolet
                : AppTheme.lightNeonViolet,
            icon: settings.blockImages
                ? Icons.image_not_supported_rounded
                : Icons.image_rounded,
            isDarkMode: settings.isDarkMode,
          );
          if (!activeTab.isHome) {
            await _safeReloadTab(activeTab);
          }
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
      case 'find':
        _openFindPanel();
        break;
      case 'force_dark':
        await _toggleForceDark(activeTab);
        break;
      case 'clear_data':
        _showClearBrowsingDataDialog();
        break;
      case 'recently_closed':
        _showRecentlyClosedSheet();
        break;
      case 'zoom':
        await _showZoomDialog(activeTab);
        break;
      case 'capture':
        await _capturePage(activeTab);
        break;
      case 'translate':
        await _showTranslateMenu(activeTab);
        break;
      case 'print':
        await _printPage(activeTab);
        break;
      case 'quit':
        await _confirmQuitBrowser();
        break;
    }
  }

  Future<void> _activateReaderMode(BrowserTab activeTab) async {
    final settings = context.read<SettingsProvider>();
    if (activeTab.isHome || activeTab.url.isEmpty) return;
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final controller = activeTab.controller;
    if (controller == null) return;

    final article = await ReaderModeService.extract(controller);
    var ok = false;
    if (article != null && article.content.isNotEmpty) {
      _readerArticle = article;
      _readerTabId = activeTab.id; // Bug #16 fix: store the originating tab ID
      _readerTheme = isDark ? 'dark' : 'light';
      ok = await ReaderModeService.rebuildReaderHtml(
        article,
        (htmlUrl) {
          if (mounted) {
            activeTab.controller
                ?.loadUrl(urlRequest: URLRequest(url: WebUri(htmlUrl)))
                .catchError((e, st) {
              Logger('browser_screen')
                  .warning('[browser_screen] reader mode load failed', e, st);
            });
          }
        },
        fontSize: _readerFontSize,
        theme: _readerTheme,
        fontFamily: _readerFontFamily,
      );
    }

    if (mounted) {
      setState(() {
        _readerControlsVisible = ok;
        if (!ok) {
          _readerArticle = null;
          _readerTabId = null;
        }
      });
      ThemedSnackbar.show(
        context,
        message: ok ? 'Reader mode activated' : 'No article content found',
        color: accent,
        icon: ok ? Icons.menu_book : Icons.error_outline,
        isDarkMode: isDark,
      );
    }
  }

  /// UX 3.2: Rebuilds the reader view with the current appearance settings.
  Future<void> _updateReaderConfig() async {
    final article = _readerArticle;
    if (article == null) return;
    // Bug #16 fix: search for the tab by its originating ID, not current index
    BrowserTab? targetTab;
    for (final t in _tabs) {
      if (t.id == _readerTabId) {
        targetTab = t;
        break;
      }
    }
    if (targetTab == null) return;
    await ReaderModeService.rebuildReaderHtml(
      article,
      (htmlUrl) {
        if (mounted) {
          targetTab!.controller
              ?.loadUrl(urlRequest: URLRequest(url: WebUri(htmlUrl)))
              .catchError((e, st) {
            Logger('browser_screen')
                .warning('[browser_screen] reader config load failed', e, st);
          });
        }
      },
      fontSize: _readerFontSize,
      theme: _readerTheme,
      fontFamily: _readerFontFamily,
    );
  }

  /// UX 3.1: Opens the find-in-page panel for the active tab.
  void _openFindPanel() {
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
    final tab = _tabs[_currentTabIndex];
    if (tab.isHome) return;
    final controller = tab.findInteractionController;
    if (controller == null) return;

    final savedQuery = tab.findQuery ?? '';
    setState(() {
      _findPanelVisible = true;
      _findMatchCount = 0;
      _findActiveMatch = 0;
      _findTextController.text = savedQuery;
      _findTextController.selection = TextSelection.collapsed(
        offset: _findTextController.text.length,
      );
    });
    if (savedQuery.isNotEmpty) {
      controller.findAll(find: savedQuery);
    }
  }

  void _closeFindPanel() {
    if (!mounted) return;
    if (_currentTabIndex >= 0 && _currentTabIndex < _tabs.length) {
      final tab = _tabs[_currentTabIndex];
      try {
        tab.findInteractionController?.clearMatches();
      } catch (_) {}
    }
    setState(() {
      _findPanelVisible = false;
      _findMatchCount = 0;
      _findActiveMatch = 0;
    });
  }

  void _findNext(bool forward) {
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
    final controller = _tabs[_currentTabIndex].findInteractionController;
    if (controller == null) return;
    if (_findMatchCount <= 0) return;
    try {
      controller.findNext(forward: forward);
    } catch (_) {}
  }

  void _updateFindQuery(BrowserTab tab, String query) {
    tab.findQuery = query;
    final controller = tab.findInteractionController;
    if (query.isEmpty) {
      try {
        controller?.clearMatches();
      } catch (_) {}
      setState(() {
        _findMatchCount = 0;
        _findActiveMatch = 0;
      });
      return;
    }
    setState(() {
      _findMatchCount = 0;
      _findActiveMatch = 0;
    });
    try {
      controller?.findAll(find: query);
    } catch (_) {}
  }

  /// UX 3.3: Toggles force-dark mode and applies it to every live tab.
  Future<void> _toggleForceDark(BrowserTab activeTab) async {
    final settings = context.read<SettingsProvider>();
    await settings.setForceDarkMode(!settings.forceDarkMode);
    _applyForceDarkToAll();
    if (mounted) {
      ThemedSnackbar.show(
        context,
        message: settings.forceDarkMode
            ? 'Force dark enabled — reloading page'
            : 'Force dark disabled',
        color: settings.isDarkMode ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
        icon: settings.forceDarkMode
            ? Icons.dark_mode_rounded
            : Icons.light_mode_rounded,
        isDarkMode: settings.isDarkMode,
      );
      if (settings.forceDarkMode && !activeTab.isHome) {
        await _safeReloadTab(activeTab);
      }
    }
  }

  void _applyForceDarkToAll() {
    final settings = _settings;
    for (final tab in _tabs) {
      final controller = tab.controller;
      if (controller == null) continue;
      if (Platform.isAndroid) {
        try {
          controller.setSettings(
            settings: InAppWebViewSettings(
              forceDark: settings.forceDarkMode ? ForceDark.ON : ForceDark.OFF,
              incognito: tab.isIncognito,
            ),
          );
        } catch (_) {}
      } else {
        try {
          final css =
              settings.forceDarkMode ? ScriptInjector.buildForceDarkCss() : '';
          controller.evaluateJavascript(source: '''
            (function() {
              var s = document.getElementById('xdm-force-dark');
              if (${settings.forceDarkMode}) {
                if (!s) {
                  s = document.createElement('style');
                  s.id = 'xdm-force-dark';
                  document.head.appendChild(s);
                }
                s.textContent = ${jsonEncode(css)};
              } else if (s) {
                s.remove();
              }
            })();
          ''').catchError((_) => null);
        } catch (_) {}
      }
    }
  }

  /// UX 3.4: Dialog to clear cache, cookies, history, form data and downloads.
  void _showClearBrowsingDataDialog() {
    final settings = _settings;
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    var cache = true;
    var cookies = true;
    var history = false;
    var formData = true;
    var downloads = false;

    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor:
                  isDark ? AppTheme.surface : AppTheme.lightSurface,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Icon(Icons.cleaning_services_rounded,
                      color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed),
                  const SizedBox(width: 8),
                  Text(
                    isRtl ? 'مسح بيانات التصفح' : 'Clear browsing data',
                    style: const TextStyle(fontSize: 16),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CheckboxListTile(
                    dense: true,
                    value: cache,
                    title: const Text('Cache', style: TextStyle(fontSize: 13)),
                    onChanged: (v) => setDialogState(() => cache = v ?? true),
                  ),
                  CheckboxListTile(
                    dense: true,
                    value: cookies,
                    title: const Text('Cookies & site data',
                        style: TextStyle(fontSize: 13)),
                    onChanged: (v) => setDialogState(() => cookies = v ?? true),
                  ),
                  CheckboxListTile(
                    dense: true,
                    value: history,
                    title: const Text('Browsing history',
                        style: TextStyle(fontSize: 13)),
                    onChanged: (v) =>
                        setDialogState(() => history = v ?? false),
                  ),
                  CheckboxListTile(
                    dense: true,
                    value: formData,
                    title: const Text('Autofill form data',
                        style: TextStyle(fontSize: 13)),
                    onChanged: (v) =>
                        setDialogState(() => formData = v ?? true),
                  ),
                  CheckboxListTile(
                    dense: true,
                    value: downloads,
                    title: const Text('Completed downloads (DB records)',
                        style: TextStyle(fontSize: 13)),
                    onChanged: (v) =>
                        setDialogState(() => downloads = v ?? false),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(isRtl ? 'إلغاء' : 'Cancel'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor:
                        isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                  ),
                  onPressed: () {
                    Navigator.pop(dialogContext);
                    _clearBrowsingData(
                        cache: cache,
                        cookies: cookies,
                        history: history,
                        formData: formData,
                        downloads: downloads);
                  },
                  child: Text(isRtl ? 'مسح' : 'Clear'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _clearBrowsingData({
    required bool cache,
    required bool cookies,
    required bool history,
    required bool formData,
    required bool downloads,
  }) async {
    final settings = _settings;
    final isDark = settings.isDarkMode;
    final db = context.read<DatabaseService>();
    final provider = context.read<DownloadProvider>();
    try {
      if (cache) {
        await InAppWebViewController.clearAllCache();
      }
      if (cookies) {
        await CookieManager.instance().deleteAllCookies();
      }
      if (history) {
        await db.clearBrowserHistoryBefore(DateTime.now());
      }
      if (formData) {
        final prefs = await SharedPreferences.getInstance();
        final keys = prefs
            .getKeys()
            .where((k) => k.startsWith('browser_autofill_'))
            .toList();
        for (final key in keys) {
          await prefs.remove(key);
        }
      }
      if (downloads) {
        final tasks = provider.tasks;
        for (final task in tasks) {
          if (task.status == DownloadStatus.completed ||
              task.status == DownloadStatus.failed) {
            await db.deleteTask(task.id);
          }
        }
      }
      if (mounted) {
        ThemedSnackbar.show(
          context,
          message: 'Browsing data cleared',
          color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
          icon: Icons.check_circle_outline,
          isDarkMode: isDark,
        );
      }
    } catch (e, st) {
      Logger('browser_screen')
          .warning('[browser_screen] clear browsing data failed', e, st);
    }
  }

  /// UX 3.9: Zoom controls dialog — applies textZoom live, persists per host.
  Future<void> _showZoomDialog(BrowserTab activeTab) async {
    final settings = _settings;
    final isDark = settings.isDarkMode;
    final host = Uri.tryParse(activeTab.url)?.host.toLowerCase() ?? '';
    final siteSettings = await SiteSettingsStore.getForHost(host);
    if (!mounted) return;
    var value = (siteSettings.zoomLevel ?? 100.0).clamp(50.0, 200.0).toDouble();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor:
                  isDark ? AppTheme.surface : AppTheme.lightSurface,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Icon(Icons.zoom_in_rounded,
                      color:
                          isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue),
                  const SizedBox(width: 8),
                  const Text('Page zoom', style: TextStyle(fontSize: 16)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${value.round()}%',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: isDark
                            ? AppTheme.textPrimary
                            : AppTheme.lightTextPrimary,
                      )),
                  Slider(
                    min: 50,
                    max: 200,
                    divisions: 30,
                    value: value,
                    activeColor:
                        isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                    label: '${value.round()}%',
                    onChanged: (v) {
                      setDialogState(() => value = v);
                      try {
                        activeTab.controller?.setSettings(
                          settings: InAppWebViewSettings(
                            textZoom: v.round(),
                            incognito: activeTab.isIncognito,
                          ),
                        );
                      } catch (_) {}
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _ZoomPresetButton(
                        label: '50%',
                        value: 50,
                        onTap: () => setDialogState(() => value = 50),
                      ),
                      _ZoomPresetButton(
                        label: '100%',
                        value: 100,
                        onTap: () => setDialogState(() => value = 100),
                      ),
                      _ZoomPresetButton(
                        label: '150%',
                        value: 150,
                        onTap: () => setDialogState(() => value = 150),
                      ),
                      _ZoomPresetButton(
                        label: '200%',
                        value: 200,
                        onTap: () => setDialogState(() => value = 200),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Done'),
                ),
              ],
            );
          },
        );
      },
    );

    if (host.isNotEmpty) {
      await SiteSettingsStore.updateForHost(
        host,
        siteSettings.copyWith(zoomLevel: value),
      );
      try {
        await activeTab.controller?.setSettings(
          settings: InAppWebViewSettings(
            textZoom: value.round(),
            incognito: activeTab.isIncognito,
          ),
        );
      } catch (_) {}
    }
  }

  /// UX 3.12: Captures the visible page and saves it as a PNG.
  Future<void> _capturePage(BrowserTab activeTab) async {
    if (_capturingPage || activeTab.isHome) return;
    final settings = _settings;
    final isDark = settings.isDarkMode;
    setState(() => _capturingPage = true);
    try {
      final bytes = await activeTab.controller?.takeScreenshot();
      if (bytes == null || bytes.isEmpty) {
        throw Exception('screenshot returned empty');
      }
      final ok = await PermissionService().ensureStorageAccess();
      if (!ok) {
        throw Exception('storage access denied');
      }
      final dir = await PermissionService().defaultDownloadDirectory();
      final fileName = 'page_${DateTime.now().millisecondsSinceEpoch}.png';
      final file = File(p.join(dir, fileName));
      await file.writeAsBytes(bytes);
      if (mounted) {
        ThemedSnackbar.show(
          context,
          message: 'Page captured — $fileName',
          color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
          icon: Icons.photo_camera_rounded,
          isDarkMode: isDark,
          actionLabel: 'OPEN',
          onAction: () => openFile(context, file.path, settings),
        );
      }
    } catch (e) {
      if (mounted) {
        ThemedSnackbar.show(
          context,
          message: 'Screenshot failed',
          color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
          icon: Icons.error_outline,
          isDarkMode: isDark,
          subtitle: e.toString(),
        );
      }
    } finally {
      if (mounted) setState(() => _capturingPage = false);
    }
  }

  /// UX 3.13: Opens translate.google.com for the current page.
  Future<void> _showTranslateMenu(BrowserTab activeTab) async {
    if (activeTab.isHome || activeTab.url.isEmpty) return;
    final settings = _settings;
    final isDark = settings.isDarkMode;
    final languages = <String, String>{
      'en': 'English',
      'ar': 'العربية',
      'fr': 'Français',
      'es': 'Español',
      'de': 'Deutsch',
      'hi': 'हिन्दी',
      'pt': 'Português',
      'ru': 'Русский',
      'tr': 'Türkçe',
      'ur': 'اردو',
    };

    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.translate_rounded,
                      color:
                          isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue),
                  const SizedBox(width: 10),
                  const Text('Translate page to',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: languages.entries.map((e) {
                  final isCurrent = e.key == settings.translateTargetLang;
                  return ListTile(
                    leading: Icon(
                      Icons.language_rounded,
                      color: isCurrent
                          ? (isDark
                              ? AppTheme.neonBlue
                              : AppTheme.lightNeonBlue)
                          : null,
                      size: 20,
                    ),
                    title: Text(e.value, style: const TextStyle(fontSize: 14)),
                    trailing: isCurrent
                        ? Icon(Icons.check_circle_rounded,
                            color: isDark
                                ? AppTheme.neonBlue
                                : AppTheme.lightNeonBlue,
                            size: 18)
                        : null,
                    onTap: () => Navigator.pop(sheetContext, e.key),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );

    if (selected == null || !mounted) return;
    await settings.setTranslateTargetLang(selected);
    final target = Uri.encodeComponent(activeTab.url);
    final translateUrl =
        'https://translate.google.com/translate?sl=auto&tl=$selected&u=$target';
    _openInNewTab(
      translateUrl,
      isIncognito: activeTab.isIncognito,
      switchToTab: true,
      origin: TabOrigin.userDirect,
    );
  }

  /// UX 3.14: Print/PDF — html2pdf data-URI fallback when the native print
  /// API is unavailable.
  Future<void> _printPage(BrowserTab activeTab) async {
    if (activeTab.isHome || activeTab.url.isEmpty) return;
    final settings = _settings;
    final isDark = settings.isDarkMode;
    final controller = activeTab.controller;
    if (controller == null) return;
    try {
      // Bug #15 fix: opening a Blob URL in a new tab/controller fails because Blob URLs
      // are origin-scoped. Instead, evaluate the print dialog directly on the current tab's controller.
      await controller.evaluateJavascript(source: "window.print();");
    } catch (e, st) {
      Logger('browser_screen').warning('[browser_screen] print failed', e, st);
      if (mounted) {
        ThemedSnackbar.show(
          context,
          message: 'Print failed',
          color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
          icon: Icons.error_outline,
          isDarkMode: isDark,
        );
      }
    }
  }

  /// UX 3.20: Keyboard shortcuts (desktop only): Ctrl+T/W/L/R/F.
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!_shortcutsActive || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final hw = HardwareKeyboard.instance;
    final modifierPressed = hw.isControlPressed || hw.isMetaPressed;
    if (!modifierPressed) return KeyEventResult.ignored;

    final logical = event.logicalKey;
    if (logical == LogicalKeyboardKey.keyT) {
      _newTabViaShortcut();
      return KeyEventResult.handled;
    }
    if (logical == LogicalKeyboardKey.keyW) {
      _closeActiveTabViaShortcut();
      return KeyEventResult.handled;
    }
    if (logical == LogicalKeyboardKey.keyL) {
      _focusUrlBar();
      return KeyEventResult.handled;
    }
    if (logical == LogicalKeyboardKey.keyR) {
      if (_currentTabIndex >= 0 && _currentTabIndex < _tabs.length) {
        final tab = _tabs[_currentTabIndex];
        if (!tab.isHome) _safeReloadTab(tab);
      }
      return KeyEventResult.handled;
    }
    if (logical == LogicalKeyboardKey.keyF) {
      _openFindPanel();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _newTabViaShortcut() {
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
    final settings = _settings;
    if (_tabs.length >= settings.maxTabs) return;
    final oldIdx = _currentTabIndex;
    setState(() {
      _tabs.add(_createNewTab());
      _currentTabIndex = _tabs.length - 1;
      _urlController.text = '';
      _showBarsNotifier.value = true;
      _updateLruOrder();
    });
    _onTabSwitched(oldIdx, _currentTabIndex);
    _saveTabs();
    _focusUrlBar();
  }

  void _closeActiveTabViaShortcut() {
    if (_tabs.length <= 1) {
      _goBack();
      return;
    }
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
    final tab = _tabs[_currentTabIndex];
    final idx = _currentTabIndex;
    setState(() {
      _recordClosedTab(tab);
      _cleanupTabState(tab.id);
      _tabs.removeAt(idx);
      if (_currentTabIndex >= _tabs.length) {
        _currentTabIndex = _tabs.length - 1;
      }
      final active = _tabs[_currentTabIndex];
      _urlController.text = active.isHome ? '' : active.url;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => tab.dispose());
    _saveTabs();
  }

  void _focusUrlBar() {
    _focusNode.requestFocus();
  }

  /// UX 3.10: Launches app-linkable URLs in an external app when enabled.
  Future<bool> _maybeOpenInApp(String url) async {
    final settings = _settings;
    if (!settings.openLinksInApp) return false;
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return false;
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return false;
    final isAppHost =
        _appLinkHosts.any((h) => host == h || host.endsWith('.$h'));
    if (!isAppHost) return false;
    try {
      final launched = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (launched && mounted) {
        ThemedSnackbar.show(
          context,
          message: 'Opening in external app…',
          color:
              settings.isDarkMode ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
          icon: Icons.open_in_new_rounded,
          isDarkMode: settings.isDarkMode,
        );
      }
      return launched;
    } catch (_) {
      return false;
    }
  }

  static const Set<String> _appLinkHosts = {
    'youtube.com',
    'youtu.be',
    'twitter.com',
    'x.com',
    'facebook.com',
    'instagram.com',
    'tiktok.com',
    'twitch.tv',
    'spotify.com',
    'open.spotify.com',
    'netflix.com',
    'maps.google.com',
    'waze.com',
    'discord.com',
    'telegram.me',
    'reddit.com',
  };

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

    var cleanUrl = url.trim();
    if (cleanUrl.isNotEmpty) {
      if (!cleanUrl.startsWith('http://') &&
          !cleanUrl.startsWith('https://') &&
          !cleanUrl.startsWith('magnet:') &&
          !cleanUrl.startsWith('file:')) {
        if (cleanUrl.startsWith('//')) {
          cleanUrl = 'https:$cleanUrl';
        } else if (cleanUrl.startsWith('/')) {
          final baseUri = Uri.tryParse(tab.url);
          if (baseUri != null && baseUri.host.isNotEmpty) {
            cleanUrl = '${baseUri.scheme}://${baseUri.host}$cleanUrl';
          } else {
            cleanUrl = 'https://$cleanUrl';
          }
        } else {
          cleanUrl = 'https://$cleanUrl';
        }
      }
    }

    if (cleanUrl.isEmpty) return;

    final now = DateTime.now();
    if (_lastLongPressSheetUrl == cleanUrl &&
        _lastLongPressSheetAt != null &&
        now.difference(_lastLongPressSheetAt!) <
            const Duration(milliseconds: 300)) {
      return;
    }
    _lastLongPressSheetUrl = cleanUrl;
    _lastLongPressSheetAt = now;

    final isWebUrl =
        cleanUrl.startsWith('http://') || cleanUrl.startsWith('https://');

    // Plain link long-press → lightweight navigation sheet.
    // Media/file long-press → BrowserDownloadSheet (download-forward UI).
    if (type == 'link') {
      LinkOptionsSheet.show(
        context,
        cleanUrl,
        onOpen: () => _navigateToUrl(cleanUrl),
        onOpenInNewTab: () {
          _openInNewTab(
            cleanUrl,
            isIncognito: tab.isIncognito,
            switchToTab: true,
            origin: TabOrigin.userDirect,
          );
          _saveTabs();
        },
        onOpenInBackground: () =>
            _openInBackgroundTab(cleanUrl, isIncognito: tab.isIncognito),
        onOpenInIncognito: () {
          _openInNewTab(
            cleanUrl,
            isIncognito: true,
            switchToTab: true,
            origin: TabOrigin.userDirect,
          );
          _saveTabs();
        },
        onDownload: () => _showInterceptionSheet(context, cleanUrl),
      );
      return;
    }

    // Media / file long-press → BrowserDownloadSheet.
    BrowserDownloadSheet.show(
      context,
      url,
      type: type,
      text: text,
      downloadPageUrl: tab.isHome ? null : tab.url,
      onQuality: hasMultipleQualities
          ? () => _showQualityPicker(tab.id, fallbackUrl: url)
          : null,
      onOpen: isWebUrl ? () => _navigateToUrl(cleanUrl) : null,
      onOpenInBackground: isWebUrl
          ? () => _openInBackgroundTab(cleanUrl, isIncognito: tab.isIncognito)
          : null,
      onOpenInNewTab: isWebUrl
          ? () {
              setState(() {
                final newTab = _createNewTab(
                  initialUrl: cleanUrl,
                  isIncognito: tab.isIncognito,
                );
                _redirectGuard.reset(newTab.id);
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
              setState(() {
                final newTab = _createNewTab(
                  initialUrl: cleanUrl,
                  isIncognito: true,
                );
                _redirectGuard.reset(newTab.id);
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

    final settings = _settings;
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
    final settings = _settings;
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
                            L10n.of(
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
    final settings = _settings;
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
    final settings = _settings;
    triggerHaptic(settings);
    try {
      final offlineTitle =
          mounted ? L10n.of(context, 'browser_offline_page') : 'Offline Page';
      String title = tab.title.isNotEmpty ? tab.title : offlineTitle;
      title = title.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();

      final path = settings.customDownloadPath?.isNotEmpty == true
          ? settings.customDownloadPath!
          : await PermissionService().defaultDownloadDirectory();

      String? webArchiveSavedPath;
      if (Platform.isAndroid && tab.controller != null) {
        try {
          final archivePath = p.join(path, "$title.mhtml");
          final res = await tab.controller
              ?.saveWebArchive(filePath: archivePath, autoname: false);
          if (res != null && res.isNotEmpty) {
            webArchiveSavedPath = res;
          }
        } catch (_) {}
      }

      String fileName;
      String filePath;
      int size = 0;

      if (webArchiveSavedPath != null &&
          File(webArchiveSavedPath).existsSync()) {
        fileName = "$title.mhtml";
        filePath = webArchiveSavedPath;
        size = await File(webArchiveSavedPath).length();
      } else {
        fileName = "$title.html";
        filePath = p.join(path, fileName);
        final result = await tab.controller?.evaluateJavascript(
          source: "document.documentElement.outerHTML",
        );
        String rawHtml = '';
        if (result is String) {
          rawHtml = result;
          if (rawHtml.startsWith('"') && rawHtml.endsWith('"')) {
            try {
              rawHtml = jsonDecode(rawHtml) as String;
            } catch (_) {
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
              color: settings.isDarkMode
                  ? AppTheme.neonRed
                  : AppTheme.lightNeonRed,
              icon: Icons.error_outline,
              isDarkMode: settings.isDarkMode,
            );
          }
          return;
        }
        final file = File(filePath);
        await file.writeAsString(rawHtml);
        size = utf8.encode(rawHtml).length;
      }

      final id = DateTime.now().millisecondsSinceEpoch.toString();

      final task = DownloadTask(
        id: id,
        fileName: fileName, // Fix: Use the evaluated fileName (supports .mhtml)
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
            message: '${L10n.of(context, 'browser_page_saved')} - $fileName',
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
        final settings = _settings;
        final limit = settings.maxTabs;
        return AlertDialog(
          backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
          title: Text(L10n.of(context, 'tab_limit_reached')),
          content: Text(
            L10n.isRtl(context)
                ? 'تم الوصول إلى الحد الأقصى للمبوبات ($limit مبوبة).'
                : 'Maximum tab limit of $limit reached.',
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
                  final oldTab = _tabs[closeIdx];
                  setModalState(() {
                    _cleanupTabState(oldTab.id);
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
                  setState(() {}); // Rebuild parent screen to sync tabs
                  WidgetsBinding.instance
                      .addPostFrameCallback((_) => oldTab.dispose());
                  _saveTabs();
                  Navigator.pop(switcherContext);
                }
              },
              child: Text(L10n.of(context, 'close_oldest_inactive')),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                final active = _tabs[_currentTabIndex];
                final oldTabs = _tabs.where((t) => t.id != active.id).toList();
                setModalState(() {
                  for (final tab in oldTabs) {
                    _recordClosedTab(tab);
                    _cleanupTabState(tab.id);
                    _tabs.remove(tab);
                  }
                  // Active tab is now at index 0 — open one new blank tab
                  _currentTabIndex = 0;
                  final newTab = _createNewTab(isIncognito: isIncognito);
                  _tabs.add(newTab);
                  _currentTabIndex = _tabs.length - 1;
                  _urlController.text = '';
                  _showBarsNotifier.value = true;
                });
                setState(() {}); // Rebuild parent screen to sync tabs
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  for (final tab in oldTabs) {
                    tab.dispose();
                  }
                });
                _saveTabs();
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

  Future<void> _confirmCloseAllTabs(
      BuildContext context, StateSetter setModalState) async {
    final settings = _settings;
    triggerHaptic(settings);
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);

    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed),
              const SizedBox(width: 8),
              Text(
                isRtl ? 'إغلاق جميع التبويبات' : 'Close All Tabs',
                style: TextStyle(
                  color:
                      isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                  fontSize: 16,
                ),
              ),
            ],
          ),
          content: Text(
            isRtl
                ? 'هل أنت تأكد من إغلاق جميع التبويبات (${_tabs.length})؟'
                : 'Close all ${_tabs.length} tabs?',
            style: TextStyle(
              color:
                  isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
              fontSize: 13,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(isRtl ? 'إلغاء' : 'Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(
                isRtl ? 'إغلاق الكل' : 'Close All',
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      final oldTabs = List<BrowserTab>.from(_tabs);
      setModalState(() {
        setState(() {
          for (final t in oldTabs) {
            _recordClosedTab(t);
            _cleanupTabState(t.id);
          }
          _tabManager.clearAllTabs();
          final homeTab = _createNewTab();
          _tabManager.openInNewTab(homeTab.url, switchToTab: true);
          _currentTabIndex = 0;
          _urlController.text = '';
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          for (final t in oldTabs) {
            t.dispose();
          }
        });
        _saveTabs();
      });
      if (context.mounted) Navigator.pop(context);
    }
  }

  void _showTabSwitcher(BuildContext context) {
    final settings = _settings;
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
            // Fix #21: Removed the no-op AnimatedSlide(offset: Offset.zero) /
            // AnimatedOpacity(opacity: 1.0) wrappers that performed no animation.
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
                                    icon: Icons.delete_sweep_rounded,
                                    color: isDark
                                        ? AppTheme.neonRed
                                        : AppTheme.lightNeonRed,
                                    tooltip: L10n.isRtl(context)
                                        ? 'إغلاق جميع التبويبات'
                                        : 'Close all tabs',
                                    onPressed: () => _confirmCloseAllTabs(
                                        context, setModalState),
                                  ),
                                  const SizedBox(width: 8),
                                  _TabSwitcherAction(
                                    icon: Icons.visibility_off_rounded,
                                    color: violet,
                                    tooltip: L10n.of(
                                      context,
                                      'browser_new_incognito_tab',
                                    ),
                                    onPressed: () {
                                      triggerHaptic(settings);
                                      final maxTabs = settings.maxTabs;
                                      if (_tabs.length >= maxTabs) {
                                        _showTabLimitDialog(
                                          context,
                                          setModalState,
                                          isIncognito: true,
                                        );
                                        return;
                                      }
                                      final oldIdx = _currentTabIndex;
                                      setState(() {
                                        _tabManager.openInNewTab(
                                          'about:blank',
                                          switchToTab: true,
                                          isIncognito: true,
                                        );
                                        _showBarsNotifier.value = true;
                                        _updateLruOrder();
                                      });
                                      _onTabSwitched(oldIdx, _currentTabIndex);
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
                                      final maxTabs = settings.maxTabs;
                                      if (_tabs.length >= maxTabs) {
                                        _showTabLimitDialog(
                                          context,
                                          setModalState,
                                          isIncognito: false,
                                        );
                                        return;
                                      }
                                      final oldIdx = _currentTabIndex;
                                      setState(() {
                                        _tabManager.openInNewTab(
                                          'about:blank',
                                          switchToTab: true,
                                          isIncognito: false,
                                        );
                                        _showBarsNotifier.value = true;
                                        _updateLruOrder();
                                      });
                                      _onTabSwitched(oldIdx, _currentTabIndex);
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

                                  // E21: Tab Switcher Tab Select/Deselect Animation & Swipe to Close
                                  return Dismissible(
                                      key: ValueKey(tab.id),
                                      direction: DismissDirection.horizontal,
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
                                          _recordClosedTab(tab);
                                          _tabManager.closeTab(tab.id);
                                        });
                                      },
                                      child: AnimatedScale(
                                        scale: isActive ? 1.05 : 1.0,
                                        duration: AppTheme.motionFast,
                                        child: Semantics(
                                          button: true,
                                          selected: isActive,
                                          label:
                                              'Tab: ${tab.title.isEmpty ? 'New Tab' : tab.title}',
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
                                                        ? (settings.isAmoledMode
                                                            ? AppTheme
                                                                .amoledSurfaceRaised
                                                            : const Color(
                                                                0xFF16121F))
                                                        : const Color(
                                                            0xFFF3EEFA))
                                                    : (isDark
                                                        ? (settings.isAmoledMode
                                                            ? AppTheme
                                                                .amoledCardBg
                                                            : AppTheme.cardBg)
                                                        : AppTheme.lightCardBg),
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
                                                          color:
                                                              tabClr.withValues(
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
                                                      color: tabClr.withValues(
                                                        alpha: isActive
                                                            ? 0.12
                                                            : 0.05,
                                                      ),
                                                      borderRadius:
                                                          const BorderRadius
                                                              .vertical(
                                                        top:
                                                            Radius.circular(15),
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
                                                              _recordClosedTab(
                                                                  tab);
                                                              _tabManager
                                                                  .closeTab(
                                                                      tab.id);
                                                            });
                                                          },
                                                          child: Icon(
                                                            Icons.close_rounded,
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
                                                      padding: const EdgeInsets
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
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        color: isDark
                                                            ? AppTheme.textMuted
                                                            : AppTheme
                                                                .lightTextMuted,
                                                        fontSize: 12,
                                                        fontFamily: 'monospace',
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(height: 10),
                                                ],
                                              ),
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
          const SizedBox(height: 24),

          // ── Section 1: Your Shortcuts ───────────────────────────
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
                isRtl ? 'اختصاراتك' : 'Your shortcuts',
                style: TextStyle(
                  color: isDark
                      ? AppTheme.textSecondary
                      : AppTheme.lightTextSecondary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _showAddShortcutDialog,
                icon: Icon(Icons.add, size: 16, color: accentColor),
                label: Text(
                  isRtl ? 'إضافة' : 'Add',
                  style: TextStyle(
                      fontSize: 12,
                      color: accentColor,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ShortcutsGridWidget(
            customShortcuts: _userCustomShortcuts,
            isDark: isDark,
            isRtl: isRtl,
            settings: settings,
            onOpenBookmarks: () async {
              final cleared = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => const BookmarkManagerScreen(),
                ),
              );
              if (cleared == true && mounted) setState(() {});
            },
            onOpenHistory: _openHistory,
            onOpenScripts: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const ScriptManagerScreen(),
                ),
              );
            },
            onRemoveShortcut: _removeCustomShortcut,
            onNavigate: (url) => _navigateToUrl(url),
          ),

          const SizedBox(height: 24),

          // ── Section 2: Suggested Sites ──────────────────────────
          Row(
            children: [
              Container(
                width: 3,
                height: 14,
                decoration: BoxDecoration(
                  color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isRtl ? 'المواقع المقترحة' : 'Suggested sites',
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
                title: 'Wikipedia',
                url: 'https://wikipedia.org',
                icon: Icons.menu_book_rounded,
                color: isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
                settings: settings,
              ),
              _buildShortcutCard(
                context,
                title: 'DuckDuckGo',
                url: 'https://duckduckgo.com',
                icon: Icons.privacy_tip_outlined,
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
    VoidCallback? onLongPress,
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
          onLongPress: onLongPress,
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

    // Bug #7 fix: do not execute side effects during build().
    // Instead of calling setSettings during build when settings.pinchToZoom changes,
    // we handle it via standard state change lifecycle or didUpdateWidget logic.
    // However, since we listen to context.watch<SettingsProvider>(), the build() method
    // runs whenever settings change. To update the controllers safely without side effects
    // in build, we schedule a post-frame callback.
    if (settings.pinchToZoom != _lastZoomEnabled) {
      _lastZoomEnabled = settings.pinchToZoom;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final tab in _tabs) {
          if (tab.controller != null) {
            tab.controller!.getSettings().then((currentSettings) {
              if (currentSettings != null) {
                currentSettings.supportZoom = settings.pinchToZoom;
                currentSettings.incognito = tab.isIncognito;
                tab.controller?.setSettings(settings: currentSettings);
              }
            }).catchError((_) {});
          }
        }
      });
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
          if (_tabs.isEmpty ||
              _currentTabIndex < 0 ||
              _currentTabIndex >= _tabs.length) {
            if (Navigator.canPop(context)) {
              Navigator.pop(context);
            } else {
              downloadProvider.setActiveTabIndex(0);
            }
            return;
          }
          // _goBack() owns the full decision tree (cases a–d):
          //   (a) WebView history → go back
          //   (b) ad/popup/redirect tab with no history → close + Undo snackbar
          //   (c) not Home → go to Home dashboard
          //   (d) already Home → returns false, fall through to exit
          // The async canGoBack check is done inside _goBack() itself.
          final handled = await _goBack();
          if (handled) return;
          // Fall through: tab is at Home and has no history to go back through.
          final switched = _switchToPreviousTab();
          if (switched) {
            return;
          }
          if (!context.mounted) return;
          if (Navigator.canPop(context)) {
            Navigator.pop(context);
          } else {
            downloadProvider.setActiveTabIndex(0);
          }
        },
        child: Focus(
          autofocus: true,
          onKeyEvent: _handleKeyEvent,
          child: GeometricGridBackground(
            child: Scaffold(
              backgroundColor: Colors.transparent,
              resizeToAvoidBottomInset: false,
              floatingActionButton:
                  showFab ? _buildDownloadFab(context, settings) : null,
              floatingActionButtonLocation:
                  FloatingActionButtonLocation.endFloat,
              body: Builder(
                builder: (context) {
                  final isTablet = MediaQuery.of(context).size.width > 900;
                  final mainContent = Column(
                    children: [
                      ValueListenableBuilder<bool>(
                        valueListenable: _showBarsNotifier,
                        builder: (context, showBars, child) {
                          return AnimatedSlide(
                            offset:
                                showBars ? Offset.zero : const Offset(0, -1.2),
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                            child: AnimatedOpacity(
                              opacity: showBars ? 1.0 : 0.0,
                              duration: const Duration(milliseconds: 150),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 250),
                                curve: Curves.easeInOut,
                                height: showBars
                                    ? (kToolbarHeight + statusBarHeight)
                                    : 0,
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
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8.0),
                                  child: Row(
                                    children: [
                                      IconButton(
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        icon: Icon(Icons.close,
                                            size: 20, color: textClr),
                                        tooltip: isRtl
                                            ? 'إغلاق المتصفح'
                                            : 'Close browser',
                                        onPressed: _handleCloseOrQuit,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: AnimatedContainer(
                                          duration:
                                              const Duration(milliseconds: 200),
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
                                                            : AppTheme
                                                                .amoledBackground)
                                                        : (_isFocused
                                                            ? const Color(
                                                                0xFF141424)
                                                            : const Color(
                                                                0xFF0F0F16)))
                                                    : (_isFocused
                                                        ? AppTheme.lightNeonBlue
                                                            .withValues(
                                                                alpha: 0.08)
                                                        : const Color(
                                                            0xFFF1F5F9)),
                                            borderRadius:
                                                BorderRadius.circular(12),
                                            border: Border.all(
                                              color: (activeTab.isIncognito ||
                                                      settings.incognitoEnabled)
                                                  ? AppTheme.neonViolet
                                                      .withValues(alpha: 0.3)
                                                  : _isFocused
                                                      ? (isDark
                                                              ? AppTheme
                                                                  .neonBlue
                                                              : AppTheme
                                                                  .lightNeonBlue)
                                                          .withValues(
                                                              alpha: 0.5)
                                                      : (isDark
                                                          ? const Color(
                                                              0x15FFFFFF)
                                                          : const Color(
                                                              0x0D000000)),
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
                                                              ? AppTheme
                                                                  .neonBlue
                                                              : AppTheme
                                                                  .lightNeonBlue)
                                                          .withValues(
                                                              alpha: 0.25),
                                                      blurRadius: 8,
                                                      spreadRadius: 0.5,
                                                    ),
                                                  ]
                                                : null,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 4),
                                          child: Row(
                                            children: [
                                              // E3: Incognito Icon
                                              if (activeTab.isIncognito ||
                                                  settings.incognitoEnabled)
                                                const Tooltip(
                                                  message:
                                                      'Incognito mode — cookies isolated, history not saved',
                                                  child: Padding(
                                                    padding:
                                                        EdgeInsets.symmetric(
                                                            horizontal: 4.0),
                                                    child: Icon(
                                                        Icons
                                                            .visibility_off_rounded,
                                                        size: 14,
                                                        color: AppTheme
                                                            .neonViolet),
                                                  ),
                                                ),

                                              // E1 & E2: Security / Loading Indicator
                                              AnimatedSwitcher(
                                                duration: AppTheme.motionBase,
                                                child: activeTab.isLoading
                                                    ? const SizedBox(
                                                        key:
                                                            ValueKey('loading'),
                                                        width: 14,
                                                        height: 14,
                                                        child:
                                                            CircularProgressIndicator(
                                                                strokeWidth:
                                                                    1.5,
                                                                color: AppTheme
                                                                    .neonBlue),
                                                      )
                                                    : GestureDetector(
                                                        onTap: () =>
                                                            _showSiteSettingsSheet(
                                                                activeTab),
                                                        child: Tooltip(
                                                          key: const ValueKey(
                                                              'security'),
                                                          message: activeTab.url
                                                                  .startsWith(
                                                                      'https')
                                                              ? 'Secure connection'
                                                              : 'Insecure connection',
                                                          child: Padding(
                                                            padding:
                                                                const EdgeInsets
                                                                    .symmetric(
                                                                    horizontal:
                                                                        6.0),
                                                            child: Icon(
                                                              activeTab.isHome ||
                                                                      activeTab
                                                                          .url
                                                                          .isEmpty
                                                                  ? Icons
                                                                      .search_rounded
                                                                  : activeTab
                                                                          .url
                                                                          .startsWith(
                                                                              'https')
                                                                      ? Icons
                                                                          .lock_rounded
                                                                      : Icons
                                                                          .lock_open_rounded,
                                                              size: 14,
                                                              color: activeTab
                                                                          .isHome ||
                                                                      activeTab
                                                                          .url
                                                                          .isEmpty
                                                                  ? (isDark
                                                                      ? AppTheme
                                                                          .textMuted
                                                                      : AppTheme
                                                                          .lightTextMuted)
                                                                  : activeTab
                                                                          .url
                                                                          .startsWith(
                                                                              'https')
                                                                      ? AppTheme
                                                                          .neonGreen
                                                                      : AppTheme
                                                                          .neonAmber,
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                              ),

                                              // E4 & E10: Ad-blocker Indicator — only shown on real web pages
                                              if (!activeTab.isHome &&
                                                  activeTab.url.isNotEmpty)
                                                GestureDetector(
                                                  onTap: () =>
                                                      _showSiteSettingsSheet(
                                                          activeTab),
                                                  child: Tooltip(
                                                    message: _adBlocker
                                                            .isEnabled
                                                        ? 'Ad-blocker active'
                                                        : 'Ad-blocker disabled',
                                                    child: Stack(
                                                      clipBehavior: Clip.none,
                                                      children: [
                                                        Padding(
                                                          padding:
                                                              const EdgeInsets
                                                                  .symmetric(
                                                                  horizontal:
                                                                      4.0),
                                                          child: Icon(
                                                            _adBlocker.isEnabled
                                                                ? Icons
                                                                    .shield_rounded
                                                                : Icons
                                                                    .shield_outlined,
                                                            size: 14,
                                                            color: _adBlocker
                                                                    .isEnabled
                                                                ? AppTheme
                                                                    .neonGreen
                                                                : (isDark
                                                                    ? AppTheme
                                                                        .textMuted
                                                                    : AppTheme
                                                                        .lightTextMuted),
                                                          ),
                                                        ),
                                                        ValueListenableBuilder<
                                                            int>(
                                                          valueListenable:
                                                              _activeBlockedAdsNotifier,
                                                          builder: (context,
                                                              count, _) {
                                                            if (!_adBlocker
                                                                    .isEnabled ||
                                                                count <= 0) {
                                                              return const SizedBox
                                                                  .shrink();
                                                            }
                                                            return Positioned(
                                                              right: -4,
                                                              top: -4,
                                                              child:
                                                                  AnimatedSwitcher(
                                                                duration:
                                                                    const Duration(
                                                                        milliseconds:
                                                                            300),
                                                                transitionBuilder: (Widget
                                                                        child,
                                                                    Animation<
                                                                            double>
                                                                        animation) {
                                                                  return ScaleTransition(
                                                                    scale: Tween<double>(
                                                                            begin:
                                                                                0.5,
                                                                            end:
                                                                                1.0)
                                                                        .animate(
                                                                      CurvedAnimation(
                                                                        parent:
                                                                            animation,
                                                                        curve: Curves
                                                                            .elasticOut,
                                                                      ),
                                                                    ),
                                                                    child:
                                                                        child,
                                                                  );
                                                                },
                                                                child:
                                                                    Container(
                                                                  key: ValueKey<
                                                                          int>(
                                                                      count),
                                                                  padding:
                                                                      const EdgeInsets
                                                                          .all(
                                                                          2),
                                                                  decoration:
                                                                      const BoxDecoration(
                                                                    color: Colors
                                                                        .redAccent,
                                                                    shape: BoxShape
                                                                        .circle,
                                                                  ),
                                                                  constraints:
                                                                      const BoxConstraints(
                                                                    minWidth:
                                                                        14,
                                                                    minHeight:
                                                                        14,
                                                                  ),
                                                                  alignment:
                                                                      Alignment
                                                                          .center,
                                                                  child: Text(
                                                                    '$count',
                                                                    style:
                                                                        const TextStyle(
                                                                      color: Colors
                                                                          .white,
                                                                      fontSize:
                                                                          8,
                                                                      fontWeight:
                                                                          FontWeight
                                                                              .bold,
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                            );
                                                          },
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),

                                              // E7: Desktop Mode Indicator
                                              if (settings.desktopMode)
                                                const Tooltip(
                                                  message:
                                                      'Desktop mode active',
                                                  child: Padding(
                                                    padding:
                                                        EdgeInsets.symmetric(
                                                            horizontal: 4.0),
                                                    child: Icon(
                                                        Icons
                                                            .desktop_windows_rounded,
                                                        size: 14,
                                                        color:
                                                            AppTheme.neonBlue),
                                                  ),
                                                ),

                                              Expanded(
                                                child: SmartUrlBar(
                                                  controller: _urlController,
                                                  focusNode: _focusNode,
                                                  isDark: isDark,
                                                  isLoading:
                                                      activeTab.isLoading,
                                                  onNavigate: _navigateToUrl,
                                                  onReload: () {
                                                    if (!activeTab.isHome) {
                                                      _safeReloadTab(activeTab);
                                                    }
                                                  },
                                                  onStopLoading: () {
                                                    activeTab.controller
                                                        ?.evaluateJavascript(
                                                            source:
                                                                'window.stop();');
                                                    setState(() {
                                                      activeTab.isLoading =
                                                          false;
                                                    });
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
                                          isPlaylist:
                                              YoutubeService.isPlaylistUrl(
                                                  activeTab.url),
                                          isRtl: isRtl,
                                          isDark: isDark,
                                          enableGlow: settings.enableGlow,
                                          onPressed: () => _handleYouTubeGrab(
                                              activeTab, settings),
                                        ),
                                        const SizedBox(width: 4),
                                      ],
                                      IconButton(
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        icon: Transform.flip(
                                          flipX: isRtl,
                                          child: Icon(
                                            Icons.arrow_back_ios_new,
                                            size: 15,
                                            color: (activeTab.canGoBack ||
                                                    (!activeTab.isHome &&
                                                        activeTab.origin !=
                                                            TabOrigin
                                                                .userDirect))
                                                ? textClr
                                                : (isDark
                                                    ? AppTheme.textMuted
                                                    : AppTheme.lightTextMuted),
                                          ),
                                        ),
                                        tooltip: isRtl ? 'رجوع' : 'Go back',
                                        onPressed: (activeTab.canGoBack ||
                                                (!activeTab.isHome &&
                                                    activeTab.origin !=
                                                        TabOrigin.userDirect))
                                            ? () async {
                                                triggerHaptic(settings);
                                                await _goBack();
                                              }
                                            : null,
                                      ),
                                      const SizedBox(width: 6),
                                      IconButton(
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        icon: Transform.flip(
                                          flipX: isRtl,
                                          child: Icon(
                                            Icons.arrow_forward_ios,
                                            size: 15,
                                            color: activeTab.canGoForward
                                                ? textClr
                                                : (isDark
                                                    ? AppTheme.textMuted
                                                    : AppTheme.lightTextMuted),
                                          ),
                                        ),
                                        tooltip: isRtl ? 'تقدّم' : 'Go forward',
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
                                              duration: const Duration(
                                                  milliseconds: 200),
                                              margin:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 2),
                                              width: 24,
                                              height: 24,
                                              decoration: BoxDecoration(
                                                border: Border.all(
                                                    color: textClr, width: 1.8),
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                                color: _tabs.length > 1
                                                    ? (isDark
                                                            ? AppTheme.neonBlue
                                                            : AppTheme
                                                                .lightNeonBlue)
                                                        .withValues(alpha: 0.1)
                                                    : Colors.transparent,
                                              ),
                                              alignment: Alignment.center,
                                              child: Text(
                                                '${_tabs.length}',
                                                style: TextStyle(
                                                  color: textClr,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w800,
                                                  fontFamily: 'Space Grotesk',
                                                ),
                                              ),
                                            ),
                                            if (_tabs.length >=
                                                settings.maxTabs)
                                              const Positioned(
                                                right: -4,
                                                top: -4,
                                                child: Tooltip(
                                                  message: 'Tab limit reached',
                                                  child: Icon(
                                                      Icons
                                                          .warning_amber_rounded,
                                                      size: 12,
                                                      color:
                                                          Colors.orangeAccent),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      PopupMenuButton<String>(
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
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
                                          // Section A: Page actions
                                          _menuItem(Icons.refresh, 'Reload',
                                              'reload', textClr),
                                          _menuItem(
                                              Icons.bookmark_add_outlined,
                                              'Bookmark this page',
                                              'bookmark',
                                              textClr),
                                          _menuItem(Icons.copy, 'Copy URL',
                                              'copy', textClr),
                                          _menuItem(Icons.share, 'Share URL',
                                              'share', textClr),
                                          const PopupMenuDivider(),

                                          // Section B: Library
                                          _menuItem(
                                              Icons.bookmarks_outlined,
                                              'Bookmarks Manager',
                                              'show_bookmarks',
                                              textClr),
                                          _menuItem(
                                              Icons.history,
                                              'Browser History',
                                              'show_history',
                                              textClr),
                                          const PopupMenuDivider(),

                                          // Section C: Page tools
                                          _menuItem(Icons.menu_book_outlined,
                                              'Reader Mode', 'reader', textClr),
                                          _menuItem(Icons.search_rounded,
                                              'Find in page', 'find', textClr),
                                          _menuItem(
                                              Icons.camera_alt_outlined,
                                              'Capture page',
                                              'capture',
                                              textClr),
                                          _menuItem(
                                              Icons.translate_rounded,
                                              'Translate page',
                                              'translate',
                                              textClr),
                                          _menuItem(Icons.print_outlined,
                                              'Print / PDF', 'print', textClr),
                                          const PopupMenuDivider(),

                                          // Section D: Quick toggles
                                          _menuItem(
                                            _isSnifferEnabled
                                                ? Icons.radar_rounded
                                                : Icons.radar_outlined,
                                            _isSnifferEnabled
                                                ? 'Stream sniffer: ON'
                                                : 'Stream sniffer: OFF',
                                            'sniffer',
                                            _isSnifferEnabled
                                                ? (isDark
                                                    ? AppTheme.neonAmber
                                                    : AppTheme.lightNeonAmber)
                                                : textClr,
                                          ),
                                          _menuItem(
                                            settings.blockImages
                                                ? Icons
                                                    .image_not_supported_rounded
                                                : Icons.image_rounded,
                                            settings.blockImages
                                                ? 'Images: BLOCKED'
                                                : 'Images: VISIBLE',
                                            'block_images',
                                            settings.blockImages
                                                ? (isDark
                                                    ? AppTheme.neonViolet
                                                    : AppTheme.lightNeonViolet)
                                                : textClr,
                                          ),
                                          const PopupMenuDivider(),

                                          // Section F: Session
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
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // UX 3.15: Incognito banner (below the URL bar)
                      if ((activeTab.isIncognito ||
                              settings.incognitoEnabled) &&
                          !_incognitoBannerDismissed)
                        Material(
                          color: const Color(0xFF1A1A2E),
                          child: SafeArea(
                            top: false,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              child: Row(
                                children: [
                                  const Icon(Icons.visibility_off_rounded,
                                      size: 14, color: AppTheme.neonViolet),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Incognito — history and cookies are not saved',
                                      style: TextStyle(
                                        color: Colors.white
                                            .withValues(alpha: 0.85),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () => setState(
                                        () => _incognitoBannerDismissed = true),
                                    child: const Padding(
                                      padding: EdgeInsets.all(2),
                                      child: Icon(Icons.close_rounded,
                                          size: 16, color: AppTheme.neonViolet),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      // UX 3.7: Tab strip for 2+ tabs
                      if (_tabs.length >= 2)
                        _buildTabStrip(context, settings, isDark, textClr),
                      if (activeTab.isLoading &&
                          !activeTab.isHome &&
                          !activeTab.isDisposed)
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
                                          transitionBuilder:
                                              (child, animation) =>
                                                  FadeTransition(
                                                      opacity: animation,
                                                      child: child),
                                          child: IndexedStack(
                                            index: _currentTabIndex >= 0 &&
                                                    _currentTabIndex <
                                                        _tabs.length
                                                ? _currentTabIndex
                                                : 0,
                                            children: _tabs.map((tab) {
                                              final tabIndex =
                                                  _tabs.indexOf(tab);
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
                                                if (!isLive ||
                                                    tab.isSuspended) {
                                                  return SizedBox(
                                                    width: double.infinity,
                                                    height: double.infinity,
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
                                                            Icon(Icons.web,
                                                                size: 48,
                                                                color: (isDark
                                                                        ? AppTheme
                                                                            .neonBlue
                                                                        : AppTheme
                                                                            .lightNeonBlue)
                                                                    .withValues(
                                                                        alpha:
                                                                            0.6)),
                                                            const SizedBox(
                                                                height: 12),
                                                            Text(
                                                              tab.title
                                                                      .isNotEmpty
                                                                  ? tab.title
                                                                  : 'Web Page',
                                                              style: TextStyle(
                                                                  fontSize: 16,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w600,
                                                                  color: isDark
                                                                      ? Colors
                                                                          .white
                                                                      : Colors
                                                                          .black87),
                                                              textAlign:
                                                                  TextAlign
                                                                      .center,
                                                            ),
                                                            if (tab.url
                                                                .isNotEmpty) ...[
                                                              const SizedBox(
                                                                  height: 4),
                                                              Padding(
                                                                padding: const EdgeInsets
                                                                    .symmetric(
                                                                    horizontal:
                                                                        24),
                                                                child: Text(
                                                                  tab.domain
                                                                          .isNotEmpty
                                                                      ? tab
                                                                          .domain
                                                                      : tab.url,
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
                                                    key: ValueKey(
                                                        'webview_${tab.id}'),
                                                    child: RefreshIndicator(
                                                      color: isDark
                                                          ? AppTheme.neonBlue
                                                          : AppTheme
                                                              .lightNeonBlue,
                                                      onRefresh: () async {
                                                        tab.hasCrashed = false;
                                                        await _refreshTabForPull(
                                                            tab);
                                                      },
                                                      child: tab.hasCrashed
                                                          // E11: Tab Crash Recovery Visual Feedback
                                                          ? AnimatedOpacity(
                                                              opacity: 1.0,
                                                              duration: AppTheme
                                                                  .motionBase,
                                                              child: Container(
                                                                color: isDark
                                                                    ? AppTheme
                                                                        .surface
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
                                                                            end:
                                                                                1.0),
                                                                        duration:
                                                                            const Duration(milliseconds: 600),
                                                                        curve: Curves
                                                                            .elasticOut,
                                                                        builder: (context,
                                                                            value,
                                                                            child) {
                                                                          final offset = sin(value * pi * 4) *
                                                                              (1 - value) *
                                                                              4;
                                                                          return Transform.translate(
                                                                              offset: Offset(offset, 0),
                                                                              child: child);
                                                                        },
                                                                        child: const Icon(
                                                                            Icons
                                                                                .error_outline_rounded,
                                                                            size:
                                                                                54,
                                                                            color:
                                                                                Colors.orangeAccent),
                                                                      ),
                                                                      const SizedBox(
                                                                          height:
                                                                              12),
                                                                      Text(
                                                                          'This tab crashed unexpectedly',
                                                                          style: TextStyle(
                                                                              fontSize: 16,
                                                                              fontWeight: FontWeight.bold,
                                                                              color: isDark ? Colors.white : Colors.black87)),
                                                                      const SizedBox(
                                                                          height:
                                                                              8),
                                                                      Text(tab.url,
                                                                          style: TextStyle(
                                                                              fontSize: 12,
                                                                              color: isDark ? Colors.white54 : Colors.black54),
                                                                          maxLines: 1,
                                                                          overflow: TextOverflow.ellipsis),
                                                                      const SizedBox(
                                                                          height:
                                                                              16),
                                                                      ElevatedButton
                                                                          .icon(
                                                                        style: ElevatedButton.styleFrom(
                                                                            backgroundColor: isDark
                                                                                ? AppTheme.neonBlue
                                                                                : AppTheme.lightNeonBlue,
                                                                            foregroundColor: Colors.white),
                                                                        onPressed:
                                                                            () {
                                                                          _safeReloadTab(
                                                                              tab);
                                                                        },
                                                                        icon: const Icon(
                                                                            Icons
                                                                                .refresh_rounded,
                                                                            size:
                                                                                18),
                                                                        label: const Text(
                                                                            'Reload Tab'),
                                                                      ),
                                                                    ],
                                                                  ),
                                                                ),
                                                              ),
                                                            )
                                                          : tab.hasError
                                                              ? Container(
                                                                  color: isDark
                                                                      ? AppTheme
                                                                          .surface
                                                                      : AppTheme
                                                                          .lightSurface,
                                                                  child: Center(
                                                                    child:
                                                                        Column(
                                                                      mainAxisAlignment:
                                                                          MainAxisAlignment
                                                                              .center,
                                                                      children: [
                                                                        const Icon(
                                                                            Icons
                                                                                .wifi_off_rounded,
                                                                            size:
                                                                                48,
                                                                            color:
                                                                                Colors.grey),
                                                                        const SizedBox(
                                                                            height:
                                                                                16),
                                                                        Text(
                                                                          'Failed to load page',
                                                                          style:
                                                                              TextStyle(
                                                                            fontSize:
                                                                                16,
                                                                            fontWeight:
                                                                                FontWeight.bold,
                                                                            color: isDark
                                                                                ? Colors.white
                                                                                : Colors.black87,
                                                                          ),
                                                                        ),
                                                                        const SizedBox(
                                                                            height:
                                                                                8),
                                                                        Padding(
                                                                          padding: const EdgeInsets
                                                                              .symmetric(
                                                                              horizontal: 32),
                                                                          child:
                                                                              Text(
                                                                            tab.errorDescription ??
                                                                                'Unknown error',
                                                                            textAlign:
                                                                                TextAlign.center,
                                                                            style:
                                                                                TextStyle(
                                                                              fontSize: 12,
                                                                              color: isDark ? Colors.white54 : Colors.black54,
                                                                            ),
                                                                          ),
                                                                        ),
                                                                        const SizedBox(
                                                                            height:
                                                                                16),
                                                                        ElevatedButton
                                                                            .icon(
                                                                          style:
                                                                              ElevatedButton.styleFrom(
                                                                            backgroundColor: isDark
                                                                                ? AppTheme.neonBlue
                                                                                : AppTheme.lightNeonBlue,
                                                                            foregroundColor:
                                                                                Colors.white,
                                                                          ),
                                                                          onPressed:
                                                                              () {
                                                                            setState(() {
                                                                              tab.hasError = false;
                                                                            });
                                                                            _safeReloadTab(tab);
                                                                          },
                                                                          icon: const Icon(
                                                                              Icons.refresh,
                                                                              size: 18),
                                                                          label:
                                                                              const Text('Retry'),
                                                                        ),
                                                                      ],
                                                                    ),
                                                                  ),
                                                                )
                                                              : Stack(
                                                                  children: [
                                                                    RepaintBoundary(
                                                                      child:
                                                                          InAppWebView(
                                                                        findInteractionController:
                                                                            tab.findInteractionController,
                                                                        initialUrlRequest: tab.url.isEmpty
                                                                            ? null
                                                                            : URLRequest(url: WebUri(tab.url)),
                                                                        onWebViewCreated:
                                                                            (controller) {
                                                                          _configureController(
                                                                              tab,
                                                                              controller);
                                                                          _hideWebViewFingerprints(
                                                                              tab);
                                                                          if (tab.url.isNotEmpty &&
                                                                              tab.url != 'about:blank') {
                                                                            controller.loadUrl(urlRequest: URLRequest(url: WebUri(tab.url)));
                                                                          }
                                                                        },
                                                                        initialUserScripts:
                                                                            UnmodifiableListView<UserScript>([
                                                                          UserScript(
                                                                            source:
                                                                                '''
                                                                  window.XDM_LongPress = { postMessage: function(msg) { window.flutter_inappwebview.callHandler('XDM_LongPress', msg); } };
                                                                  window.XDM_Popups = { postMessage: function(msg) { window.flutter_inappwebview.callHandler('XDM_Popups', msg); } };
                                                                  window.XdmPickerChannel = { postMessage: function(msg) { window.flutter_inappwebview.callHandler('XdmPickerChannel', msg); } };
                                                                  ${ScriptInjector.kLongPressScript}
                                                                ''',
                                                                            injectionTime:
                                                                                UserScriptInjectionTime.AT_DOCUMENT_START,
                                                                          ),
                                                                          UserScript(
                                                                            source:
                                                                                AdBlockerService.youtubeEarlyJs,
                                                                            injectionTime:
                                                                                UserScriptInjectionTime.AT_DOCUMENT_START,
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
                                                                          supportZoom:
                                                                              settings.desktopMode || settings.pinchToZoom,
                                                                          contentBlockers:
                                                                              _adBlocker.contentBlockers,
                                                                          incognito:
                                                                              tab.isIncognito,
                                                                          supportMultipleWindows:
                                                                              true,
                                                                          javaScriptCanOpenWindowsAutomatically:
                                                                              true,
                                                                        ),
                                                                        onReceivedServerTrustAuthRequest:
                                                                            (controller,
                                                                                challenge) async {
                                                                          final settings = Provider.of<SettingsProvider>(
                                                                              context,
                                                                              listen: false);
                                                                          if (settings
                                                                              .bypassSSL) {
                                                                            return ServerTrustAuthResponse(action: ServerTrustAuthResponseAction.PROCEED);
                                                                          }
                                                                          return ServerTrustAuthResponse(
                                                                              action: ServerTrustAuthResponseAction.CANCEL);
                                                                        },
                                                                        onCreateWindow:
                                                                            (controller,
                                                                                createWindowAction) async {
                                                                          final reqUrl = createWindowAction
                                                                              .request
                                                                              .url;
                                                                          if (reqUrl !=
                                                                              null) {
                                                                            // Fix #2: Route window.open() to a new tab via
                                                                            // popup handling (ad-block, download-intercept,
                                                                            // background tab creation) rather than replacing
                                                                            // the current page in the same controller.
                                                                            _handlePopupMessageForTab(tab,
                                                                                JavaScriptMessage(message: reqUrl.toString()));
                                                                          }
                                                                          return true;
                                                                        },
                                                                        onConsoleMessage:
                                                                            (controller,
                                                                                consoleMessage) {
                                                                          final msg =
                                                                              consoleMessage.message;
                                                                          if (msg.contains('recaptcha') ||
                                                                              msg.contains("reading 'e3'")) {
                                                                            return;
                                                                          }
                                                                          _log.fine(
                                                                              '[WebView Console] ${consoleMessage.messageLevel}: $msg');
                                                                        },
                                                                        onLongPressHitTestResult:
                                                                            (controller,
                                                                                hitTestResult) async {
                                                                          triggerHaptic(
                                                                              settings);
                                                                          var targetUrl =
                                                                              hitTestResult.extra;
                                                                          String
                                                                              typeOverride =
                                                                              '';
                                                                          if (targetUrl == null ||
                                                                              targetUrl.trim().isEmpty) {
                                                                            try {
                                                                              final jsUrl = await controller.evaluateJavascript(
                                                                                source: _longPressTargetFallbackJs,
                                                                              );
                                                                              final resolved = _parseLongPressTarget(jsUrl?.toString());
                                                                              if (resolved != null) {
                                                                                targetUrl = resolved.$1;
                                                                                typeOverride = resolved.$2;
                                                                              }
                                                                            } catch (_) {}
                                                                          }
                                                                          if (targetUrl != null &&
                                                                              targetUrl.trim().isNotEmpty) {
                                                                            if (!mounted ||
                                                                                !context.mounted) {
                                                                              return;
                                                                            }
                                                                            String type = typeOverride.isNotEmpty
                                                                                ? typeOverride
                                                                                : 'link';
                                                                            final hType =
                                                                                hitTestResult.type;
                                                                            if (hType == InAppWebViewHitTestResultType.IMAGE_TYPE ||
                                                                                hType == InAppWebViewHitTestResultType.SRC_IMAGE_ANCHOR_TYPE) {
                                                                              type = 'image';
                                                                            }
                                                                            if (!mounted ||
                                                                                !context.mounted) {
                                                                              return;
                                                                            }
                                                                            _showLongPressSheet(
                                                                                context,
                                                                                targetUrl.trim(),
                                                                                type,
                                                                                tabId: tab.id);
                                                                          }
                                                                        },
                                                                        gestureRecognizers: const <Factory<
                                                                            OneSequenceGestureRecognizer>>{},
                                                                        pullToRefreshController:
                                                                            tab.pullToRefreshController,
                                                                        onScrollChanged: (controller,
                                                                            x,
                                                                            y) {
                                                                          if (mounted &&
                                                                              _currentTabIndex >= 0 &&
                                                                              _currentTabIndex < _tabs.length &&
                                                                              _tabs[_currentTabIndex].id == tab.id) {
                                                                            _handleScroll(y.toDouble());
                                                                          }
                                                                        },
                                                                        onLoadStart:
                                                                            (controller,
                                                                                url) {
                                                                          _onPageStart(
                                                                              tab,
                                                                              url?.toString() ?? '');
                                                                        },
                                                                        onLoadStop:
                                                                            (controller,
                                                                                url) async {
                                                                          _onPageStop(
                                                                              tab,
                                                                              url?.toString() ?? '');
                                                                          if (url ==
                                                                              null) {
                                                                            return;
                                                                          }
                                                                          final res =
                                                                              await _redirectGuard.extractFromPage(
                                                                            tabId:
                                                                                tab.id,
                                                                            controller:
                                                                                controller,
                                                                          );
                                                                          switch (
                                                                              res.decision) {
                                                                            case RedirectDecision.autoFollow:
                                                                              await Future.delayed(const Duration(milliseconds: 400));
                                                                              await controller.loadUrl(urlRequest: URLRequest(url: WebUri(res.targetUrl!)));
                                                                              break;
                                                                            case RedirectDecision.promptUser:
                                                                              if (context.mounted) {
                                                                                RedirectSheet.show(
                                                                                  context,
                                                                                  candidates: res.candidates,
                                                                                  onSelected: (u) {
                                                                                    controller.loadUrl(urlRequest: URLRequest(url: WebUri(u)));
                                                                                  },
                                                                                );
                                                                              }
                                                                              break;
                                                                            case RedirectDecision.block:
                                                                            case RedirectDecision.ignore:
                                                                              break;
                                                                          }
                                                                        },
                                                                        onProgressChanged:
                                                                            (controller,
                                                                                progress) {
                                                                          if (progress == 0 ||
                                                                              progress == 100 ||
                                                                              (progress - tab.lastRenderedProgress).abs() >= 2) {
                                                                            tab.lastRenderedProgress =
                                                                                progress;
                                                                            tab.progress =
                                                                                progress / 100;
                                                                          }
                                                                        },
                                                                        onUpdateVisitedHistory: (controller,
                                                                            url,
                                                                            isReload) {
                                                                          if (url !=
                                                                              null) {
                                                                            _onUrlChange(tab,
                                                                                url.toString());
                                                                          }
                                                                        },
                                                                        onDownloadStartRequest:
                                                                            (controller,
                                                                                downloadStartRequest) async {
                                                                          final url = downloadStartRequest
                                                                              .url
                                                                              .toString();
                                                                          _log.info(
                                                                              '[Browser] onDownloadStartRequest: $url');
                                                                          _markUrlAsDownloaded(
                                                                              url);
                                                                          final isDark =
                                                                              Provider.of<SettingsProvider>(context, listen: false).isDarkMode;
                                                                          final result =
                                                                              await _interceptor.startDirectDownload(
                                                                            url,
                                                                            suggestedName:
                                                                                downloadStartRequest.suggestedFilename,
                                                                            mimeType:
                                                                                downloadStartRequest.mimeType,
                                                                            contentLength:
                                                                                downloadStartRequest.contentLength,
                                                                            contentDisposition:
                                                                                downloadStartRequest.contentDisposition,
                                                                          );
                                                                          if (!context
                                                                              .mounted) {
                                                                            return;
                                                                          }
                                                                          if (result.status ==
                                                                              InterceptDownloadStatus
                                                                                  .queued) {
                                                                            final filename =
                                                                                downloadStartRequest.suggestedFilename ?? fileNameFromUrl(url);
                                                                            ThemedSnackbar.show(
                                                                              context,
                                                                              message: 'Download started: $filename',
                                                                              icon: Icons.download_done_rounded,
                                                                              color: AppTheme.neonGreen,
                                                                              isDarkMode: isDark,
                                                                            );
                                                                          } else if (result.status ==
                                                                              InterceptDownloadStatus.alreadyInProgress) {
                                                                            ThemedSnackbar.show(
                                                                              context,
                                                                              message: 'Download already in progress',
                                                                              icon: Icons.info_outline,
                                                                              color: AppTheme.neonAmber,
                                                                              isDarkMode: isDark,
                                                                            );
                                                                          }
                                                                        },
                                                                        onReceivedError: (controller,
                                                                            request,
                                                                            error) async {
                                                                          _log.warning(
                                                                              '[Browser] WebResourceError on tab ${tab.id}: ${error.description}');
                                                                          final errUrl = request
                                                                              .url
                                                                              .toString();
                                                                          if (errUrl.startsWith('magnet:') ||
                                                                              isMagnetUrl(errUrl) ||
                                                                              error.description.contains('ERR_UNKNOWN_URL_SCHEME')) {
                                                                            _log.info('[Browser] WebResourceError handled for magnet link: $errUrl');
                                                                            controller.stopLoading();
                                                                            if (await controller.canGoBack()) {
                                                                              await controller.goBack();
                                                                            }
                                                                            if (mounted) {
                                                                              setState(() {
                                                                                tab.isLoading = false;
                                                                              });
                                                                            }
                                                                            return;
                                                                          }
                                                                          if (mounted &&
                                                                              request.isForMainFrame == true) {
                                                                            setState(() {
                                                                              tab.isLoading = false;
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
                                                                              tab.isLoading = false;
                                                                              tab.hasCrashed = true;
                                                                              tab.controller = null;
                                                                            });
                                                                          }
                                                                        },
                                                                        shouldInterceptRequest:
                                                                            (controller,
                                                                                request) async {
                                                                          // Never block main-frame requests
                                                                          if (request.isForMainFrame ==
                                                                              true) {
                                                                            return null;
                                                                          }

                                                                          final requestHost = request
                                                                              .url
                                                                              .host
                                                                              .toLowerCase();

                                                                          // Instant fast-path: Never block YouTube, Google, gstatic, or core media infrastructure
                                                                          const whitelistedDomains =
                                                                              [
                                                                            'youtube.com',
                                                                            'youtu.be',
                                                                            'ytimg.com',
                                                                            'googlesyndication.com',
                                                                            'googlevideo.com',
                                                                            'ggpht.com',
                                                                            'googleapis.com',
                                                                            'google.com',
                                                                            'gstatic.com',
                                                                          ];
                                                                          bool
                                                                              isWhitelisted =
                                                                              false;
                                                                          for (final d
                                                                              in whitelistedDomains) {
                                                                            if (requestHost == d ||
                                                                                requestHost.endsWith('.$d')) {
                                                                              isWhitelisted = true;
                                                                              break;
                                                                            }
                                                                          }
                                                                          if (isWhitelisted) {
                                                                            return null;
                                                                          }

                                                                          // Never block same-origin requests (requests to the current site's own domain or subdomains)
                                                                          final pageUrl =
                                                                              tab.url;
                                                                          if (pageUrl
                                                                              .isNotEmpty) {
                                                                            final pageHost =
                                                                                Uri.tryParse(pageUrl)?.host.toLowerCase() ?? '';
                                                                            if (pageHost.isNotEmpty &&
                                                                                (requestHost == pageHost || requestHost.endsWith('.$pageHost') || (requestHost.contains('.') && pageHost.endsWith('.$requestHost')))) {
                                                                              return null;
                                                                            }
                                                                          }

                                                                          final url = request
                                                                              .url
                                                                              .toString();
                                                                          if (_adBlocker
                                                                              .shouldBlock(url)) {
                                                                            _adBlocker.recordBlocked(url);
                                                                            final count =
                                                                                (_blockedAdsPerTab[tab.id] ?? 0) + 1;
                                                                            _blockedAdsPerTab[tab.id] =
                                                                                count;

                                                                            // Fix: Update the active tab's notifier so the UI badge updates in real-time
                                                                            if (_currentTabIndex >= 0 &&
                                                                                _currentTabIndex < _tabs.length &&
                                                                                _tabs[_currentTabIndex].id == tab.id) {
                                                                              if (_zeroNotifierTabId == tab.id) {
                                                                                _zeroNotifier.value = count;
                                                                              } else {
                                                                                final notifier = _blockedAdsNotifiers[tab.id];
                                                                                if (notifier != null) {
                                                                                  notifier.value = count;
                                                                                }
                                                                              }
                                                                            }

                                                                            return WebResourceResponse(
                                                                              contentType: 'text/plain',
                                                                              contentEncoding: 'utf-8',
                                                                              statusCode: 204,
                                                                              reasonPhrase: 'Blocked',
                                                                              data: Uint8List(0),
                                                                            );
                                                                          }
                                                                          return null;
                                                                        },
                                                                        shouldOverrideUrlLoading:
                                                                            (controller,
                                                                                navigationAction) async {
                                                                          final url =
                                                                              navigationAction.request.url?.toString() ?? '';
                                                                          if (url
                                                                              .isEmpty) {
                                                                            return NavigationActionPolicy.ALLOW;
                                                                          }
                                                                          if ((_navigatingBackForwardTabIds[tab.id] ??
                                                                              false)) {
                                                                            return NavigationActionPolicy.ALLOW;
                                                                          }
                                                                          if (_recentDownloadUrls
                                                                              .contains(url)) {
                                                                            _log.info('[Browser] shouldOverrideUrlLoading: ignoring $url (already downloading)');
                                                                            return NavigationActionPolicy.CANCEL;
                                                                          }

                                                                          final res =
                                                                              await _redirectGuard.evaluate(
                                                                            tabId:
                                                                                tab.id,
                                                                            navigatingTo:
                                                                                url,
                                                                          );
                                                                          if (res.decision ==
                                                                              RedirectDecision.block) {
                                                                            return NavigationActionPolicy.CANCEL;
                                                                          }

                                                                          // 0. Ad-blocker: cancel navigation-level ad redirects
                                                                          // Only block sub-frame navigations (ads redirect in iframes/popups)
                                                                          // Never block main-frame navigations so user can still browse
                                                                          if (navigationAction.isForMainFrame != true &&
                                                                              _adBlocker.shouldBlock(url)) {
                                                                            _adBlocker.recordBlocked(url);
                                                                            return NavigationActionPolicy.CANCEL;
                                                                          }

                                                                          // 1. Magnet link check
                                                                          if (url.startsWith('magnet:') ||
                                                                              isMagnetUrl(url)) {
                                                                            _log.info('[Browser] Intercepted magnet link in navigation: $url');
                                                                            if (context.mounted) {
                                                                              _showInterceptionSheet(context, url);
                                                                            }
                                                                            return NavigationActionPolicy.CANCEL;
                                                                          }

                                                                          // 2. HTTPS-only upgrade check
                                                                          if (navigationAction.isForMainFrame == true &&
                                                                              settings.httpsOnly &&
                                                                              url.startsWith('http://')) {
                                                                            final upgraded =
                                                                                url.replaceFirst('http://', 'https://');
                                                                            _log.warning('[Browser] HTTPS-only: upgrading $url -> $upgraded');
                                                                            controller.loadUrl(urlRequest: URLRequest(url: WebUri(upgraded)));
                                                                            return NavigationActionPolicy.CANCEL;
                                                                          }

                                                                          // 2b. UX 3.10: Open in external app (user-initiated main-frame only).
                                                                          if (navigationAction.isForMainFrame == true &&
                                                                              navigationAction.hasGesture == true &&
                                                                              await _maybeOpenInApp(url)) {
                                                                            return NavigationActionPolicy.CANCEL;
                                                                          }

                                                                          // 3. Bypass check
                                                                          // 4. Smart classification
                                                                          final classification = await PageIntentClassifier
                                                                              .instance
                                                                              .classifyWithContextAsync(
                                                                            currentUrl:
                                                                                tab.url,
                                                                            targetUrl:
                                                                                url,
                                                                            interceptor:
                                                                                _interceptor,
                                                                            isUserInitiated:
                                                                                navigationAction.isForMainFrame,
                                                                            isFromClick:
                                                                                navigationAction.request.method == 'GET',
                                                                          );

                                                                          _log.info(
                                                                              '[Browser] Classification for $url: ${classification.action.name} (intent: ${classification.intent.name}, confidence: ${classification.confidence})');

                                                                          switch (
                                                                              classification.action) {
                                                                            case PageAction.block:
                                                                              AdBlockerService.instance.recordBlockedRequest(url);
                                                                              _log.warning('[AdBlocker] Blocked: $url');
                                                                              return NavigationActionPolicy.CANCEL;

                                                                            case PageAction.openNewTab:
                                                                            case PageAction.openNewTabWithWarning:
                                                                            case PageAction.openNewTabWithDownloadSuggestion:
                                                                              // Browser redirects (e.g. http→https, www→non-www)
                                                                              // must navigate inside the current tab, not open a
                                                                              // new one — guard with isRedirect.
                                                                              if (navigationAction.isRedirect == true) {
                                                                                return NavigationActionPolicy.ALLOW;
                                                                              }
                                                                              // User-triggered tap → open in foreground.
                                                                              if (navigationAction.hasGesture == true) {
                                                                                _openInNewTab(url, isIncognito: tab.isIncognito, switchToTab: true, origin: TabOrigin.userDirect);
                                                                                return NavigationActionPolicy.CANCEL;
                                                                              }
                                                                              // Auto/ad navigation → background tab.
                                                                              _evictStaleAdTabs();
                                                                              _openInNewTab(url, isIncognito: tab.isIncognito, switchToTab: false, origin: TabOrigin.adOrPopup);
                                                                              if (context.mounted) {
                                                                                final bgSettings = Provider.of<SettingsProvider>(context, listen: false);
                                                                                final bgDark = bgSettings.isDarkMode;
                                                                                final bgRtl = L10n.isRtl(context);
                                                                                ThemedSnackbar.show(
                                                                                  context,
                                                                                  message: bgRtl ? 'تم فتح علامة تبويب في الخلفية' : 'Opened in background tab',
                                                                                  color: bgDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                                                                                  icon: Icons.tab_rounded,
                                                                                  isDarkMode: bgDark,
                                                                                );
                                                                              }
                                                                              if (classification.action == PageAction.openNewTabWithDownloadSuggestion) {
                                                                                _suggestDownload(url, classification);
                                                                              }
                                                                              if (classification.action == PageAction.openNewTabWithWarning) {
                                                                                if (context.mounted) {
                                                                                  _showAdWarning(context, url);
                                                                                }
                                                                              }
                                                                              return NavigationActionPolicy.CANCEL;

                                                                            case PageAction.openBackgroundTab:
                                                                              _openInBackgroundTab(url, isIncognito: tab.isIncognito);
                                                                              return NavigationActionPolicy.CANCEL;

                                                                            case PageAction.directDownload:
                                                                              if (context.mounted) {
                                                                                _showInterceptionSheet(context, url);
                                                                              }
                                                                              return NavigationActionPolicy.CANCEL;

                                                                            case PageAction.openSameTab:
                                                                              if (_interceptor.shouldIntercept(tabUrl: tab.url, requestUrl: url)) {
                                                                                setState(() {
                                                                                  _detectedDownloadUrls[tab.id] = url;
                                                                                });
                                                                                if (context.mounted) {
                                                                                  _showInterceptionSheet(context, url);
                                                                                }
                                                                                return NavigationActionPolicy.CANCEL;
                                                                              }
                                                                              return NavigationActionPolicy.ALLOW;
                                                                          }
                                                                        },
                                                                      ),
                                                                    ),
                                                                    // E13: Tab Suspension/Resume Visual Feedback
                                                                    if (_restoringTabId ==
                                                                        tab.id)
                                                                      Positioned
                                                                          .fill(
                                                                        child:
                                                                            AnimatedOpacity(
                                                                          opacity:
                                                                              1.0,
                                                                          duration:
                                                                              AppTheme.motionBase,
                                                                          child:
                                                                              Container(
                                                                            color:
                                                                                Colors.black.withValues(alpha: 0.7),
                                                                            child:
                                                                                const Center(child: Text('Restoring tab...', style: TextStyle(color: Colors.white, fontSize: 16))),
                                                                          ),
                                                                        ),
                                                                      ),
                                                                    // E5: Media Sniffer Detection Feedback
                                                                    if (_detectedMediaSources[activeTab.id]
                                                                            ?.isNotEmpty ??
                                                                        false)
                                                                      Positioned(
                                                                        top: 16,
                                                                        right:
                                                                            16,
                                                                        child:
                                                                            AnimatedScale(
                                                                          scale:
                                                                              1.0,
                                                                          duration:
                                                                              AppTheme.motionBase,
                                                                          child:
                                                                              AnimatedOpacity(
                                                                            opacity:
                                                                                1.0,
                                                                            duration:
                                                                                AppTheme.motionBase,
                                                                            child:
                                                                                Stack(
                                                                              alignment: Alignment.center,
                                                                              children: [
                                                                                Container(
                                                                                  width: 24,
                                                                                  height: 24,
                                                                                  decoration: BoxDecoration(shape: BoxShape.circle, color: AppTheme.neonBlue.withValues(alpha: 0.3)),
                                                                                ),
                                                                                const CircleAvatar(
                                                                                  backgroundColor: AppTheme.neonBlue,
                                                                                  radius: 10,
                                                                                  child: Icon(Icons.download_rounded, size: 12, color: Colors.white),
                                                                                ),
                                                                                Positioned(
                                                                                  top: -4,
                                                                                  right: -4,
                                                                                  child: Container(
                                                                                    padding: const EdgeInsets.all(2),
                                                                                    decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                                                                                    constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
                                                                                    child: Text('${_detectedMediaSources[activeTab.id]!.length}', style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
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
                                                                        right:
                                                                            0,
                                                                        child:
                                                                            Material(
                                                                          color:
                                                                              Colors.blue,
                                                                          child:
                                                                              Padding(
                                                                            padding:
                                                                                const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
                                                                            child:
                                                                                Row(
                                                                              children: [
                                                                                const Icon(Icons.touch_app_rounded, color: Colors.white, size: 16),
                                                                                const SizedBox(width: 8),
                                                                                const Expanded(child: Text('Element Picker Mode — Tap an element to block it', style: TextStyle(color: Colors.white, fontSize: 12))),
                                                                                TextButton(onPressed: () => setState(() => _isPickerModeActive = false), child: const Text('Done', style: TextStyle(color: Colors.white))),
                                                                              ],
                                                                            ),
                                                                          ),
                                                                        ),
                                                                      ),
                                                                    if (_isPickerModeActive)
                                                                      Positioned
                                                                          .fill(
                                                                        child:
                                                                            IgnorePointer(
                                                                          ignoring:
                                                                              true,
                                                                          child:
                                                                              Container(decoration: BoxDecoration(border: Border.all(color: Colors.blue.withValues(alpha: 0.5), width: 2))),
                                                                        ),
                                                                      ),
                                                                    // E12: Tab Timeout Visual Feedback
                                                                    if (tab.isTimedOut &&
                                                                        tab.isLoading)
                                                                      Positioned(
                                                                        top: 0,
                                                                        left: 0,
                                                                        right:
                                                                            0,
                                                                        child:
                                                                            AnimatedOpacity(
                                                                          opacity:
                                                                              1.0,
                                                                          duration:
                                                                              AppTheme.motionBase,
                                                                          child:
                                                                              Container(
                                                                            padding:
                                                                                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                                                            color:
                                                                                Colors.orange.withValues(alpha: 0.9),
                                                                            child:
                                                                                Row(
                                                                              children: [
                                                                                TweenAnimationBuilder<double>(
                                                                                  tween: Tween(begin: 0.8, end: 1.2),
                                                                                  duration: const Duration(milliseconds: 800),
                                                                                  builder: (context, value, child) => Transform.scale(scale: value, child: child),
                                                                                  child: const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.white),
                                                                                ),
                                                                                const SizedBox(width: 8),
                                                                                const Expanded(
                                                                                  child: Text('Page load taking long...', style: TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold)),
                                                                                ),
                                                                                GestureDetector(
                                                                                  onTap: () {
                                                                                    tab.controller?.evaluateJavascript(source: 'window.stop();');
                                                                                    setState(() {
                                                                                      tab.isLoading = false;
                                                                                      tab.isTimedOut = false;
                                                                                    });
                                                                                  },
                                                                                  child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Text(L10n.of(context, 'stop_loading'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12))),
                                                                                ),
                                                                                GestureDetector(
                                                                                  onTap: () {
                                                                                    _safeReloadTab(tab);
                                                                                    tab.isTimedOut = false;
                                                                                  },
                                                                                  child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Text(L10n.of(context, 'reload_page'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12))),
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
                            // UX 3.1: Find-in-page bottom panel
                            if (_findPanelVisible)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: SafeArea(
                                  top: false,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: (isDark
                                              ? AppTheme.surface
                                              : AppTheme.lightSurface)
                                          .withValues(alpha: 0.97),
                                      border: Border(
                                        top: BorderSide(
                                          color: isDark
                                              ? AppTheme.border
                                              : AppTheme.lightBorder,
                                        ),
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black
                                              .withValues(alpha: 0.2),
                                          blurRadius: 12,
                                          offset: const Offset(0, -2),
                                        ),
                                      ],
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(Icons.search_rounded,
                                            size: 18, color: textClr),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: TextField(
                                            controller: _findTextController,
                                            autofocus: true,
                                            style: TextStyle(
                                                color: textClr, fontSize: 14),
                                            cursorColor: isDark
                                                ? AppTheme.neonBlue
                                                : AppTheme.lightNeonBlue,
                                            decoration: InputDecoration(
                                              isDense: true,
                                              hintText: 'Find in page',
                                              hintStyle: TextStyle(
                                                color: isDark
                                                    ? AppTheme.textMuted
                                                    : AppTheme.lightTextMuted,
                                                fontSize: 14,
                                              ),
                                              border: InputBorder.none,
                                            ),
                                            onChanged: (q) =>
                                                _updateFindQuery(activeTab, q),
                                            onSubmitted: (q) => _findNext(true),
                                          ),
                                        ),
                                        if (_findTextController
                                                .text.isNotEmpty ||
                                            _findMatchCount > 0)
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 6),
                                            child: Text(
                                              _findMatchCount == 0 &&
                                                      _findTextController
                                                          .text.isNotEmpty
                                                  ? 'No matches'
                                                  : '$_findActiveMatch/$_findMatchCount',
                                              style: TextStyle(
                                                color: _findMatchCount == 0 &&
                                                        _findTextController
                                                            .text.isNotEmpty
                                                    ? (isDark
                                                        ? AppTheme.neonRed
                                                        : AppTheme.lightNeonRed)
                                                    : (isDark
                                                        ? AppTheme.textSecondary
                                                        : AppTheme
                                                            .lightTextSecondary),
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        IconButton(
                                          icon: const Icon(
                                              Icons.arrow_upward_rounded,
                                              size: 18),
                                          color: textClr,
                                          tooltip: 'Previous match',
                                          onPressed: () => _findNext(false),
                                        ),
                                        IconButton(
                                          icon: const Icon(
                                              Icons.arrow_downward_rounded,
                                              size: 18),
                                          color: textClr,
                                          tooltip: 'Next match',
                                          onPressed: () => _findNext(true),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.close_rounded,
                                              size: 18),
                                          color: textClr,
                                          tooltip: 'Close find',
                                          onPressed: _closeFindPanel,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            // UX 3.2: Reader-mode controls toolbar
                            if (_readerControlsVisible &&
                                _readerArticle != null)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: SafeArea(
                                  top: false,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: (isDark
                                              ? AppTheme.surface
                                              : AppTheme.lightSurface)
                                          .withValues(alpha: 0.97),
                                      border: Border(
                                        top: BorderSide(
                                          color: isDark
                                              ? AppTheme.border
                                              : AppTheme.lightBorder,
                                        ),
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black
                                              .withValues(alpha: 0.2),
                                          blurRadius: 12,
                                          offset: const Offset(0, -2),
                                        ),
                                      ],
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.format_size_rounded,
                                            size: 16, color: AppTheme.neonBlue),
                                        Expanded(
                                          child: Slider(
                                            min: 12,
                                            max: 32,
                                            divisions: 20,
                                            value: _readerFontSize,
                                            activeColor: isDark
                                                ? AppTheme.neonBlue
                                                : AppTheme.lightNeonBlue,
                                            onChanged: (v) => setState(
                                                () => _readerFontSize = v),
                                            onChangeEnd: (_) =>
                                                _updateReaderConfig(),
                                          ),
                                        ),
                                        // Theme toggle: light / dark / sepia
                                        for (final (label, theme) in [
                                          ('L', 'light'),
                                          ('D', 'dark'),
                                          ('S', 'sepia'),
                                        ])
                                          GestureDetector(
                                            onTap: () {
                                              if (_readerTheme == theme) return;
                                              setState(
                                                  () => _readerTheme = theme);
                                              _updateReaderConfig();
                                            },
                                            child: Container(
                                              margin:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 3),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 5),
                                              decoration: BoxDecoration(
                                                color: _readerTheme == theme
                                                    ? (isDark
                                                            ? AppTheme.neonBlue
                                                            : AppTheme
                                                                .lightNeonBlue)
                                                        .withValues(alpha: 0.18)
                                                    : Colors.transparent,
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                                border: Border.all(
                                                  color: _readerTheme == theme
                                                      ? (isDark
                                                              ? AppTheme
                                                                  .neonBlue
                                                              : AppTheme
                                                                  .lightNeonBlue)
                                                          .withValues(
                                                              alpha: 0.6)
                                                      : Colors.transparent,
                                                ),
                                              ),
                                              child: Text(
                                                label,
                                                style: TextStyle(
                                                  color: _readerTheme == theme
                                                      ? (isDark
                                                          ? AppTheme.neonBlue
                                                          : AppTheme
                                                              .lightNeonBlue)
                                                      : textClr,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ),
                                          ),
                                        const SizedBox(width: 4),
                                        PopupMenuButton<String>(
                                          icon: Icon(
                                              Icons.font_download_rounded,
                                              size: 16,
                                              color: textClr),
                                          tooltip: 'Font family',
                                          color: isDark
                                              ? AppTheme.surface
                                              : AppTheme.lightSurface,
                                          onSelected: (f) {
                                            setState(
                                                () => _readerFontFamily = f);
                                            _updateReaderConfig();
                                          },
                                          itemBuilder: (_) => [
                                            const PopupMenuItem(
                                              value: 'serif',
                                              child: Text('Serif',
                                                  style:
                                                      TextStyle(fontSize: 13)),
                                            ),
                                            const PopupMenuItem(
                                              value: 'sans',
                                              child: Text('Sans-serif',
                                                  style:
                                                      TextStyle(fontSize: 13)),
                                            ),
                                          ],
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.close_rounded,
                                              size: 18),
                                          color: textClr,
                                          tooltip: 'Exit reader mode',
                                          onPressed: () {
                                            setState(() {
                                              _readerControlsVisible = false;
                                              _readerArticle = null;
                                            });
                                            _goBack();
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  );
                  return Row(
                    children: [
                      if (isTablet) _buildVerticalTabSidebar(context, settings),
                      Expanded(
                        child: Stack(
                          children: [
                            mainContent,
                            if (_showTabTooltip)
                              _buildOnboardingTooltip(
                                  context, settings, isDark, isRtl),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOnboardingTooltip(
    BuildContext context,
    SettingsProvider settings,
    bool isDark,
    bool isRtl,
  ) {
    return Positioned(
      bottom: kBottomNavigationBarHeight + 12,
      right: isRtl ? null : 50,
      left: isRtl ? 50 : null,
      child: GestureDetector(
        onTap: _dismissTabTooltip,
        child: Material(
          elevation: 10,
          borderRadius: BorderRadius.circular(14),
          color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.touch_app_rounded,
                    color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Text(
                  isRtl ? 'اضغط لرؤية جميع التبويبات' : 'Tap to see all tabs',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.close_rounded,
                    color: Colors.white70, size: 14),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVerticalTabSidebar(
      BuildContext context, SettingsProvider settings) {
    final isDark = settings.isDarkMode;
    final isAmoled = settings.isAmoledMode;
    final bgClr = isAmoled
        ? Colors.black
        : (isDark ? AppTheme.surface : AppTheme.lightSurface);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final isRtl = L10n.isRtl(context);

    return Container(
      width: 220,
      decoration: BoxDecoration(
        color: bgClr,
        border: Border(
          right: isRtl
              ? BorderSide.none
              : BorderSide(
                  color:
                      isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                  width: 0.8,
                ),
          left: isRtl
              ? BorderSide(
                  color:
                      isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                  width: 0.8,
                )
              : BorderSide.none,
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                children: [
                  Icon(Icons.tab_rounded, color: accent, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    isRtl ? 'التبويبات' : 'Tabs',
                    style: TextStyle(
                      color: textClr,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.add, color: accent, size: 20),
                    tooltip: isRtl ? 'تبويب جديد' : 'New Tab',
                    onPressed: () {
                      lightPulse(settings);
                      _openInNewTab(
                        'about:blank',
                        isIncognito: settings.incognitoEnabled,
                        switchToTab: true,
                      );
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                itemCount: _tabs.length,
                itemBuilder: (context, index) {
                  final tab = _tabs[index];
                  final isActive = index == _currentTabIndex;

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        onTap: () {
                          lightPulse(settings);
                          _switchTab(index);
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: isActive
                                ? accent.withValues(alpha: 0.15)
                                : (isDark
                                    ? Colors.white.withValues(alpha: 0.03)
                                    : Colors.black.withValues(alpha: 0.03)),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isActive
                                  ? accent.withValues(alpha: 0.5)
                                  : Colors.transparent,
                              width: 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Hero(
                                tag: 'tab_favicon_${tab.id}',
                                child: Container(
                                  width: 18,
                                  height: 18,
                                  alignment: Alignment.center,
                                  child: tab.faviconUrl != null
                                      ? Image.network(
                                          tab.faviconUrl!,
                                          width: 16,
                                          height: 16,
                                          errorBuilder: (_, __, ___) => Icon(
                                            Icons.public_rounded,
                                            size: 14,
                                            color: textClr,
                                          ),
                                        )
                                      : Icon(
                                          Icons.public_rounded,
                                          size: 14,
                                          color: textClr,
                                        ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Hero(
                                  tag: 'tab_title_${tab.id}',
                                  child: Material(
                                    color: Colors.transparent,
                                    child: Text(
                                      tab.stripLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: isActive
                                            ? textClr
                                            : (isDark
                                                ? AppTheme.textSecondary
                                                : AppTheme.lightTextSecondary),
                                        fontSize: 12,
                                        fontWeight: isActive
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              if (_tabs.length > 1)
                                GestureDetector(
                                  onTap: () {
                                    lightPulse(settings);
                                    _closeTabAtIndex(index);
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.all(2.0),
                                    child: Icon(
                                      Icons.close_rounded,
                                      size: 14,
                                      color: isDark
                                          ? AppTheme.textMuted
                                          : AppTheme.lightTextMuted,
                                    ),
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
          ],
        ),
      ),
    );
  }

  Widget _buildTabStrip(
    BuildContext context,
    SettingsProvider settings,
    bool isDark,
    Color textClr,
  ) {
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    return Container(
      height: 40,
      color: isDark
          ? (settings.isAmoledMode
              ? AppTheme.amoledSurfaceRaised
              : AppTheme.surface)
          : AppTheme.lightSurface,
      child: ListView.builder(
        controller: _tabStripScrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: _tabs.length,
        itemBuilder: (context, index) {
          final tab = _tabs[index];
          final isActive = index == _currentTabIndex;
          return Semantics(
            button: true,
            selected: isActive,
            label: 'Tab: ${tab.stripLabel}',
            child: GestureDetector(
              onTap: () {
                triggerHaptic(settings);
                _switchTab(index);
              },
              onLongPress: () => _showTabStripMenu(context, index),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.only(right: 6, top: 4, bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: isActive
                      ? accent.withValues(alpha: 0.12)
                      : (isDark
                          ? const Color(0x0DFFFFFF)
                          : const Color(0x0D000000)),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isActive
                        ? accent.withValues(alpha: 0.7)
                        : Colors.transparent,
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (tab.faviconBytes != null)
                      Image.memory(tab.faviconBytes!,
                          width: 14, height: 14, fit: BoxFit.cover)
                    else
                      Icon(
                        tab.isIncognito
                            ? Icons.visibility_off_rounded
                            : Icons.public_rounded,
                        size: 13,
                        color: tab.isIncognito ? AppTheme.neonViolet : textClr,
                      ),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 96),
                      child: Text(
                        tab.stripLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isActive
                              ? textClr
                              : (isDark
                                  ? AppTheme.textSecondary
                                  : AppTheme.lightTextSecondary),
                          fontSize: 11,
                          fontWeight:
                              isActive ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: () => _closeTabAtIndex(index),
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(Icons.close_rounded,
                            size: 13,
                            color: isDark
                                ? AppTheme.textMuted
                                : AppTheme.lightTextMuted),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _showTabStripMenu(BuildContext context, int index) {
    if (index < 0 || index >= _tabs.length) return;
    final tab = _tabs[index];
    final settings = _settings;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor:
          settings.isDarkMode ? AppTheme.surface : AppTheme.lightSurface,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.refresh_rounded),
              title: const Text('Reload tab', style: TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(sheetContext);
                _safeReloadTab(tab);
              },
            ),
            ListTile(
              leading: const Icon(Icons.close_rounded),
              title: const Text('Close tab', style: TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(sheetContext);
                _closeTabAtIndex(index);
              },
            ),
            ListTile(
              leading: const Icon(Icons.layers_clear_rounded),
              title: const Text('Close other tabs',
                  style: TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(sheetContext);
                _closeOtherTabs(index);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_sweep_rounded),
              title:
                  const Text('Close all tabs', style: TextStyle(fontSize: 14)),
              onTap: () {
                Navigator.pop(sheetContext);
                _closeAllTabsFromStrip();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _closeTabAtIndex(int index) {
    if (index < 0 || index >= _tabs.length) return;

    final tab = _tabs[index];
    _recordClosedTab(tab);
    setState(() {
      // TabManager.closeTab() removes the tab from its internal list, recalculates
      // _currentIndex (LRU-aware), syncs the URL bar, persists state, and disposes
      // the tab post-frame. If this was the last tab it creates a fresh blank tab.
      // Do NOT manually write to _tabs (it is unmodifiable) or re-adjust
      // _currentTabIndex here — that would double-shift the index.
      _tabManager.closeTab(tab.id);
    });
    // Ensure address bars are visible after closing, especially the last tab.
    _showBarsNotifier.value = true;
  }

  void _closeOtherTabs(int keepIndex) {
    if (keepIndex < 0 || keepIndex >= _tabs.length) return;
    final keep = _tabs[keepIndex];
    final closed = _tabs.where((t) => t.id != keep.id).toList();
    setState(() {
      // Record closed-tab history first (before tabs are removed), then close
      // each via TabManager which handles removal, index adjustment, disposal, and saving.
      for (final t in closed) {
        _recordClosedTab(t);
        _tabManager.closeTab(t.id);
      }
    });
  }

  void _closeAllTabsFromStrip() {
    final list = List<BrowserTab>.from(_tabs);
    setState(() {
      for (final t in list) {
        _recordClosedTab(t);
        // TabManager handles removal, index recalculation, disposal, and saving.
        _tabManager.closeTab(t.id);
      }
    });
    // Ensure bars are shown so the user can start a new URL on the blank tab
    // that TabManager automatically creates when all tabs are closed.
    _showBarsNotifier.value = true;
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
    final settings = _settings;
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
    final settings = _settings;
    triggerHaptic(settings);
    final url = await BrowserHistorySheet.show(context);
    if (url != null && url.isNotEmpty && mounted) {
      _navigateToUrl(url);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cachedSettings = _settings;
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
    // Bug #9 fix: _buildDownloadFab can be called during tab transitions when
    // _tabs is empty or _currentTabIndex is out of bounds. Return an invisible
    // widget instead of crashing with a RangeError.
    if (_tabs.isEmpty ||
        _currentTabIndex < 0 ||
        _currentTabIndex >= _tabs.length) {
      return const SizedBox.shrink();
    }
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
    final settingsProvider = _settings;
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

  Future<void> _handleCloseOrQuit() async {
    final settings = _settings;
    triggerHaptic(settings);
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final downloadProvider = context.read<DownloadProvider>();

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(
          isRtl ? 'إغلاق المتصفح' : 'Close Browser',
          style: TextStyle(
            color: isDark ? Colors.white : Colors.black87,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          isRtl
              ? 'هل تريد إخفاء المتصفح وحفظ الجلسة أم إنهاء الجلسة بالكامل؟'
              : 'Do you want to hide the browser and save your session, or terminate completely?',
          style: TextStyle(
            color: isDark ? Colors.white70 : Colors.black54,
            fontSize: 13,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: Text(
              isRtl ? 'إلغاء' : 'Cancel',
              style: TextStyle(
                color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'hide'),
            child: Text(
              isRtl ? 'إخفاء' : 'Hide',
              style: TextStyle(
                color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'kill'),
            child: Text(
              isRtl ? 'إنهاء الجلسة' : 'Terminate',
              style: const TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (result == 'hide') {
      if (Navigator.canPop(context)) {
        Navigator.pop(context);
      } else {
        downloadProvider.setActiveTabIndex(0);
      }
    } else if (result == 'kill') {
      await _quitBrowser();
    }
  }

  Future<void> _confirmQuitBrowser() async {
    final settings = _settings;
    triggerHaptic(settings);
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed),
              const SizedBox(width: 8),
              Text(
                isRtl ? 'إنهاء المتصفح' : 'Quit Browser',
                style: TextStyle(
                    color: isDark
                        ? AppTheme.textPrimary
                        : AppTheme.lightTextPrimary,
                    fontSize: 16),
              ),
            ],
          ),
          content: Text(
            isRtl
                ? 'هل أنت تأكد من إغلاق جميع التبويبات والحفظ والخروج؟'
                : 'Are you sure you want to quit the browser and save your session?',
            style: TextStyle(
                color: isDark
                    ? AppTheme.textSecondary
                    : AppTheme.lightTextSecondary,
                fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(isRtl ? 'إلغاء' : 'Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(
                isRtl ? 'إنهاء' : 'Quit',
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      await _quitBrowser();
    }
  }

  Future<void> _quitBrowser() async {
    final settings = _settings;
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
            lastVisitedAt: t.lastVisitedAt,
            faviconUrl: t.faviconUrl,
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
      // Fix #1: Clean up per-tab state (clears incognito cache/localStorage/
      // sessionStorage/cookies) before disposing the tab's progressNotifier.
      _cleanupTabState(tab.id);
      try {
        tab.dispose();
      } catch (e, st) {
        Logger('browser_screen')
            .warning('[browser_screen] operation failed', e, st);
      }
    }
    _tabManager.clearAllTabs();
    _currentTabIndex = 0;
    // Bug #5 fix: do NOT reset _quitPersisted here. _teardownBrowserServices
    // is called by _quitBrowser() after setting _quitPersisted = true, so
    // resetting it here would incorrectly override the quit flag and could
    // cause dispose() to attempt unnecessary tab saves on an empty list.
    // Fix #1: Cancel any remaining loading-timeout timers that were not
    // cleaned up by _cleanupTabState (tabs that finished loading but whose
    // timers weren't removed from the map).
    for (final t in _loadingTimeoutTimers.values) {
      t.cancel();
    }
    _loadingTimeoutTimers.clear();
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
    // Fix #18: Use repeat(reverse: true) for continuous pulsing.
    // The old approach chained 2 cycles then stopped, making the dot appear frozen.
    _c.repeat(reverse: true);
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
    // Fix #18: Use repeat(reverse: true) for continuous pulsing.
    // The old _runTwoCycles() ran exactly 2 cycles and then froze.
    _c.repeat(reverse: true);
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
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                    fontFamily: 'Space Grotesk',
                    fontSize: 12)),
          ),
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
    final settings = Provider.of<SettingsProvider>(context);
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

/// UX 3.5: A tab that was closed during the current session, eligible for
/// restore from the "Recently closed tabs" sheet.
class _ClosedTab {
  final String url;
  final String title;
  final bool isIncognito;
  final int closedAt;
  _ClosedTab({
    required this.url,
    required this.title,
    this.isIncognito = false,
    required this.closedAt,
  });
}

/// UX 3.9: A preset zoom percentage button in the page-zoom dialog.
class _ZoomPresetButton extends StatelessWidget {
  final String label;
  final int value;
  final VoidCallback onTap;
  const _ZoomPresetButton({
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(48, 32),
        backgroundColor: AppTheme.neonBlue.withValues(alpha: 0.08),
        foregroundColor: AppTheme.neonBlue,
      ),
      onPressed: onTap,
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}
