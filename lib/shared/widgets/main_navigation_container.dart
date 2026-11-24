import 'dart:async';

import 'package:dmx/core/services/logging_service.dart';
import 'package:dmx/core/utils/localization.dart';
import 'package:dmx/features/add_download/widgets/add_download_dialog.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:dmx/shared/widgets/dmx_app_icon.dart';
import 'package:dmx/shared/widgets/dmx_backdrop_filter.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/services/app_lock_service.dart';
import '../../core/services/background_service.dart';
import '../../core/services/clipboard_service.dart';
import '../../core/services/power_monitor.dart';
import '../../core/services/share_service.dart';
import '../../core/services/share_url_handler.dart';
import '../../core/services/single_instance_service.dart';
import '../../core/services/torrent_resume_store.dart';
import '../../core/services/torrent_service.dart';
import '../../core/services/update_service.dart';
import '../../core/utils/responsive.dart';
import '../../features/browser/screens/browser_screen.dart';
import '../../features/downloads/widgets/filter_chips_bar.dart';
import '../../features/home/screens/home_screen.dart';
import '../../features/settings/screens/settings_screen.dart';
import '../../features/settings/widgets/app_lock_screen.dart';
import '../../features/settings/widgets/update_dialogs.dart';
import '../design/dmx_tokens.dart';
import 'themed_snackbar.dart';

class MainNavigationContainer extends StatefulWidget {
  final String? initialUrl;
  final bool isShareLaunch;
  const MainNavigationContainer({
    super.key,
    this.initialUrl,
    this.isShareLaunch = false,
  });

  @override
  State<MainNavigationContainer> createState() =>
      _MainNavigationContainerState();
}

