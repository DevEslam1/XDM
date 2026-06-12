import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/app_theme.dart';
import '../../core/services/clipboard_service.dart';
import '../../core/services/share_service.dart';
import '../../core/utils/localization.dart';
import '../../features/add_download/screens/add_screen.dart';
import '../../features/browser/screens/browser_screen.dart';
import '../../features/home/screens/home_screen.dart';
import '../../features/onboarding/screens/biometric_lock_screen.dart';
import '../../features/settings/provider/settings_provider.dart';
import '../../features/settings/screens/settings_screen.dart';
import '../../features/downloads/provider/download_provider.dart';
import 'clipboard_detection_sheet.dart';
import 'dmx_backdrop_filter.dart';
import '../../core/utils/premium_route.dart';

class MainNavigationContainer extends StatefulWidget {
  const MainNavigationContainer({super.key});

  @override
  State<MainNavigationContainer> createState() =>
      _MainNavigationContainerState();
}

class _MainNavigationContainerState extends State<MainNavigationContainer> with WidgetsBindingObserver {
  bool _isLocked = false;
  bool _isLockScreenOpen = false;

  final List<Widget> _screens = [
    const HomeScreen(),
    const BrowserScreen(),
    const SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ShareService().init(onUrlReceived: _onUrlReceived);
    _checkClipboard();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ShareService().dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    if (state == AppLifecycleState.paused) {
      if (settings.biometricLock) {
        _isLocked = true;
      }
    } else if (state == AppLifecycleState.resumed) {
      _checkClipboard();
      if (settings.biometricLock && _isLocked && !_isLockScreenOpen && mounted) {
        _showLockScreen();
      }
    }
  }

  Future<void> _showLockScreen() async {
    if (!mounted) return;
    setState(() {
      _isLockScreenOpen = true;
    });
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);

    final result = await Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => BiometricLockScreen(
          isDark: isDark,
          isRtl: isRtl,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        barrierDismissible: false,
      ),
    );

    // Always reset the "lock screen is open" flag, regardless of how the
    // route was dismissed (success, back gesture, route replacement).
    // Otherwise future lifecycle events won't re-prompt.
    if (!mounted) return;
    setState(() {
      _isLockScreenOpen = false;
    });

    if (result == true) {
      setState(() {
        _isLocked = false;
      });
    }
    // If result is not true, _isLocked stays true and the next
    // lifecycle-resume will re-prompt the lock screen.
  }

  void _onUrlReceived(String url) {
    // The share-intent callback fires on isolate-level events that can land
    // after this widget is unmounted (background → resume). Guard against
    // using a deactivated context.
    if (!mounted) return;
    Navigator.push(
      context,
      PremiumPageRoute(
        type: PageTransitionType.slideUp,
        child: AddScreen(prefilledUrl: url),
      ),
    );
  }

  Future<void> _checkClipboard() async {
    final url = await ClipboardService().checkClipboardForUrl();
    if (url != null && mounted) {
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

    return Scaffold(
      backgroundColor: isDark ? AppTheme.background : AppTheme.lightBackground,
      extendBody: true,
      body: Directionality(
        textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
        child: FadeIndexedStack(
          index: currentIndex,
          children: _screens,
        ),
      ),
      bottomNavigationBar: AnimatedSlide(
        offset: (downloadProvider.isNavbarVisible && currentIndex != 1) ? Offset.zero : const Offset(0, 1.0),
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
                    : (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(alpha: 0.65),
                borderRadius: settings.classicUi
                    ? BorderRadius.zero
                    : const BorderRadius.vertical(top: Radius.circular(24)),
                border: Border(
                  top: BorderSide(
                    color: settings.classicUi
                        ? (isDark ? AppTheme.border : AppTheme.lightBorder)
                        : (isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder),
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
                        _buildNavItem(
                          index: 0,
                          icon: Icons.file_download_outlined,
                          activeIcon: Icons.file_download,
                          label: L10n.of(context, 'title_transmissions'),
                        ),
                        _buildNavItem(
                          index: 1,
                          icon: Icons.language_outlined,
                          activeIcon: Icons.language,
                          label: L10n.of(context, 'title_browser'),
                        ),
                        _buildNavItem(
                          index: 2,
                          icon: Icons.settings_outlined,
                          activeIcon: Icons.settings_rounded,
                          label: L10n.of(context, 'title_config'),
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

  Widget _buildNavItem({
    required int index,
    required IconData icon,
    required IconData activeIcon,
    required String label,
  }) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final downloadProvider = Provider.of<DownloadProvider>(context, listen: false);
    final isDark = settings.isDarkMode;
    final currentIndex = downloadProvider.activeTabIndex;
    final isSelected = currentIndex == index;
    final activeColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final inactiveColor = isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
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
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );
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
      child: IndexedStack(
        index: widget.index,
        children: widget.children,
      ),
    );
  }
}
