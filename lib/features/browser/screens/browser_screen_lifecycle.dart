part of 'browser_screen.dart';

/// Widget/app lifecycle: init/dispose, inactivity timeout, settings
/// reloads, and app close/quit handling.
mixin _LifecycleMixin on _BrowserScreenStateBase {
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
            currentSettings.userAgent = _settings.desktopMode
                ? FingerprintManager.desktopUserAgent
                : _resolveUserAgent(
                    isIncognito: tab.isIncognito, settings: _settings);
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

  @override
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

  @override
  void dispose() {
    _disposeTimers();
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
        unawaited(_tabManager.saveTabsImmediately());
      } catch (e, st) {
        Logger('browser_screen')
            .warning('[browser_screen] operation failed', e, st);
      }
    }

    for (final tab in _tabs) {
      _cleanupTabState(tab.id);
    }

    final bool hasIncognito = _tabs.any((t) => t.isIncognito);
    if (hasIncognito) {
      try {
        unawaited(InAppWebViewController.clearAllCache());
        unawaited(CookieManager.instance().deleteAllCookies());
      } catch (_) {}
    }

    for (final tab in _tabs) {
      if (tab.isIncognito) {
        try {
          tab.controller
              ?.evaluateJavascript(
                  source:
                      'window.localStorage.clear(); window.sessionStorage.clear();')
              .catchError((_) => null);
        } catch (_) {/* ignore: clearing storage on close */}
      }
      try {
        tab.dispose();
      } catch (_) {/* ignore: disposing tab may already be disposed */}
    }

    _tabManager.clearAllTabs();
    _tabManager.dispose();
    _sniffer.dispose();
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
    _navStateDebounceTimer?.cancel();
    _interceptor.dispose();
    for (final timer in _mediaScanDebouncePerTab.values) {
      timer.cancel();
    }
    _mediaScanDebouncePerTab.clear();
    _downloadProvider?.removeListener(_onDownloadProviderChanged);

    _urlController.dispose();
    _findTextController.dispose();
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

  @override
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cachedSettings = Provider.of<SettingsProvider>(context);
    final settings = _cachedSettings!;
    final newProvider = Provider.of<DownloadProvider>(context);
    if (_downloadProvider != newProvider) {
      _downloadProvider?.removeListener(_onDownloadProviderChanged);
      _downloadProvider = newProvider;
      _downloadProvider?.addListener(_onDownloadProviderChanged);
    }

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

    if (_effectiveForceDark(settings) != _lastEffectiveForceDark) {
      _lastEffectiveForceDark = _effectiveForceDark(settings);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _applyForceDarkToAll();
      });
    }
  }

  @override
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

  @override
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
      final normalTabs = _tabs.where((t) => !t.isIncognito).toList();
      final activeTab =
          (_currentTabIndex >= 0 && _currentTabIndex < _tabs.length)
              ? _tabs[_currentTabIndex]
              : null;
      final String? activeTabId = (activeTab != null && !activeTab.isIncognito)
          ? activeTab.id
          : (normalTabs.isNotEmpty ? normalTabs.last.id : null);

      final persistable = <SavedBrowserTab>[];
      for (var i = 0; i < normalTabs.length; i++) {
        final t = normalTabs[i];
        persistable.add(
          SavedBrowserTab(
            id: t.id,
            url: t.url.isNotEmpty ? t.url : 'about:blank',
            title: t.title,
            isActive: t.id == activeTabId,
            position: i,
            createdAt: t.createdAtMs,
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