class _MainNavigationContainerState extends State<MainNavigationContainer>
    with WidgetsBindingObserver {
  String? _lastClipboardUrl;
  bool _lockScreenVisible = false;
  DateTime _lastClipboardCheckTime = DateTime.fromMillisecondsSinceEpoch(
    0,
    isUtc: true,
  );

  Widget _buildScreen(int index) {
    switch (index) {
      case 0:
        return const HomeScreen();
      case 1:
        return const BrowserScreen();
      case 2:
        return const SettingsScreen();
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ShareService().init(
      onUrlReceived: (url, {bool isInitial = false}) =>
          _onUrlReceived(url, isShareLaunch: widget.isShareLaunch || isInitial),
    );
    SingleInstanceService().setListener(
      (url) => _onUrlReceived(url, isShareLaunch: false),
    );
    if (widget.initialUrl != null && widget.initialUrl!.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _onUrlReceived(
            widget.initialUrl!,
            isShareLaunch: widget.isShareLaunch,
          );
        }
      });
    }
    _checkClipboard();
    BackgroundService.onIosBackgroundUnavailable = () {
      if (!mounted) return;
      final isDark = Theme.of(context).brightness == Brightness.dark;
      ThemedSnackbar.show(
        context,
        message:
            'iOS background execution is limited. Keep app open while downloading.',
        color: AppTheme.neonAmber,
        icon: Icons.info_outline,
        isDarkMode: isDark,
      );
    };
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _showAppLockIfNeeded();
      if (mounted) _checkAppUpdates();
    });
  }

  Future<void> _checkAppUpdates() async {
    try {
      final update = await UpdateService().checkForUpdate();
      if (update != null && mounted) {
        final provider = context.read<DownloadProvider>();
        final settings = context.read<SettingsProvider>();
        if (update.mandatory) {
          showMandatoryUpdateDialog(context, update, provider);
        } else {
          final isDark = settings.isDarkMode;
          ThemedSnackbar.show(
            context,
            message:
                '${L10n.of(context, 'new_update_available')}${update.latestVersion}',
            color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
            icon: Icons.system_update_rounded,
            isDarkMode: isDark,
            actionLabel: L10n.of(context, 'download_action'),
            onAction: () =>
                showUpdateInfoDialog(context, update, provider, settings),
          );
        }
      }
    } catch (e, st) {
      LoggingService.logger('MainNavigationContainer')
          .warning('Update check error', e, st);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ShareService().dispose();
    SingleInstanceService().clearListener();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkClipboard();
      _showAppLockIfNeeded();
    }
    if (state == AppLifecycleState.paused) {
      _saveTorrentResumeStateWithTimeout();
    }
  }

  Future<void> _showAppLockIfNeeded() async {
    if (_lockScreenVisible || !mounted) return;
    if (!await AppLockService.isLockEnabled() || !mounted) return;
    _lockScreenVisible = true;
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const AppLockScreen(),
      ),
    );
    _lockScreenVisible = false;
  }

  Future<void> _saveTorrentResumeStateWithTimeout() async {
    try {
      await Future.any([
        TorrentResumeStore.saveAll(
          TorrentService.activeTorrentIds,
          TorrentService.resumeBlobFor,
        ),
        Future.delayed(const Duration(seconds: 3)),
      ]);
    } catch (e) {
      LoggingService.logger('MainNavigationContainer').warning(
        '[MainNavigationContainer] saving torrent resume state failed',
        e,
      );
    }
  }

  void _onUrlReceived(String url, {bool isShareLaunch = false}) {
    if (!mounted) return;
    ShareUrlHandler.handle(context, url, isShareLaunch: isShareLaunch);
  }

  bool _isShowingClipboardDialog = false;
  bool _isCheckingClipboard = false;

  Future<void> _checkClipboard() async {
    if (_isCheckingClipboard || _isShowingClipboardDialog) return;
    _isCheckingClipboard = true;
    try {
      final now = DateTime.now();
      if (now.difference(_lastClipboardCheckTime).inSeconds < 2) return;
      _lastClipboardCheckTime = now;
      final url = await ClipboardService().checkClipboardForUrl();
      if (url != null && mounted && url != _lastClipboardUrl) {
        _isShowingClipboardDialog = true;
        _lastClipboardUrl = url;
        _showClipboardSnackbar(url);
        Future.delayed(const Duration(seconds: 3), () {
          _isShowingClipboardDialog = false;
        });
      }
    } finally {
      _isCheckingClipboard = false;
    }
  }

  void _showClipboardSnackbar(String url) {
    final settings = context.read<SettingsProvider>();
    final isDark = settings.isDarkMode;
    if (settings.vibration) HapticFeedback.mediumImpact();
    String preview = url;
    try {
      final uri = Uri.parse(url);
      if (uri.userInfo.isNotEmpty) {
        preview = uri.replace(userInfo: '').toString();
      }
    } catch (_) {}
    final safePreview =
        preview.length > 40 ? '${preview.substring(0, 40)}…' : preview;
    ThemedSnackbar.show(
      context,
      message: L10n.of(context, 'clipboard_link_detected'),
      subtitle: safePreview,
      color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
      icon: Icons.content_paste_go_rounded,
      isDarkMode: isDark,
      actionLabel: L10n.of(context, 'download_action'),
      onAction: () {
        // Open the Add Download dialog instead of the browser so the user
        // can start the download directly from the clipboard prompt.
        AddDownloadDialog.show(context, prefilledUrl: url);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // PERF: Use Selector so this shell only rebuilds when the navigation
    // state actually changes — not on every download-progress tick.
    return Selector<SettingsProvider,
        ({bool isDark, bool isAmoled, bool classicUi, bool vibration})>(
      selector: (_, s) => (
        isDark: s.isDarkMode,
        isAmoled: s.isAmoledMode,
        classicUi: s.classicUi,
        vibration: s.vibration,
      ),
      builder: (context, settingsTuple, _) {
        final isDark = settingsTuple.isDark;
        final isRtl = L10n.isRtl(context);
        final screenType = getScreenType(context);
        final showSideNav = shouldShowSideNavigation(context);

        return Selector<DownloadProvider,
            ({int activeTabIndex, bool isNavbarVisible, bool isSelectionMode})>(
          selector: (_, p) => (
            activeTabIndex: p.activeTabIndex,
            isNavbarVisible: p.isNavbarVisible,
            isSelectionMode: p.isSelectionMode,
          ),
          builder: (context, navState, _) {
            final currentIndex = navState.activeTabIndex;
            final isBarShowing = navState.isNavbarVisible &&
                currentIndex != 1 &&
                !navState.isSelectionMode;

            final bodyWithShortcuts = CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.keyN, control: true):
                    () {
                  AddDownloadDialog.show(context);
                },
                const SingleActivator(LogicalKeyboardKey.digit1, control: true):
                    () {
                  context.read<DownloadProvider>().setActiveTabIndex(0);
                },
                const SingleActivator(LogicalKeyboardKey.digit2, control: true):
                    () {
                  context.read<DownloadProvider>().setActiveTabIndex(1);
                },
                const SingleActivator(LogicalKeyboardKey.digit3, control: true):
                    () {
                  context.read<DownloadProvider>().setActiveTabIndex(2);
                },
              },
              child: Directionality(
                textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
                child: _FadeIndexedStack(
                  index: currentIndex,
                  itemCount: 3,
                  itemBuilder: (ctx, i) => _buildScreen(i),
                ),
              ),
            );

            return PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, result) async {
                if (didPop) return;
                if (currentIndex != 0) {
                  // Only switch back to main home tab if we're not on the Browser tab (which has its own inner back navigation pop scope)
                  if (currentIndex != 1) {
                    Provider.of<DownloadProvider>(context, listen: false)
                        .setActiveTabIndex(0);
                  }
                }
              },
              child: Scaffold(
                backgroundColor: AppTheme.getBackground(
                  isDark,
                  isAmoled: settingsTuple.isAmoled,
                ),
                extendBody: true,
                body: Stack(
                  children: [
                    (showSideNav && currentIndex != 1)
                        ? Row(
                            children: [
                              RepaintBoundary(
                                child: _NavigationRailWidget(
                                  settingsTuple: settingsTuple,
                                  isDark: isDark,
                                  isRtl: isRtl,
                                  currentIndex: currentIndex,
                                ),
                              ),
                              Expanded(child: bodyWithShortcuts),
                            ],
                          )
                        : bodyWithShortcuts,
                    if (!showSideNav)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: RepaintBoundary(
                          child: IgnorePointer(
                            ignoring: !isBarShowing,
                            child: screenType == ScreenType.phone
                                ? _PhoneBottomNavBar(
                                    settingsTuple: settingsTuple,
                                    isDark: isDark,
                                    isRtl: isRtl,
                                    navState: navState,
                                  )
                                : _TabletFloatingNavBar(
                                    settingsTuple: settingsTuple,
                                    isDark: isDark,
                                    isRtl: isRtl,
                                    navState: navState,
                                  ),
                          ),
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
}

// Smooth fade when switching tabs with lazy item construction
class _FadeIndexedStack extends StatefulWidget {
  final int index;
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;

  const _FadeIndexedStack({
    required this.index,
    required this.itemCount,
    required this.itemBuilder,
  });

  @override
  State<_FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<_FadeIndexedStack>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  final Set<int> _activatedIndices = {};
  final Map<int, Widget> _cachedWidgets = {};

  @override
  void initState() {
    super.initState();
    _activatedIndices.add(widget.index);
    _c = AnimationController(vsync: this, duration: AppTheme.motionBase)
      ..forward();
  }

  @override
  void didUpdateWidget(_FadeIndexedStack old) {
    super.didUpdateWidget(old);
    _activatedIndices.add(widget.index);
    if (old.index != widget.index) {
      _c.reset();
      _c.forward();
    }
    // FIX-3.5: Clean up stale cached widgets if item count changes
    if (old.itemCount != widget.itemCount) {
      _cachedWidgets.removeWhere((key, _) => key >= widget.itemCount);
      _activatedIndices.removeWhere((key) => key >= widget.itemCount);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _cachedWidgets.clear();
    _activatedIndices.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _activatedIndices.add(widget.index);
    return FadeTransition(
      opacity: _c,
      child: IndexedStack(
        index: widget.index,
        children: List.generate(widget.itemCount, (i) {
          final isCurrent = i == widget.index;
          final isActivated = _activatedIndices.contains(i);
          if (isActivated && !_cachedWidgets.containsKey(i)) {
            _cachedWidgets[i] = Builder(
              builder: (ctx) => widget.itemBuilder(ctx, i),
            );
          }
          return TickerMode(
            enabled: isCurrent,
            child: isActivated
                ? (_cachedWidgets[i] ?? const SizedBox.shrink())
                : const SizedBox.shrink(),
          );
        }),
      ),
    );
  }
}

class _PhoneBottomNavBar extends StatelessWidget {
  final ({
    bool isDark,
    bool isAmoled,
    bool classicUi,
    bool vibration
  }) settingsTuple;
  final ({
    int activeTabIndex,
    bool isNavbarVisible,
    bool isSelectionMode
  }) navState;
  final bool isDark;
  final bool isRtl;

  const _PhoneBottomNavBar({
    required this.settingsTuple,
    required this.navState,
    required this.isDark,
    required this.isRtl,
  });

  @override
  Widget build(BuildContext context) {
    final currentIndex = navState.activeTabIndex;
    final navBg = AppTheme.surfaceColor(
      isDark,
      isAmoled: settingsTuple.isAmoled,
      elevated: true,
    );
    final borderColor = AppTheme.hairlineBorder(
      isDark,
      isAmoled: settingsTuple.isAmoled,
    );
    final isShowing = navState.isNavbarVisible &&
        currentIndex != 1 &&
        !navState.isSelectionMode;
    final useSolid = settingsTuple.classicUi || PowerMonitor.isLowEndDevice;

    return AnimatedSlide(
      offset: isShowing ? Offset.zero : const Offset(0, 1.8),
      duration: AppTheme.motionBase,
      curve: AppTheme.motionCurve,
      child: RepaintBoundary(
        child: SafeArea(
          top: false,
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            alignment: Alignment.bottomCenter,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 460),
              decoration: BoxDecoration(
                color: useSolid
                    ? navBg
                    : navBg.withValues(
                        alpha: settingsTuple.isAmoled
                            ? 0.96
                            : (isDark ? 0.88 : 0.94),
                      ),
                borderRadius: BorderRadius.circular(DmxTokens.radius2xl),
                border: Border.all(
                  color: borderColor,
                  width: DmxTokens.borderThin,
                ),
                boxShadow: settingsTuple.classicUi
                    ? null
                    : AppTheme.cardShadow(isDark, elevated: true),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(DmxTokens.radius2xl),
                child: DmxBackdropFilter(
                  sigmaX: useSolid ? 0 : 14,
                  sigmaY: useSolid ? 0 : 14,
                  forceSolid: useSolid,
                  child: Directionality(
                    textDirection:
                        isRtl ? TextDirection.rtl : TextDirection.ltr,
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 62),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10.0,
                        vertical: 6.0,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _NavItem(
                            index: 0,
                            icon: Icons.file_download_outlined,
                            activeIcon: Icons.file_download,
                            label: L10n.of(context, 'title_transmissions'),
                            settingsTuple: settingsTuple,
                            isDark: isDark,
                            currentIndex: currentIndex,
                          ),
                          _NavItem(
                            index: 1,
                            icon: Icons.language_outlined,
                            activeIcon: Icons.language,
                            label: L10n.of(context, 'title_browser'),
                            settingsTuple: settingsTuple,
                            isDark: isDark,
                            currentIndex: currentIndex,
                          ),
                          _NavItem(
                            index: 2,
                            icon: Icons.settings_outlined,
                            activeIcon: Icons.settings_rounded,
                            label: L10n.of(context, 'title_config'),
                            settingsTuple: settingsTuple,
                            isDark: isDark,
                            currentIndex: currentIndex,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TabletFloatingNavBar extends StatelessWidget {
  final ({
    bool isDark,
    bool isAmoled,
    bool classicUi,
    bool vibration
  }) settingsTuple;
  final ({
    int activeTabIndex,
    bool isNavbarVisible,
    bool isSelectionMode
  }) navState;
  final bool isDark;
  final bool isRtl;

  const _TabletFloatingNavBar({
    required this.settingsTuple,
    required this.navState,
    required this.isDark,
    required this.isRtl,
  });

  @override
  Widget build(BuildContext context) {
    final currentIndex = navState.activeTabIndex;
    final navBg = AppTheme.surfaceColor(
      isDark,
      isAmoled: settingsTuple.isAmoled,
      elevated: true,
    );
    final borderColor = AppTheme.hairlineBorder(
      isDark,
      isAmoled: settingsTuple.isAmoled,
    );
    final isShowing = navState.isNavbarVisible &&
        currentIndex != 1 &&
        !navState.isSelectionMode;
    final useSolid = settingsTuple.classicUi || PowerMonitor.isLowEndDevice;

    return AnimatedSlide(
      offset: isShowing ? Offset.zero : const Offset(0, 1.8),
      duration: AppTheme.motionSlow,
      curve: AppTheme.motionCurve,
      child: RepaintBoundary(
        child: SafeArea(
          top: false,
          child: Container(
            margin: const EdgeInsets.only(bottom: 20, left: 32, right: 32),
            alignment: Alignment.bottomCenter,
            constraints: const BoxConstraints(minHeight: 66),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 440),
              decoration: BoxDecoration(
                color: useSolid
                    ? navBg
                    : navBg.withValues(
                        alpha: settingsTuple.isAmoled
                            ? 0.96
                            : (isDark ? 0.88 : 0.94),
                      ),
                borderRadius: BorderRadius.circular(DmxTokens.radius2xl),
                border: Border.all(
                  color: borderColor,
                  width: DmxTokens.borderThin,
                ),
                boxShadow: settingsTuple.classicUi
                    ? null
                    : AppTheme.cardShadow(isDark, elevated: true),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(DmxTokens.radius2xl),
                child: DmxBackdropFilter(
                  sigmaX: useSolid ? 0 : 14,
                  sigmaY: useSolid ? 0 : 14,
                  forceSolid: useSolid,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14.0,
                      vertical: 6.0,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _NavItem(
                          index: 0,
                          icon: Icons.file_download_outlined,
                          activeIcon: Icons.file_download,
                          label: L10n.of(context, 'title_transmissions'),
                          settingsTuple: settingsTuple,
                          isDark: isDark,
                          currentIndex: currentIndex,
                        ),
                        _NavItem(
                          index: 1,
                          icon: Icons.language_outlined,
                          activeIcon: Icons.language,
                          label: L10n.of(context, 'title_browser'),
                          settingsTuple: settingsTuple,
                          isDark: isDark,
                          currentIndex: currentIndex,
                        ),
                        _NavItem(
                          index: 2,
                          icon: Icons.settings_outlined,
                          activeIcon: Icons.settings_rounded,
                          label: L10n.of(context, 'title_config'),
                          settingsTuple: settingsTuple,
                          isDark: isDark,
                          currentIndex: currentIndex,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavigationRailWidget extends StatelessWidget {
  final ({
    bool isDark,
    bool isAmoled,
    bool classicUi,
    bool vibration
  }) settingsTuple;
  final bool isDark;
  final bool isRtl;
  final int currentIndex;

  const _NavigationRailWidget({
    required this.settingsTuple,
    required this.isDark,
    required this.isRtl,
    required this.currentIndex,
  });

  @override
  Widget build(BuildContext context) {
    final downloadProvider = context.read<DownloadProvider>();
    final activeColor = context.select(
      (DownloadProvider p) => getActiveFilterColor(p, isDark),
    );
    final settingsTabColor = context.select(
      (SettingsProvider s) =>
          getSettingsTabColor(s.activeSettingsTabIndex, isDark),
    );
    final inactiveColor = AppTheme.textSecondaryOf(isDark);
    final navBg = AppTheme.surfaceColor(
      isDark,
      isAmoled: settingsTuple.isAmoled,
    );
    final sideBorderColor = AppTheme.hairlineBorder(
      isDark,
      isAmoled: settingsTuple.isAmoled,
    );

    final isPhoneLandscapeMode = isPhoneLandscape(context);
    final baseRailWidth = isPhoneLandscapeMode ? 76.0 : 84.0;

    final mediaPadding = MediaQuery.paddingOf(context);
    final sideInset = isRtl ? mediaPadding.right : mediaPadding.left;
    final totalRailWidth = baseRailWidth + sideInset;

    final useSolidNav = settingsTuple.classicUi || PowerMonitor.isLowEndDevice;
    return Container(
      width: totalRailWidth,
      height: double.infinity,
      decoration: BoxDecoration(
        color: useSolidNav
            ? navBg
            : navBg.withValues(
                alpha: settingsTuple.isAmoled ? 1.0 : 0.90,
              ),
        border: Border(
          right: isRtl
              ? BorderSide.none
              : BorderSide(color: sideBorderColor, width: DmxTokens.borderThin),
          left: isRtl
              ? BorderSide(color: sideBorderColor, width: DmxTokens.borderThin)
              : BorderSide.none,
        ),
      ),
      child: DmxBackdropFilter(
        sigmaX: useSolidNav ? 0 : 14,
        sigmaY: useSolidNav ? 0 : 14,
        forceSolid: useSolidNav,
        child: SafeArea(
          top: true,
          bottom: true,
          left: true,
          right: true,
          child: Column(
            children: [
              SizedBox(height: isPhoneLandscapeMode ? 8 : 16),
              Padding(
                padding: EdgeInsets.symmetric(
                  vertical: isPhoneLandscapeMode ? 4 : 10,
                ),
                child: DmxAppIcon(
                  size: isPhoneLandscapeMode ? 26 : 32,
                  showGlow: false,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Divider(
                  height: isPhoneLandscapeMode ? 8 : 16,
                  thickness: 0.8,
                  color: sideBorderColor,
                ),
              ),
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _RailItem(
                          index: 0,
                          icon: Icons.file_download_outlined,
                          selectedIcon: Icons.file_download,
                          label: L10n.of(context, 'title_transmissions'),
                          isSelected: currentIndex == 0,
                          activeColor: activeColor,
                          inactiveColor: inactiveColor,
                          onTap: () {
                            if (settingsTuple.vibration) {
                              HapticFeedback.lightImpact();
                            }
                            downloadProvider.setActiveTabIndex(0);
                          },
                        ),
                        _RailItem(
                          index: 1,
                          icon: Icons.language_outlined,
                          selectedIcon: Icons.language,
                          label: L10n.of(context, 'title_browser'),
                          isSelected: currentIndex == 1,
                          activeColor: activeColor,
                          inactiveColor: inactiveColor,
                          onTap: () {
                            if (settingsTuple.vibration) {
                              HapticFeedback.lightImpact();
                            }
                            downloadProvider.setActiveTabIndex(1);
                          },
                        ),
                        _RailItem(
                          index: 2,
                          icon: Icons.settings_outlined,
                          selectedIcon: Icons.settings_rounded,
                          label: L10n.of(context, 'title_config'),
                          isSelected: currentIndex == 2,
                          activeColor: settingsTabColor,
                          inactiveColor: inactiveColor,
                          onTap: () {
                            if (settingsTuple.vibration) {
                              HapticFeedback.lightImpact();
                            }
                            downloadProvider.setActiveTabIndex(2);
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
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  final int index;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool isSelected;
  final Color activeColor;
  final Color inactiveColor;
  final VoidCallback onTap;

  const _RailItem({
    required this.index,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.isSelected,
    required this.activeColor,
    required this.inactiveColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? activeColor : inactiveColor;
    final displayIcon = isSelected ? selectedIcon : icon;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isLandscapeMode = isPhoneLandscape(context);

    return Semantics(
      selected: isSelected,
      label: label,
      button: true,
      hint: 'Double tap to switch tab',
      child: Padding(
        padding: EdgeInsets.symmetric(
          vertical: isLandscapeMode ? 3 : 5,
          horizontal: 6,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            focusColor: AppTheme.focusRingColor(isDark).withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
            child: AnimatedContainer(
              duration: AppTheme.motionBase,
              curve: AppTheme.motionCurve,
              padding: EdgeInsets.symmetric(
                vertical: isLandscapeMode ? 8 : 10,
                horizontal: isLandscapeMode ? 4 : 6,
              ),
              decoration: BoxDecoration(
                color: isSelected
                    ? activeColor.withValues(alpha: isDark ? 0.14 : 0.10)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                border: isSelected
                    ? Border.all(
                        color:
                            activeColor.withValues(alpha: isDark ? 0.28 : 0.22),
                        width: DmxTokens.borderThin,
                      )
                    : null,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Icon(displayIcon,
                          color: color, size: isLandscapeMode ? 21 : 23),
                      if (index == 0)
                        PositionedDirectional(
                          top: -4,
                          end: -6,
                          child: _ActiveCountBadge(isDark: isDark),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: double.infinity,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        style: TextStyle(
                          fontFamily: AppTheme.fontDisplay,
                          color: color,
                          fontSize: isLandscapeMode ? 10 : 11,
                          fontWeight:
                              isSelected ? FontWeight.w700 : FontWeight.w500,
                        ),
                        maxLines: 1,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final int index;
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final ({
    bool isDark,
    bool isAmoled,
    bool classicUi,
    bool vibration
  }) settingsTuple;
  final bool isDark;
  final int currentIndex;

  const _NavItem({
    required this.index,
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.settingsTuple,
    required this.isDark,
    required this.currentIndex,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = currentIndex == index;
    final activeColor = (index == 0)
        ? context.select(
            (DownloadProvider p) => getActiveFilterColor(p, isDark),
          )
        : (index == 2)
            ? context.select(
                (SettingsProvider s) =>
                    getSettingsTabColor(s.activeSettingsTabIndex, isDark),
              )
            : (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue);
    final inactiveColor = AppTheme.textSecondaryOf(isDark);
    final color = isSelected ? activeColor : inactiveColor;
    final displayIcon = isSelected ? activeIcon : icon;

    return Expanded(
      child: Semantics(
        selected: isSelected,
        label: label,
        button: true,
        hint: 'Double tap to switch tab',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              if (settingsTuple.vibration) HapticFeedback.lightImpact();
              context.read<DownloadProvider>().setActiveTabIndex(index);
            },
            focusColor: AppTheme.focusRingColor(isDark).withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(DmxTokens.radiusLg),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      AnimatedContainer(
                        duration: AppTheme.motionBase,
                        curve: AppTheme.motionCurve,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? activeColor.withValues(
                                  alpha: isDark ? 0.16 : 0.11)
                              : Colors.transparent,
                          borderRadius:
                              BorderRadius.circular(DmxTokens.radiusFull),
                        ),
                        child: Icon(
                          displayIcon,
                          color: color,
                          size: isTablet(context) ? 23 : 21,
                        ),
                      ),
                      if (index == 0)
                        PositionedDirectional(
                          top: -3,
                          end: 4,
                          child: _ActiveCountBadge(isDark: isDark),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      maxLines: 1,
                      style: TextStyle(
                        fontFamily: AppTheme.fontDisplay,
                        color: color,
                        fontSize: isTablet(context) ? 11.5 : 10.5,
                        fontWeight:
                            isSelected ? FontWeight.w700 : FontWeight.w500,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActiveCountBadge extends StatelessWidget {
  final bool isDark;
  const _ActiveCountBadge({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Selector<DownloadProvider, int>(
      selector: (_, p) => p.downloadingTasksCount,
      builder: (_, count, __) {
        if (count <= 0) return const SizedBox.shrink();
        final badgeBg = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
        final badgeFg = AppTheme.inkOn(badgeBg);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
          decoration: BoxDecoration(
            color: badgeBg,
            borderRadius: BorderRadius.circular(DmxTokens.radiusFull),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              fontFamily: AppTheme.fontDisplay,
              color: badgeFg,
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
      },
    );
  }
}
