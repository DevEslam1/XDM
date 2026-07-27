import 'package:dmx/core/utils/localization.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:dmx/shared/widgets/dmx_app_icon.dart';
import 'package:dmx/shared/widgets/dmx_backdrop_filter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/app_theme.dart';
import '../../core/services/clipboard_service.dart';
import '../../core/services/share_service.dart';
import '../../core/services/share_url_handler.dart';
import '../../core/services/single_instance_service.dart';
import '../../core/services/update_service.dart';
import '../../core/utils/responsive.dart';
import '../../features/browser/screens/browser_screen.dart';
import '../../features/home/screens/home_screen.dart';
import '../../features/settings/screens/settings_screen.dart';
import '../../features/settings/widgets/update_dialogs.dart';
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
  DateTime _lastClipboardCheckTime = DateTime.fromMillisecondsSinceEpoch(0);

  final List<Widget> _screens = [
    const HomeScreen(),
    const BrowserScreen(),
    const SettingsScreen(),
  ];

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
          _onUrlReceived(widget.initialUrl!, isShareLaunch: widget.isShareLaunch);
        }
      });
    }
    _checkClipboard();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAppUpdates();
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
          final isRtl = L10n.isRtl(context);
          ThemedSnackbar.show(
            context,
            message: isRtl
                ? 'New update available v${update.latestVersion}'
                : 'New update available v${update.latestVersion}',
            color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
            icon: Icons.system_update_rounded,
            isDarkMode: isDark,
            actionLabel: isRtl ? 'تنزيل' : 'Update',
            onAction: () =>
                showUpdateInfoDialog(context, update, provider, settings),
          );
        }
      }
    } catch (e) {
      debugPrint('Update check error: $e');
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
    if (state == AppLifecycleState.resumed) _checkClipboard();
  }

  void _onUrlReceived(String url, {bool isShareLaunch = false}) {
    if (!mounted) return;
    ShareUrlHandler.handle(context, url, isShareLaunch: isShareLaunch);
  }

  Future<void> _checkClipboard() async {
    final now = DateTime.now();
    if (now.difference(_lastClipboardCheckTime).inSeconds < 5) return;
    _lastClipboardCheckTime = now;
    final url = await ClipboardService().checkClipboardForUrl();
    if (url != null && mounted && url != _lastClipboardUrl) {
      _lastClipboardUrl = url;
      _showClipboardSnackbar(url);
    }
  }

  void _showClipboardSnackbar(String url) {
    final settings = context.read<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    if (settings.vibration) HapticFeedback.mediumImpact();
    final preview = url.length > 40 ? '${url.substring(0, 40)}…' : url;
    ThemedSnackbar.show(
      context,
      message: isRtl
          ? 'تم اكتشاف رابط في الحافظة'
          : 'Link detected in clipboard',
      subtitle: preview,
      color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
      icon: Icons.content_paste_go_rounded,
      isDarkMode: isDark,
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final downloadProvider = context.watch<DownloadProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final currentIndex = downloadProvider.activeTabIndex;
    final screenType = getScreenType(context);

    final bodyContent = Directionality(
      textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
      child: _FadeIndexedStack(index: currentIndex, children: _screens),
    );

    return Scaffold(
      backgroundColor: isDark ? AppTheme.background : AppTheme.lightBackground,
      extendBody: true,
      body: screenType == ScreenType.desktop
          ? Row(
              children: [
                _NavigationRailWidget(
                  settings: settings,
                  downloadProvider: downloadProvider,
                  isDark: isDark,
                  isRtl: isRtl,
                  currentIndex: currentIndex,
                ),
                const VerticalDivider(width: 1),
                Expanded(child: bodyContent),
              ],
            )
          : bodyContent,
      bottomNavigationBar: screenType == ScreenType.phone
          ? _PhoneBottomNavBar(
              settings: settings,
              downloadProvider: downloadProvider,
              isDark: isDark,
              isRtl: isRtl,
              currentIndex: currentIndex,
            )
          : screenType == ScreenType.tablet
          ? _TabletFloatingNavBar(
              settings: settings,
              downloadProvider: downloadProvider,
              isDark: isDark,
              isRtl: isRtl,
              currentIndex: currentIndex,
            )
          : null,
    );
  }
}

// Smooth fade when switching tabs
class _FadeIndexedStack extends StatefulWidget {
  final int index;
  final List<Widget> children;
  const _FadeIndexedStack({required this.index, required this.children});
  @override
  State<_FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<_FadeIndexedStack>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: AppTheme.motionBase,
    )..forward();
  }

  @override
  void didUpdateWidget(_FadeIndexedStack old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      _c.reset();
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _c,
      child: IndexedStack(index: widget.index, children: widget.children),
    );
  }
}


