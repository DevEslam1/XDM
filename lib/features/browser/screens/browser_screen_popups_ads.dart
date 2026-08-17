part of 'browser_screen.dart';

/// Ad/popup interception, long-press + element-picker message
/// handling, and blocked-count notifiers.
mixin _PopupsAdsMixin on _BrowserScreenStateBase {
  @override
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

  /// ValueNotifier for the currently-active tab's blocked-ad count.
  @override
  ValueNotifier<int> get _activeBlockedAdsNotifier {
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) {
      return ValueNotifier<int>(0);
    }
    final tabId = _tabs[_currentTabIndex].id;
    final count = _blockedAdsPerTab[tabId] ?? 0;
    final notifier = _notifierForTab(tabId);
    if (notifier.value != count) {
      notifier.value = count;
    }
    return notifier;
  }

  /// Blocked popups for the currently-active tab.
  // ignore: unused_element — tracked for future snackbar/badge display.
  int get _blockedPopupCount {
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return 0;
    return _blockedPopupsPerTab[_tabs[_currentTabIndex].id] ?? 0;
  }

  /// Fallback used by [onLongPressHitTestResult] when the OS hit test gives no
  /// URL. It resolves the element at the point stored by the injected
  /// long-press script (window.__xdmLastTouch) and returns {url, type}.
  @override
  String get _longPressTargetFallbackJs => _longPressTargetFallbackJsStatic;
  static const String _longPressTargetFallbackJsStatic = '''
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

  @override
  void _handleLongPressMessageForTab(
    BrowserTab tab,
    BrowserJsMessage message,
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
  @override
  (String, String)? _parseLongPressTarget(String? raw) {
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
    } catch (e, st) {
      LoggingService.logger('BrowserScreenPopupsAds')
          .warning('Operation failed', e, st);
    }
    return null;
  }

  @override
  void _handlePopupMessageForTab(
    BrowserTab parentTab,
    BrowserJsMessage message,
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
    final newTab = _createNewTab(
      initialUrl: url,
      isIncognito: parentTab.isIncognito,
      origin: TabOrigin.adOrPopup,
    );
    _redirectGuard.reset(newTab.id);
    _tabManager.addTab(newTab, switchToTab: false);
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
        final newTab = _createNewTab(
          initialUrl: finalUrl,
          isIncognito: parentTab.isIncognito,
          origin: TabOrigin.redirect,
        );
        _redirectGuard.reset(newTab.id);
        _tabManager.addTab(newTab, switchToTab: false);
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

  @override
  void _handlePickerMessageForTab(
    BrowserTab tab,
    BrowserJsMessage message,
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

  @override
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
    final newTab = _createNewTab(
      initialUrl: url,
      isIncognito: isIncognito,
      origin: origin,
    );
    _redirectGuard.reset(newTab.id);
    _tabManager.addTab(newTab, switchToTab: switchToTab);
  }

  @override
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

  @override
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

  @override
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

  @override
  void _onDashboardScroll() {
    if (!_dashboardScrollController.hasClients) return;
    final y = _dashboardScrollController.offset;
    _handleScroll(y);
  }

  @override
  void _handleScroll(double y) {
    if (!mounted) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastScrollTimeMs < 16) return;
    _lastScrollTimeMs = now;

    final downloadProvider = context.read<DownloadProvider>();

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
}
