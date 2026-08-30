part of 'browser_screen.dart';

/// Back/forward/url-bar navigation, the toolbar menu, find-in-page,
/// reader mode, force-dark, zoom, clear-browsing-data, translate, print.
mixin _NavigationMenuMixin on _BrowserScreenStateBase {
  @override
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
              activeTab.updateUrl(clean);
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
  @override
  Future<bool> _goBack() async {
    if (_tabs.isEmpty ||
        _currentTabIndex < 0 ||
        _currentTabIndex >= _tabs.length) {
      return false;
    }
    final activeTab = _tabs[_currentTabIndex];

    // (a) WebView can go back.
    final webCanGoBack = activeTab.canGoBack ||
        (await activeTab.controller?.canGoBack() ?? false);
    if (webCanGoBack && activeTab.controller != null) {
      _homeReturnUrl = null;
      final currentTabId = activeTab.id;
      _navigatingBackForwardTabIds[currentTabId] = true;
      unawaited(activeTab.controller?.goBack() ?? Future.value());
      Future.delayed(const Duration(seconds: 30), () {
        if (mounted) {
          _navigatingBackForwardTabIds[currentTabId] = false;
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

      final tabToDispose = activeTab;
      setState(() {
        _recordClosedTab(tabToDispose);
        // TabManager.closeTab() removes the tab from its internal list,
        // recalculates _currentIndex (LRU-aware), clears per-tab state, persists,
        // and disposes the tab post-frame. If this was the last tab it creates a
        // fresh blank tab. Do NOT mutate _tabs here — it is unmodifiable.
        _tabManager.closeTab(tabToDispose.id);
      });
      if (!_switchToPreviousTab()) {
        final nowActive = _tabs[_currentTabIndex];
        _urlController.text = nowActive.isHome ? '' : nowActive.url;
      } else {
        _saveTabs();
      }

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
            final restored = _createNewTab(
              initialUrl: closedUrl,
              isIncognito: closedIsIncognito,
              origin: closedOrigin,
            );
            _redirectGuard.reset(restored.id);
            _tabManager.addTab(restored, switchToTab: true);
            _urlController.text = closedUrl;
            _showBarsNotifier.value = true;
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

  @override
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

    final currentTabId = activeTab.id;
    _navigatingBackForwardTabIds[currentTabId] = true;
    unawaited(activeTab.controller?.goForward() ?? Future.value());
    Future.delayed(const Duration(seconds: 30), () {
      if (mounted) {
        _navigatingBackForwardTabIds[currentTabId] = false;
      }
    });
    _updateNavState();
  }

  @override
  void _navigateToUrl(String input) {
    if (_tabs.isNotEmpty &&
        _currentTabIndex >= 0 &&
        _currentTabIndex < _tabs.length) {
      _navigatingBackForwardTabIds[_tabs[_currentTabIndex].id] = false;
    }
    var url = input.trim();
    if (url.isEmpty) return;

    final settings = _settings;
    final searchPrefix = SearchEngineConfig.prefixFor(settings.searchEngine);

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
      activeTab.updateUrl(targetUrl);
      _urlController.text = targetUrl;
      activeTab.hasCrashed = false;
      activeTab.hasError = false;
      activeTab.isTimedOut = false;
      activeTab.isLoading = true;
    });

    if (activeTab.controller != null) {
      activeTab.controller?.loadUrl(
        urlRequest: URLRequest(url: WebUri(targetUrl)),
      );
    }
    _delayed(const Duration(milliseconds: 300), _updateNavState);
  }

  @override
  String _cleanUrl(String url) {
    if (url.isEmpty || url == 'about:blank') return '';
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return url;
    // Preserve trailing slash — stripping it can change semantics for REST
    // endpoints where `/foo` and `/foo/` are distinct resources.
    return uri.toString();
  }

  @override
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
      case 'force_dark_mode':
        await settings.setForceDarkMode(!settings.forceDarkMode);
        if (mounted) {
          final effectiveDark = _effectiveForceDark(settings);
          ThemedSnackbar.show(
            context,
            message: effectiveDark
                ? 'Dark mode enabled — reloading page'
                : 'Dark mode disabled — reloading page',
            color: settings.isDarkMode
                ? AppTheme.neonBlue
                : AppTheme.lightNeonBlue,
            icon: Icons.dark_mode_rounded,
            isDarkMode: settings.isDarkMode,
          );
          _applyForceDarkToAll();
          if (!activeTab.isHome) {
            await _safeReloadTab(activeTab);
          }
        }
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
          // Apply UA to the active tab, and reload it if it's not the home page.
          // Background tabs will reload and get the updated desktop mode setting when resumed.
          await _applyUserAgent(activeTab, settings);
          try {
            final currentSettings = await activeTab.controller?.getSettings();
            if (currentSettings != null) {
              currentSettings.supportZoom =
                  settings.desktopMode || settings.pinchToZoom;
              currentSettings.incognito = activeTab.isIncognito;
              await activeTab.controller
                  ?.setSettings(settings: currentSettings);
            }
          } catch (e, st) {
            Logger('browser_screen')
                .warning('[browser_screen] operation failed', e, st);
          }
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
  @override
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

  @override
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

  @override
  void _findNext(bool forward) {
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
    final controller = _tabs[_currentTabIndex].findInteractionController;
    if (controller == null) return;
    if (_findMatchCount <= 0) return;
    try {
      controller.findNext(forward: forward);
    } catch (_) {}
  }

  @override
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
    final effectiveDark = _effectiveForceDark(settings);
    _applyForceDarkToAll();
    if (mounted) {
      ThemedSnackbar.show(
        context,
        message: effectiveDark
            ? 'Force dark enabled — reloading page'
            : 'Force dark disabled — reloading page',
        color: settings.isDarkMode ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
        icon:
            effectiveDark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
        isDarkMode: settings.isDarkMode,
      );
      if (!activeTab.isHome) {
        await _safeReloadTab(activeTab);
      }
    }
  }

  @override
  Future<void> _applyForceDarkToAll() async {
    final settings = _settings;
    final forceDark = _effectiveForceDark(settings);
    for (final tab in _tabs) {
      final controller = tab.controller;
      if (controller == null) continue;
      if (Platform.isAndroid) {
        try {
          final currentSettings = await controller.getSettings();
          if (currentSettings != null) {
            currentSettings.forceDark =
                forceDark ? ForceDark.ON : ForceDark.OFF;
            currentSettings.incognito = tab.isIncognito;
            await controller.setSettings(settings: currentSettings);
          }
        } catch (_) {}
      }
      try {
        final css = forceDark ? ScriptInjector.buildForceDarkCss() : '';
        controller.evaluateJavascript(source: '''
          (function() {
            var s = document.getElementById('xdm-force-dark');
            if ($forceDark) {
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

  @override
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
            // Delete the physical file from disk if it exists.
            if (task.localFilePath.isNotEmpty) {
              try {
                final file = File(task.localFilePath);
                if (await file.exists()) {
                  await file.delete();
                }
              } catch (_) {
                // File may be locked or already deleted — safe to ignore.
              }
            }
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
    final siteSettings = await _siteSettingsStore.getForHost(host);
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
                    },
                    onChangeEnd: (v) async {
                      try {
                        final currentSettings =
                            await activeTab.controller?.getSettings();
                        if (currentSettings != null) {
                          currentSettings.textZoom = v.round();
                          await activeTab.controller
                              ?.setSettings(settings: currentSettings);
                        }
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
      await _siteSettingsStore.updateForHost(
        host,
        siteSettings.copyWith(zoomLevel: value),
      );
      try {
        final currentSettings = await activeTab.controller?.getSettings();
        if (currentSettings != null) {
          currentSettings.textZoom = value.round();
          await activeTab.controller?.setSettings(settings: currentSettings);
        }
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
  @override
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
    final isIncog = _tabs[_currentTabIndex].isIncognito;
    _openInNewTab('', isIncognito: isIncog, switchToTab: true);
    _focusUrlBar();
  }

  void _closeActiveTabViaShortcut() {
    if (_tabs.length <= 1) {
      _goBack();
      return;
    }
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
    final tab = _tabs[_currentTabIndex];
    setState(() {
      _recordClosedTab(tab);
      // TabManager handles removal, index recalculation, disposal, and saving.
      _tabManager.closeTab(tab.id);
    });
    final active = _tabs[_currentTabIndex];
    _urlController.text = active.isHome ? '' : active.url;
  }

  /// UX 3.10: Launches app-linkable URLs in an external app when enabled.
  @override
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

  @override
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
}
