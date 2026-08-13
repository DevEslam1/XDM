part of 'browser_screen.dart';

/// WebView wiring: controller setup, page start/stop/url events,
/// script injection, favicon fetch, autofill, and background suspension.
mixin _WebViewMixin on _BrowserScreenStateBase {
  @override
  Future<void> _safeReloadTab(BrowserTab tab) async {
    if (!mounted) return;

    if (tab.hasCrashed) {
      setState(() {
        tab.hasCrashed = false;
        tab.hasError = false;
        tab.isTimedOut = false;
        tab.isLoading = true;
        tab.controller = null;
      });
      return;
    }

    setState(() {
      tab.hasError = false;
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

  @override
  Future<void> _refreshTabForPull(BrowserTab tab) async {
    await _safeReloadTab(tab);

    // Keep the native indicator visible until loading completes or at most 3 seconds.
    int elapsed = 0;
    while (tab.isLoading && elapsed < 3000) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      elapsed += 200;
    }

    final pullToRefresh = tab.pullToRefreshController;
    if (pullToRefresh != null) {
      try {
        await pullToRefresh.endRefreshing();
      } catch (_) {
        // The controller may be disposed during tab eviction.
      }
    }
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
    try {
      final currentSettings = await tab.controller?.getSettings();
      if (currentSettings != null) {
        currentSettings.useShouldOverrideUrlLoading = true;
        currentSettings.useOnDownloadStart = true;
        currentSettings.userAgent = userAgent;
        currentSettings.supportZoom = isDesktop || settings.pinchToZoom;
        currentSettings.incognito = tab.isIncognito;
        currentSettings.contentBlockers =
            isAdBlock ? _adBlocker.contentBlockers : <ContentBlocker>[];
        currentSettings.javaScriptEnabled = true;
        currentSettings.domStorageEnabled = true;
        currentSettings.databaseEnabled = true;
        currentSettings.supportMultipleWindows = true;
        currentSettings.javaScriptCanOpenWindowsAutomatically = true;
        await tab.controller?.setSettings(settings: currentSettings);
      } else {
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
    } catch (e) {
      _log.warning('[Browser] Failed to apply site settings: $e');
    }
  }

  @override
  void _configureController(BrowserTab tab, InAppWebViewController controller) {
    tab.controller = controller;

    // Register JS handlers (channels)
    controller.addJavaScriptHandler(
      handlerName: _longPressChannel,
      callback: (args) {
        final msg = args.isNotEmpty ? args.first.toString() : '';
        _handleLongPressMessageForTab(tab, BrowserJsMessage(message: msg));
      },
    );
    controller.addJavaScriptHandler(
      handlerName: _popupsChannel,
      callback: (args) {
        final msg = args.isNotEmpty ? args.first.toString() : '';
        _handlePopupMessageForTab(tab, BrowserJsMessage(message: msg));
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
        _handlePickerMessageForTab(tab, BrowserJsMessage(message: msg));
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
        const sensitiveKeywords = [
          'password',
          'token',
          'secret',
          'card',
          'cvv',
          'pan',
          'ssn',
          'social_security',
          'credit',
          'debit',
          'iban',
          'swift',
          'routing',
        ];
        if (sensitiveKeywords.any((kw) => name.contains(kw))) {
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

  @override
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

  @override
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
      try {
        final currentSettings = await tab.controller?.getSettings();
        if (currentSettings != null) {
          currentSettings.userAgent =
              'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
          currentSettings.incognito = tab.isIncognito;
          await tab.controller?.setSettings(settings: currentSettings);
        }
      } catch (e, st) {
        _log.warning('[Browser] Failed to apply Google accounts UA: $e', e, st);
      }
      unawaited(_hideWebViewFingerprints(tab));
    } else {
      // Fix #20: Restore the correct UA when navigating away from Google login
      // pages. Without this, the Pixel 8 UA set for accounts.google.com
      // persisted permanently for all subsequent pages in the same tab.
      final settings = _settings;
      unawaited(_applyUserAgent(tab, settings));
    }

    if (mounted) {
      final downloadProvider = context.read<DownloadProvider>();
      setState(() {
        tab.isLoading = true;
        tab.progress = 0.0;
        tab.lastRenderedProgress = 0;
        tab.updateUrl(_cleanUrl(url));
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

  @override
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

    _navDebounce?.cancel();
    _navDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _updateNavState();
    });

    if (!_isYoutubeHost(tab.url)) {
      _scheduleMediaScan(tab);
    }
  }

  @override
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
        tab.updateUrl(cleanUrl);
        if (cleanUrl.isNotEmpty) {
          tab.isHome = false;
        }
        if (_currentTabIndex >= 0 &&
            _currentTabIndex < _tabs.length &&
            _tabs[_currentTabIndex].id == tab.id) {
          _urlController.text = tab.url;
        }
      });
      _saveTabs();
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
              _saveTabs();
            }
          });
        }
      });
    }
    _updateNavState();
    _delayed(const Duration(milliseconds: 500), _updateNavState);
  }

  Future<void> _injectTimerSpeedScript(BrowserTab tab) async {
    if (!mounted) return;
    await _scriptInjector.injectTimerSpeedScript(tab);
  }

  Future<void> _injectLongPressScriptToTab(BrowserTab tab) async {
    if (!mounted) return;
    await _scriptInjector.injectLongPressScriptToTab(tab);
  }

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

  @override
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
      // Cancel pending loading timeout to prevent setState on a suspended tab.
      _loadingTimeoutTimers[tab.id]?.cancel();
      _loadingTimeoutTimers.remove(tab.id);
      // Cancel pending media scan debounce.
      _mediaScanDebouncePerTab[tab.id]?.cancel();
      _mediaScanDebouncePerTab.remove(tab.id);
      tab.isSuspended = true;
      tab.isTimedOut = false;
      tab.isLoading = false;
      tab.controller = null;
      tab.pullToRefreshController = null;
    }
  }

  @override
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
    try {
      final req = await _faviconHttpClient.getUrl(Uri.parse(faviconUrl));
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
}
