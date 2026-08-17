part of 'browser_screen.dart';

/// Tab lifecycle: creation, switching, closing, restore, LRU order,
/// the tab strip UI, the vertical sidebar, and recently-closed tabs.
mixin _TabsMixin on _BrowserScreenStateBase {
  @override
  set _currentTabIndex(int value) {
    if (value >= 0 && value < _tabs.length) {
      final oldActiveTab =
          _tabs.length > _currentTabIndex && _currentTabIndex >= 0
              ? _tabs[_currentTabIndex]
              : null;
      if (!_isNavigatingTabHistory &&
          oldActiveTab != null &&
          oldActiveTab.id != _tabs[value].id) {
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

  @override
  void _ensureTabsExist() {
    if ((_tabs.isEmpty ||
            (_tabs.length == 1 &&
                _tabs.first.url.isEmpty &&
                !_tabs.first.isIncognito)) &&
        !_isRestoring) {
      _restoreTabs();
    }
  }

  @override
  void _debouncedSiteSettingsReload(BrowserTab tab) {
    _siteSettingsReloadTimer?.cancel();
    _siteSettingsReloadTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) {
        tab.controller?.reload();
      }
    });
  }

  @override
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
    const cap = 3;
    if (_lruTabIds.length > cap) {
      _lruTabIds.removeRange(cap, _lruTabIds.length);
    }
    _tabManager.evictInactiveTabs(keepRecentCount: cap);
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
    if (!_tabStripScrollController.hasClients ||
        _tabStripScrollController.positions.isEmpty) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_tabStripScrollController.hasClients ||
          _tabStripScrollController.positions.isEmpty) {
        return;
      }
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
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_isRestoring || (now - _lastRestoreAttemptTimeMs < 3000)) return;
    _lastRestoreAttemptTimeMs = now;
    _isRestoring = true;
    try {
      await _tabManager.restoreTabs();
    } catch (e, st) {
      Logger('browser_screen').warning('[Browser] restoreTabs error', e, st);
      if (_tabs.isEmpty) {
        _tabManager.addTab(_createNewTab(initialUrl: ''), switchToTab: true);
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
  void _checkOnboardingTooltip() async {
    final prefs = await SharedPreferences.getInstance();
    final hasSeen = prefs.getBool('has_seen_tab_tooltip') ?? false;
    if (!hasSeen && mounted) {
      setState(() => _showTabTooltip = true);
    }
  }

  @override
  void _dismissTabTooltip() async {
    if (_showTabTooltip) {
      setState(() => _showTabTooltip = false);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('has_seen_tab_tooltip', true);
    }
  }

  @override
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

  @override
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
    final adNotifier = _blockedAdsNotifiers.remove(tabId);
    _blockedAdsPerTab.remove(tabId);
    _blockedPopupsPerTab.remove(tabId);
    if (adNotifier != null) {
      try {
        adNotifier.dispose();
      } catch (e, st) {
        LoggingService.logger('BrowserScreenTabs')
            .warning('Operation failed', e, st);
      }
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
          } catch (e, st) {
            LoggingService.logger('BrowserScreenTabs')
                .warning('Operation failed', e, st);
          }
          try {
            tab.controller
                ?.evaluateJavascript(
                    source:
                        'window.localStorage.clear(); window.sessionStorage.clear();')
                .catchError((_) => null);
          } catch (e, st) {
            LoggingService.logger('BrowserScreenTabs')
                .warning('Operation failed', e, st);
          }
          if (tab.url.isNotEmpty && tab.url != 'about:blank') {
            try {
              CookieManager.instance().deleteCookies(url: WebUri(tab.url));
            } catch (e, st) {
              LoggingService.logger('BrowserScreenTabs')
                  .warning('Operation failed', e, st);
            }
          }
        });
      }
    }
  }

  /// UX 3.5: Pushes a recently-closed tab onto the bounded history list.
  @override
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
  @override
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
                                setSheetState(() {
                                  _recentlyClosedTabs.removeAt(index);
                                });
                                Navigator.pop(sheetContext);
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

  @override
  bool _switchToPreviousTab() {
    _tabIdHistory.removeWhere((id) => !_tabs.any((t) => t.id == id));
    if (_tabIdHistory.isNotEmpty) {
      final prevId = _tabIdHistory.removeLast();
      final idx = _tabs.indexWhere((t) => t.id == prevId);
      if (idx != -1) {
        _isNavigatingTabHistory = true;
        try {
          _switchTab(
              idx); // Fix: Delegate to _switchTab to handle all side effects
        } finally {
          _isNavigatingTabHistory = false;
        }
        return true;
      }
    }
    return false;
  }

  @override
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
                    // TabManager handles removal, index recalculation, disposal,
                    // and saving. Do NOT mutate _tabs here — it is unmodifiable.
                    _tabManager.closeTab(oldTab.id);
                    final tab = _createNewTab(isIncognito: isIncognito);
                    _tabManager.addTab(tab, switchToTab: true);
                    _urlController.text = '';
                    _showBarsNotifier.value = true;
                  });
                  setState(() {}); // Rebuild parent screen to sync tabs
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
                    // TabManager handles removal, index recalculation, disposal,
                    // and saving. Do NOT mutate _tabs here — it is unmodifiable.
                    _tabManager.closeTab(tab.id);
                  }
                  // Active tab is now at index 0 — open one new blank tab
                  _currentTabIndex = 0;
                  final newTab = _createNewTab(isIncognito: isIncognito);
                  _tabManager.addTab(newTab, switchToTab: true);
                  _urlController.text = '';
                  _showBarsNotifier.value = true;
                });
                setState(() {}); // Rebuild parent screen to sync tabs
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
          _urlController.text = '';
        });
        _saveTabs();
      });
      if (context.mounted) Navigator.pop(context);
    }
  }

  @override
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

  @override
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
                              Container(
                                width: 18,
                                height: 18,
                                alignment: Alignment.center,
                                child: tab.faviconUrl != null
                                    ? CachedNetworkImage(
                                        imageUrl: tab.faviconUrl!,
                                        width: 16,
                                        height: 16,
                                        fit: BoxFit.contain,
                                        placeholder: (context, url) =>
                                            const SizedBox(
                                                width: 16, height: 16),
                                        errorWidget: (context, url, error) =>
                                            Icon(
                                          Icons.public_rounded,
                                          size: 14,
                                          color: textClr,
                                        ),
                                        memCacheWidth: 32,
                                      )
                                    : Icon(
                                        Icons.public_rounded,
                                        size: 14,
                                        color: textClr,
                                      ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
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

  @override
  Widget _buildTabStrip(
    BuildContext context,
    SettingsProvider settings,
    bool isDark,
    Color textClr,
  ) {
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    return Container(
      height: 40,
      color: settings.isAmoledMode
          ? Colors.black
          : (isDark ? AppTheme.surface : AppTheme.lightSurface),
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
}