class _PhoneBottomNavBar extends StatelessWidget {
  final SettingsProvider settings;
  final DownloadProvider downloadProvider;
  final bool isDark;
  final bool isRtl;
  final int currentIndex;

  const _PhoneBottomNavBar({
    required this.settings,
    required this.downloadProvider,
    required this.isDark,
    required this.isRtl,
    required this.currentIndex,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      offset: (downloadProvider.isNavbarVisible && currentIndex != 1)
          ? Offset.zero
          : const Offset(0, 1.0),
      duration: AppTheme.motionBase,
      curve: AppTheme.motionCurve,
      child: ClipRRect(
        borderRadius: settings.classicUi
            ? BorderRadius.zero
            : const BorderRadius.vertical(top: Radius.circular(24)),
        child: DmxBackdropFilter(
          sigmaX: 15,
          sigmaY: 15,
          child: Container(
            decoration: BoxDecoration(
              color: settings.classicUi
                  ? (isDark ? AppTheme.surface : AppTheme.lightSurface)
                  : (isDark ? AppTheme.surface : AppTheme.lightSurface)
                        .withValues(alpha: 0.7),
              borderRadius: settings.classicUi
                  ? BorderRadius.zero
                  : const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border(
                top: BorderSide(
                  color: settings.classicUi
                      ? (isDark ? AppTheme.border : AppTheme.lightBorder)
                      : (isDark
                            ? AppTheme.glassBorder
                            : AppTheme.lightGlassBorder),
                  width: settings.classicUi ? 1.0 : 0.6,
                ),
              ),
            ),
            child: SafeArea(
              child: Directionality(
                textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
                child: Container(
                  height: 68,
                  padding: const EdgeInsets.symmetric(horizontal: 12.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _NavItem(
                        index: 0,
                        icon: Icons.file_download_outlined,
                        activeIcon: Icons.file_download,
                        label: L10n.of(context, 'title_transmissions'),
                        settings: settings,
                        downloadProvider: downloadProvider,
                        isDark: isDark,
                        currentIndex: currentIndex,
                      ),
                      _NavItem(
                        index: 1,
                        icon: Icons.language_outlined,
                        activeIcon: Icons.language,
                        label: L10n.of(context, 'title_browser'),
                        settings: settings,
                        downloadProvider: downloadProvider,
                        isDark: isDark,
                        currentIndex: currentIndex,
                      ),
                      _NavItem(
                        index: 2,
                        icon: Icons.settings_outlined,
                        activeIcon: Icons.settings_rounded,
                        label: L10n.of(context, 'title_config'),
                        settings: settings,
                        downloadProvider: downloadProvider,
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
    );
  }
}

class _TabletFloatingNavBar extends StatelessWidget {
  final SettingsProvider settings;
  final DownloadProvider downloadProvider;
  final bool isDark;
  final bool isRtl;
  final int currentIndex;

  const _TabletFloatingNavBar({
    required this.settings,
    required this.downloadProvider,
    required this.isDark,
    required this.isRtl,
    required this.currentIndex,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      offset: (downloadProvider.isNavbarVisible && currentIndex != 1)
          ? Offset.zero
          : const Offset(0, 1.8),
      duration: AppTheme.motionSlow,
      curve: AppTheme.motionCurve,
      child: SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.only(bottom: 24, left: 32, right: 32),
          alignment: Alignment.bottomCenter,
          height: 70,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 460),
            decoration: settings.classicUi
                ? BoxDecoration(
                    color: isDark ? AppTheme.surface : AppTheme.lightSurface,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color: isDark ? AppTheme.border : AppTheme.lightBorder,
                      width: 1.0,
                    ),
                  )
                : BoxDecoration(
                    color: (isDark ? AppTheme.surface : AppTheme.lightSurface)
                        .withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color: isDark
                          ? AppTheme.glassBorder
                          : AppTheme.lightGlassBorder,
                      width: 0.8,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: isDark ? 0.45 : 0.15,
                        ),
                        blurRadius: 20,
                        spreadRadius: 2,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(30),
              child: DmxBackdropFilter(
                sigmaX: 15,
                sigmaY: 15,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _NavItem(
                        index: 0,
                        icon: Icons.file_download_outlined,
                        activeIcon: Icons.file_download,
                        label: L10n.of(context, 'title_transmissions'),
                        settings: settings,
                        downloadProvider: downloadProvider,
                        isDark: isDark,
                        currentIndex: currentIndex,
                      ),
                      _NavItem(
                        index: 1,
                        icon: Icons.language_outlined,
                        activeIcon: Icons.language,
                        label: L10n.of(context, 'title_browser'),
                        settings: settings,
                        downloadProvider: downloadProvider,
                        isDark: isDark,
                        currentIndex: currentIndex,
                      ),
                      _NavItem(
                        index: 2,
                        icon: Icons.settings_outlined,
                        activeIcon: Icons.settings_rounded,
                        label: L10n.of(context, 'title_config'),
                        settings: settings,
                        downloadProvider: downloadProvider,
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
    );
  }
}

class _NavigationRailWidget extends StatelessWidget {
  final SettingsProvider settings;
  final DownloadProvider downloadProvider;
  final bool isDark;
  final bool isRtl;
  final int currentIndex;

  const _NavigationRailWidget({
    required this.settings,
    required this.downloadProvider,
    required this.isDark,
    required this.isRtl,
    required this.currentIndex,
  });

  @override
  Widget build(BuildContext context) {
    final activeColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final inactiveColor = isDark
        ? AppTheme.textSecondary
        : AppTheme.lightTextSecondary;

    return DmxBackdropFilter(
      sigmaX: 15,
      sigmaY: 15,
      child: Container(
        decoration: BoxDecoration(
          color: (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(
            alpha: 0.85,
          ),
          border: isRtl
              ? Border(
                  left: BorderSide(
                    color: isDark ? AppTheme.border : AppTheme.lightBorder,
                    width: 1.0,
                  ),
                )
              : Border(
                  right: BorderSide(
                    color: isDark ? AppTheme.border : AppTheme.lightBorder,
                    width: 1.0,
                  ),
                ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 16),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: DmxAppIcon(size: 40, showGlow: true),
              ),
              const SizedBox(height: 8),
              _RailItem(
                index: 0,
                icon: Icons.file_download_outlined,
                selectedIcon: Icons.file_download,
                label: L10n.of(context, 'title_transmissions'),
                isSelected: currentIndex == 0,
                activeColor: activeColor,
                inactiveColor: inactiveColor,
                onTap: () {
                  if (settings.vibration) HapticFeedback.lightImpact();
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
                  if (settings.vibration) HapticFeedback.lightImpact();
                  downloadProvider.setActiveTabIndex(1);
                },
              ),
              _RailItem(
                index: 2,
                icon: Icons.settings_outlined,
                selectedIcon: Icons.settings_rounded,
                label: L10n.of(context, 'title_config'),
                isSelected: currentIndex == 2,
                activeColor: activeColor,
                inactiveColor: inactiveColor,
                onTap: () {
                  if (settings.vibration) HapticFeedback.lightImpact();
                  downloadProvider.setActiveTabIndex(2);
                },
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: AppTheme.motionBase,
            curve: AppTheme.motionCurve,
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: isSelected
                  ? activeColor.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: isSelected
                  ? Border.all(
                      color: activeColor.withValues(alpha: 0.3),
                      width: 0.8,
                    )
                  : null,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(displayIcon, color: color, size: 24),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
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
  final SettingsProvider settings;
  final DownloadProvider downloadProvider;
  final bool isDark;
  final int currentIndex;

  const _NavItem({
    required this.index,
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.settings,
    required this.downloadProvider,
    required this.isDark,
    required this.currentIndex,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = currentIndex == index;
    final activeColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final inactiveColor = isDark
        ? AppTheme.textSecondary
        : AppTheme.lightTextSecondary;
    final activeDownloadsCount = index == 0
        ? downloadProvider.downloadingTasksCount
        : 0;
    final totalSpeed = index == 0
        ? downloadProvider.currentDownloadSpeedFormatted
        : '';
    final color = isSelected ? activeColor : inactiveColor;
    final displayIcon = isSelected ? activeIcon : icon;

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            if (settings.vibration) HapticFeedback.mediumImpact();
            downloadProvider.setActiveTabIndex(index);
          },
          borderRadius: BorderRadius.circular(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedContainer(
                    duration: AppTheme.motionBase,
                    curve: AppTheme.motionSpring,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? activeColor.withValues(alpha: 0.12)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(20),
                      border: isSelected
                          ? Border.all(
                              color: activeColor.withValues(alpha: 0.3),
                              width: 0.8,
                            )
                          : null,
                    ),
                    child: Icon(displayIcon, color: color, size: 22),
                  ),
                  if (index == 0 && activeDownloadsCount > 0)
                    Positioned(
                      top: -4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: isDark
                              ? AppTheme.neonGreen
                              : AppTheme.lightNeonGreen,
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: [
                            BoxShadow(
                              color:
                                  (isDark
                                          ? AppTheme.neonGreen
                                          : AppTheme.lightNeonGreen)
                                      .withValues(alpha: 0.4),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                        child: Text(
                          totalSpeed.isNotEmpty
                              ? totalSpeed
                              : '$activeDownloadsCount',
                          style: TextStyle(
                            color: isDark ? Colors.black : Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: color,
                    fontSize: 10.0,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                    letterSpacing: 0.3,
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
