import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/app_theme.dart';
import '../../core/services/clipboard_service.dart';
import '../../core/services/share_service.dart';
import '../../core/utils/localization.dart';
import '../../core/utils/responsive.dart';
import '../../core/services/share_url_handler.dart';
import '../../features/browser/screens/browser_screen.dart';
import '../../features/home/screens/home_screen.dart';

import '../../features/settings/provider/settings_provider.dart';
import '../../features/settings/screens/settings_screen.dart';
import '../../features/downloads/provider/download_provider.dart';
import '../../core/services/single_instance_service.dart';
import 'clipboard_detection_sheet.dart';
import 'dmx_backdrop_filter.dart';

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
    }
  }

  void _onUrlReceived(String url, {bool isShareLaunch = false}) async {
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
      _showClipboardBottomSheet(url);
    }
  }

  void _showClipboardBottomSheet(String url) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return ClipboardDetectionSheet(
          url: url,
          onEstablish: () => _onUrlReceived(url),
        );
      },
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
      child: FadeIndexedStack(index: currentIndex, children: _screens),
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
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
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
                        .withValues(alpha: 0.65),
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
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOutCubic,
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
                        .withValues(alpha: 0.65),
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
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Icon(
                  Icons.download_for_offline_rounded,
                  color: activeColor,
                  size: 32,
                ),
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
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: isSelected
                  ? activeColor.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
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
    final color = isSelected ? activeColor : inactiveColor;
    final displayIcon = isSelected ? activeIcon : icon;

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            if (settings.vibration) {
              HapticFeedback.lightImpact();
            }
            downloadProvider.setActiveTabIndex(index);
          },
          borderRadius: BorderRadius.circular(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: isSelected
                      ? activeColor.withValues(alpha: 0.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(displayIcon, color: color, size: 22),
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

class FadeIndexedStack extends StatefulWidget {
  final int index;
  final List<Widget> children;
  final Duration duration;

  const FadeIndexedStack({
    super.key,
    required this.index,
    required this.children,
    this.duration = const Duration(milliseconds: 220),
  });

  @override
  State<FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<FadeIndexedStack>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _controller.forward();
  }

  @override
  void didUpdateWidget(FadeIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      _controller.reset();
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: IndexedStack(index: widget.index, children: widget.children),
    );
  }
}
