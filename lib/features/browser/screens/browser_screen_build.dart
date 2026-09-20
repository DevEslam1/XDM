part of 'browser_screen.dart';

/// The main build() method for the whole browser screen.
mixin _BuildMixin on _BrowserScreenStateBase {
  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final downloadProvider = context.read<DownloadProvider>();
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
              floatingActionButton: ListenableBuilder(
                listenable: _sniffer,
                builder: (context, _) {
                  if (_tabs.isEmpty ||
                      _currentTabIndex < 0 ||
                      _currentTabIndex >= _tabs.length) {
                    return const SizedBox.shrink();
                  }
                  final activeTab = _tabs[_currentTabIndex];
                  final showFab = !activeTab.isHome &&
                      (_sniffer.detectedDownloadUrls[activeTab.id] != null ||
                          (_sniffer.detectedMediaSources[activeTab.id]
                                  ?.isNotEmpty ??
                              false) ||
                          _sniffer.detectedPlaylistUrls
                              .containsKey(activeTab.id) ||
                          (_sniffer.mediaScanFailed[activeTab.id] ?? false));
                  return showFab
                      ? _buildDownloadFab(context, settings)
                      : const SizedBox.shrink();
                },
              ),
              floatingActionButtonLocation:
                  FloatingActionButtonLocation.endFloat,
              body: Builder(
                builder: (context) {
                  final showTabSidebar =
                      (isDesktop(context) || isTabletLandscape(context)) &&
                          !isPhoneLandscape(context) &&
                          MediaQuery.of(context).size.height >= 600;
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
                            forceSolid: true,
                            sigmaX: 12,
                            sigmaY: 12,
                            child: Container(
                              padding: EdgeInsets.only(top: statusBarHeight),
                              height: kToolbarHeight + statusBarHeight,
                              decoration: BoxDecoration(
                                color: settings.isAmoledMode
                                    ? Colors.black
                                    : (settings.classicUi
                                        ? (isDark
                                            ? AppTheme.surface
                                            : AppTheme.lightSurface)
                                        : (isDark
                                                ? AppTheme.surface
                                                : AppTheme.lightSurface)
                                            .withValues(alpha: 0.88)),
                                border: Border(
                                  bottom: BorderSide(
                                    color: settings.isAmoledMode
                                        ? (isDark
                                            ? const Color(0xFF222222)
                                            : AppTheme.lightBorder)
                                        : (settings.classicUi
                                            ? (isDark
                                                ? AppTheme.border
                                                : AppTheme.lightBorder)
                                            : (isDark
                                                ? AppTheme.glassBorder
                                                : AppTheme.lightGlassBorder)),
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

                                      // Incognito Mode Visual Indicator
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
                                                size: 16,
                                                color: AppTheme.neonViolet),
                                          ),
                                        ),

                                      // Desktop Mode Indicator
                                      if (settings.desktopMode)
                                        const Tooltip(
                                          message: 'Desktop mode active',
                                          child: Padding(
                                            padding: EdgeInsets.symmetric(
                                                horizontal: 4.0),
                                            child: Icon(
                                                Icons.desktop_windows_rounded,
                                                size: 16,
                                                color: AppTheme.neonBlue),
                                          ),
                                        ),

                                      // Single unified SmartUrlBar capsule
                                      Expanded(
                                        child: SmartUrlBar(
                                          controller: _urlController,
                                          focusNode: _focusNode,
                                          isDark: isDark,
                                          isLoading: activeTab.isLoading,
                                          progress: activeTab.progress,
                                          onNavigate: _navigateToUrl,
                                          onReload: () {
                                            if (!activeTab.isHome) {
                                              _safeReloadTab(activeTab);
                                            }
                                          },
                                          onStopLoading: () {
                                            activeTab.controller
                                                ?.evaluateJavascript(
                                                    source: 'window.stop();');
                                            setState(() {
                                              activeTab.isLoading = false;
                                            });
                                          },
                                          onShieldPressed: () {
                                            if (activeTab.isHome) {
                                              return;
                                            }
                                            final blockedAds =
                                                _blockedAdsPerTab[
                                                        activeTab.id] ??
                                                    0;
                                            final blockedPopups =
                                                _blockedPopupsPerTab[
                                                        activeTab.id] ??
                                                    0;
                                            BrowserShieldSheet.show(
                                              context: context,
                                              currentUrl: activeTab.url,
                                              blockedAdsCount: blockedAds,
                                              blockedPopupsCount:
                                                  blockedPopups,
                                              onStartElementPicker: () =>
                                                  _startElementPicker(
                                                      activeTab),
                                              onReloadTab: () =>
                                                  _safeReloadTab(activeTab),
                                            );
                                          },
                                          isHttps: activeTab.url
                                              .toLowerCase()
                                              .startsWith('https://'),
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
                                              L10n.of(
                                                  context, 'browser_history_title'),
                                              'show_history',
                                              textClr),
                                          _menuItem(
                                              Icons.restore_rounded,
                                              L10n.of(context,
                                                  'browser_recently_closed'),
                                              'recently_closed',
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
                                          _menuItem(
                                            _effectiveForceDark(settings)
                                                ? Icons.dark_mode_rounded
                                                : Icons.light_mode_outlined,
                                            _effectiveForceDark(settings)
                                                ? 'Dark mode: ON'
                                                : 'Dark mode: OFF',
                                            'force_dark_mode',
                                            _effectiveForceDark(settings)
                                                ? (isDark
                                                    ? AppTheme.neonBlue
                                                    : AppTheme.lightNeonBlue)
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
                                          const PopupMenuDivider(),
                                          _menuItem(
                                            Icons.settings_outlined,
                                            'Browser settings',
                                            'browser_settings',
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
                                                return _BrowserTabView(
                                                  tab: tab,
                                                  state: this,
                                                  settings: settings,
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
                      if (showTabSidebar)
                        _buildVerticalTabSidebar(context, settings),
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
}
