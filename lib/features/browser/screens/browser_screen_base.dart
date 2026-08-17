part of 'browser_screen.dart';

/// Shared fields, simple getters, and small service instances used across
/// every mixin that makes up [_BrowserScreenState]. Kept here so all the
/// split-out mixins (tabs, webview, navigation, etc.) can see the same
/// private state without needing cross-file imports (Dart privacy is
/// per-library, so this only works because everything below is a `part`
/// of the same library as browser_screen.dart).
abstract class _BrowserScreenStateBase extends State<BrowserScreen>
    with HapticHelper, WidgetsBindingObserver, SingleTickerProviderStateMixin {
  Timer? _navStateDebounceTimer;

  SettingsProvider? _cachedSettings;

  SettingsProvider get _settings =>
      _cachedSettings ?? context.read<SettingsProvider>();

  final List<Map<String, String>> _userCustomShortcuts = [];

  final Logger _log = Logger('BrowserScreen');

  final List<String> _tabIdHistory = [];

  final Set<String> _recentDownloadUrls = {};
  final Map<String, Timer> _downloadUrlTimers = {};

  HttpClient? _sharedHttpClient;

  HttpClient get _faviconHttpClient {
    return _sharedHttpClient ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
  }

  void _markUrlAsDownloaded(String url) {
    _recentDownloadUrls.add(url);
    _downloadUrlTimers[url]?.cancel();
    _downloadUrlTimers[url] = Timer(const Duration(seconds: 4), () {
      _recentDownloadUrls.remove(url);
      _downloadUrlTimers.remove(url);
    });
  }

  void _disposeTimers() {
    for (final t in _downloadUrlTimers.values) {
      t.cancel();
    }
    _downloadUrlTimers.clear();
    _sharedHttpClient?.close(force: true);
    _sharedHttpClient = null;
  }

  List<BrowserTab> get _tabs => _tabManager.tabs;

  int get _currentTabIndex => _tabManager.currentIndex;
  set _currentTabIndex(int idx) {
    if (_tabs.isNotEmpty && idx >= 0 && idx < _tabs.length) {
      _tabManager.switchToTab(idx);
    }
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

  // FIX-0.2 / FIX-0.3: Per-tab ValueNotifier for blocked ads (no shared _zeroNotifier)
  final Map<String, ValueNotifier<int>> _blockedAdsNotifiers = {};

  final Map<String, int> _blockedAdsPerTab = {};

  final Map<String, int> _blockedPopupsPerTab = {};

  ValueNotifier<int> _notifierForTab(String tabId) {
    return _blockedAdsNotifiers.putIfAbsent(
      tabId,
      () => ValueNotifier<int>(_blockedAdsPerTab[tabId] ?? 0),
    );
  }

  // FIX P1-3: Cap _blockedAdsNotifiers (50), _blockedAdsPerTab (200), and _blockedPopupsPerTab (200)
  void _evictTrackingMapsIfNeeded() {
    if (_blockedAdsNotifiers.length > 50) {
      final activeTabIds = _tabs.map((t) => t.id).toSet();
      final toRemove = _blockedAdsNotifiers.keys
          .where((k) => !activeTabIds.contains(k))
          .take(_blockedAdsNotifiers.length - 50)
          .toList();
      for (final k in toRemove) {
        final n = _blockedAdsNotifiers.remove(k);
        n?.dispose();
      }
    }
    if (_blockedAdsPerTab.length > 200) {
      final activeTabIds = _tabs.map((t) => t.id).toSet();
      final toRemove = _blockedAdsPerTab.keys
          .where((k) => !activeTabIds.contains(k))
          .take(_blockedAdsPerTab.length - 200)
          .toList();
      for (final k in toRemove) {
        _blockedAdsPerTab.remove(k);
        final n = _blockedAdsNotifiers.remove(k);
        n?.dispose();
      }
    }
    if (_blockedPopupsPerTab.length > 200) {
      final activeTabIds = _tabs.map((t) => t.id).toSet();
      final toRemove = _blockedPopupsPerTab.keys
          .where((k) => !activeTabIds.contains(k))
          .take(_blockedPopupsPerTab.length - 200)
          .toList();
      for (final k in toRemove) {
        _blockedPopupsPerTab.remove(k);
      }
    }
  }

  // E13: Tab Suspension/Resume Visual Feedback
  String? _restoringTabId;

  Map<String, String> get _detectedDownloadUrls =>
      _sniffer.detectedDownloadUrls;

  Map<String, List<Map<String, dynamic>>> get _detectedMediaSources =>
      _sniffer.detectedMediaSources;

  Map<String, int> get _detectedPlaylistUrls => _sniffer.detectedPlaylistUrls;

  Map<String, DateTime> get _ytDetectionFailed => _sniffer.ytDetectionFailed;

  Map<String, bool> get _mediaScanFailed => _sniffer.mediaScanFailed;

  Map<String, DateTime> get _lastYoutubeAuthTimes =>
      _sniffer.lastYoutubeAuthTimes;

  Duration get _youtubeAuthCooldown => const Duration(seconds: 30);

  Map<String, Timer> get _mediaScanTimers => _sniffer.mediaScanTimers;

  bool _quitPersisted = false;

  bool _isRestoring = false;
  int _lastRestoreAttemptTimeMs = 0;
  bool _isNavigatingTabHistory = false;

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

  DownloadProvider? _downloadProvider;

  late final BrowserHistoryManager _historyManager = BrowserHistoryManager(
    resolveDatabase: () => context.read<DatabaseService>(),
    isIncognito: () => _settings.incognitoEnabled,
    cleanUrl: _cleanUrl,
    isActive: () => mounted,
  );

  late final DownloadInterceptor _interceptor = DownloadInterceptor(
    resolveDownloadProvider: () => context.read<DownloadProvider>(),
    resolveActiveTab: () =>
        (_currentTabIndex >= 0 && _currentTabIndex < _tabs.length)
            ? _tabs[_currentTabIndex]
            : null,
  );

  final ScrollController _dashboardScrollController = ScrollController();

  List<Timer> get _pendingTimers => _tabManager.pendingTimers;

  Timer? _navDebounce;

  String get _snifferPrefKey => 'browserSnifferEnabled';

  bool _isSnifferEnabled = true;

  bool _lastZoomEnabled = false;

  bool _lastEffectiveForceDark = false;

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

  String? _readerTabId;
  // Bug #16 fix: track the specific tab where reader mode was activated
  bool _readerControlsVisible = false;

  double _readerFontSize = 16.0;

  String _readerTheme = 'light';

  String _readerFontFamily = 'serif';

  // UX 3.5: Recently closed tabs
  int get _maxRecentClosedTabs => 10;

  final List<_ClosedTab> _recentlyClosedTabs = [];

  // UX 3.12: Full-page screenshot guard
  bool _capturingPage = false;

  // UX 3.15: Incognito banner (dismissed per session)
  bool _incognitoBannerDismissed = false;

  // UX 3.19: Form autofill JS channel
  String get _autofillChannel => 'XDM_Autofill';

  // UX 3.20: Keyboard shortcuts only on desktop-class platforms
  bool get _shortcutsActive =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  String get _longPressChannel => 'XDM_LongPress';

  String get _popupsChannel => 'XDM_Popups';

  String get _pickerChannel => 'XdmPickerChannel';

  // ─────────────────────────────────────────────────────────────
  // Cross-mixin method contracts
  // ─────────────────────────────────────────────────────────────
  BrowserTab _createNewTab({
    String initialUrl = '',
    bool isIncognito = false,
    String? id,
    bool autoLoad = true,
    TabOrigin origin = TabOrigin.userDirect,
  });

  void _cleanupTabState(String tabId);

  void _openInNewTab(
    String url, {
    bool isIncognito = false,
    bool switchToTab = false,
    TabOrigin origin = TabOrigin.userDirect,
  });

  Future<void> _safeReloadTab(BrowserTab tab);

  Future<void> _startElementPicker(BrowserTab activeTab);

  void _resumeTab(BrowserTab tab);

  void _suspendBackgroundTabs();

  Future<void> _refreshTabForPull(BrowserTab tab);

  void _showInterceptionSheet(BuildContext context, String downloadUrl);

  void _showLongPressSheet(
    BuildContext context,
    String url,
    String type, {
    String text = '',
    String? tabId,
  });

  void _onPageStart(BrowserTab tab, String url);

  void _onPageStop(BrowserTab tab, String url);

  void _onUrlChange(BrowserTab tab, String url);

  void _configureController(BrowserTab tab, InAppWebViewController controller);

  Future<void> _showAddShortcutDialog();

  Future<void> _loadCustomShortcuts();

  Future<void> _removeCustomShortcut(Map<String, String> shortcut);

  void _showRecentlyClosedSheet();

  bool _switchToPreviousTab();

  void _switchToTabRelative(int offset);

  void _showTabSwitcher(BuildContext context);

  void _openFindPanel();

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event);

  Widget _buildDownloadFab(BuildContext context, SettingsProvider settings);

  Future<void> _handleCloseOrQuit();

  ValueNotifier<int> get _activeBlockedAdsNotifier;

  void _navigateToUrl(String input);

  Future<void> _handleYouTubeGrab(BrowserTab tab, SettingsProvider settings);

  Future<void> _handleMenuAction(String value);

  void _updateLruOrder();

  Widget _buildHomeDashboard(
    BuildContext context,
    SettingsProvider settings, {
    ScrollController? scrollController,
  });

  String get _longPressTargetFallbackJs;

  (String, String)? _parseLongPressTarget(String? raw);

  void _handleScroll(double y);

  Future<bool> _maybeOpenInApp(String url);

  void _suggestDownload(String url, PageClassification classification);

  void _showJsCssInjectorDialog();

  Future<void> _savePageOffline(BrowserTab tab);

  Future<void> _confirmQuitBrowser();

  void _recordClosedTab(BrowserTab tab);

  Future<void> _setSnifferEnabled(bool value);

  void _checkOnboardingTooltip();

  void _onDashboardScroll();

  void _onDownloadProviderChanged();

  void _ensureTabsExist();

  Future<void> _applyForceDarkToAll();

  void _openBookmarks();

  void _openHistory();

  void _animateFlyingStar();

  Future<void> _updateNavState();

  void _resetInactivityTimer();

  void _dismissTabTooltip();

  void _handleLongPressMessageForTab(BrowserTab tab, BrowserJsMessage message);

  void _handlePopupMessageForTab(BrowserTab tab, BrowserJsMessage message);

  void _handlePickerMessageForTab(BrowserTab tab, BrowserJsMessage message);

  void _notifyScriptsInjected();

  Future<void> _injectCustomJsCss(BrowserTab tab);

  void _debouncedSiteSettingsReload(BrowserTab tab);

  void _showSiteSettingsSheet(BrowserTab tab);

  String _cleanUrl(String url);

  Future<void> _clearBrowsingData({
    required bool cache,
    required bool cookies,
    required bool history,
    required bool formData,
    required bool downloads,
  });

  Future<bool> _goBack();

  Future<void> _goForward();

  void _updateFindQuery(BrowserTab tab, String query);

  void _findNext(bool forward);

  void _closeFindPanel();

  Future<void> _updateReaderConfig();

  void _showAdWarning(BuildContext context, String url);

  void _openInBackgroundTab(String url, {bool isIncognito = false});

  Widget _buildVerticalTabSidebar(
      BuildContext context, SettingsProvider settings);

  Widget _buildTabStrip(
    BuildContext context,
    SettingsProvider settings,
    bool isDark,
    Color textClr,
  );

  Future<void> _startDirectDownload(
    String url, {
    String? suggestedName,
    String? type,
  });

  // ─────────────────────────────────────────────────────────────
  // Tab persistence
  // ─────────────────────────────────────────────────────────────
  Future<void> _saveTabs() => _tabManager.saveTabs();

  final List<String> _lruTabIds = [];

  final Map<String, Timer> _loadingTimeoutTimers = {};

  Timer? _siteSettingsReloadTimer;

  final _inactivityWatchdog = InactivityWatchdog();

  void _pauseTabMedia(BrowserTab tab) => _inactivityWatchdog.pauseTabMedia(tab);

  bool _showTabTooltip = false;

  DateTime? _lastInactivityReset;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _inactivityWatchdog.handleAppLifecycleState(
      state: state,
      tabs: _tabs,
      resetInactivityTimer: _resetInactivityTimer,
    );
  }

  void _recordHistory(String url, {String? title}) =>
      _historyManager.recordHistory(url, title: title);

  bool _isYoutubeHost(String url) => MediaSniffer.isYoutubeHost(url);

  final Map<String, Timer> _mediaScanDebouncePerTab = {};

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

  Future<void> _hideWebViewFingerprints(BrowserTab tab) {
    final settings = _settings;
    return _fingerprintManager.hideWebViewFingerprints(tab, settings);
  }

  void _injectDesktopModeScript(BrowserTab tab, SettingsProvider settings) =>
      _scriptInjector.injectDesktopModeScript(tab, settings);

  /// Silently removes the oldest [TabOrigin.adOrPopup] / [TabOrigin.redirect]
  /// background tabs when their count is at or above the manager's cap,
  /// ensuring ad popups cannot fill all available tab slots.
  ///
  /// [TabOrigin.userDirect] tabs are NEVER touched by this method.
  ///
  /// Call this inside or just before the [setState] that adds a new
  /// ad/popup/redirect tab.
  void _evictStaleAdTabs() {
    _tabManager.evictStaleAdTabs();
  }

  int _lastScrollTimeMs = 0;

  bool? _lastNavbarVisible;

  void _delayed(Duration duration, VoidCallback callback) =>
      _tabManager.delayed(duration, callback);

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

  bool _effectiveForceDark(SettingsProvider settings) {
    // Dedicated switch controls whether web content is forced to dark mode.
    return settings.forceDarkMode;
  }

  /// Handles HTTP Basic / Digest authentication challenges (401 Unauthorized).
  Future<HttpAuthResponse?> _handleHttpAuthRequest(
      URLAuthenticationChallenge challenge) async {
    final host = challenge.protectionSpace.host;
    final realm = challenge.protectionSpace.realm ?? '';
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();
    final isDark = _settings.isDarkMode;
    final isRtl = L10n.isRtl(context);

    if (!mounted) return null;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.lock_outline_rounded,
                color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isRtl ? 'تسجيل الدخول المطلوب' : 'Authentication Required',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              realm.isNotEmpty
                  ? '$host ($realm)'
                  : (isRtl
                      ? 'الموقع $host يتطلب اسم مستخدم وكلمة مرور'
                      : 'The site at $host requires a username and password.'),
              style: TextStyle(
                fontSize: 12,
                color: isDark
                    ? AppTheme.textSecondary
                    : AppTheme.lightTextSecondary,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: usernameController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: isRtl ? 'اسم المستخدم' : 'Username',
                prefixIcon: const Icon(Icons.person_outline, size: 18),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: isRtl ? 'كلمة المرور' : 'Password',
                prefixIcon: const Icon(Icons.password_outlined, size: 18),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text(L10n.of(dialogCtx, 'cancel_btn')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(isRtl ? 'تسجيل الدخول' : 'Sign In'),
          ),
        ],
      ),
    );

    if (result == true) {
      return HttpAuthResponse(
        action: HttpAuthResponseAction.PROCEED,
        username: usernameController.text.trim(),
        password: passwordController.text,
      );
    }
    return HttpAuthResponse(action: HttpAuthResponseAction.CANCEL);
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

  void _focusUrlBar() {
    _focusNode.requestFocus();
  }

  Set<String> get _appLinkHosts => const {
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

  Future<void> _scanPageMedia(BrowserTab tab) =>
      _sniffer.scanPageMedia(tab, tabs: _tabs);

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

  late final MediaSniffer _sniffer = MediaSniffer(
    isActive: () => mounted,
    containsTab: (tab) => _tabs.contains(tab),
    isSnifferEnabled: () => _isSnifferEnabled,
  );
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
