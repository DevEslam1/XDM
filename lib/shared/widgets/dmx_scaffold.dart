import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../features/settings/provider/settings_provider.dart';
import 'dmx_backdrop_filter.dart';
import 'geometric_grid_background.dart';

/// Unified Scaffold for DMX that eliminates redundant background repaints,
/// handles AMOLED dark mode cleanly, and prevents backdrop filter stacking.
class DmxScaffold extends StatelessWidget {
  final PreferredSizeWidget? appBar;
  final Widget body;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final Widget? bottomNavigationBar;
  final bool extendBodyBehindAppBar;
  final Color? backgroundColor;
  final bool showGridBackground;

  const DmxScaffold({
    super.key,
    this.appBar,
    required this.body,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.bottomNavigationBar,
    this.extendBodyBehindAppBar = false,
    this.backgroundColor,
    this.showGridBackground = true,
  });

  /// Factory helper to create standard DMX AppBars with optimized blur & AMOLED support.
  static PreferredSizeWidget createAppBar(
    BuildContext context, {
    Widget? title,
    List<Widget>? actions,
    Widget? leading,
    bool automaticallyImplyLeading = true,
    double elevation = 0,
    Color? titleColor,
    PreferredSizeWidget? bottom,
  }) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final isDark = settings.isDarkMode;
    final isAmoled = settings.isAmoledMode && isDark;

    return AppBar(
      title: title,
      actions: actions,
      leading: leading,
      automaticallyImplyLeading: automaticallyImplyLeading,
      elevation: elevation,
      bottom: bottom,
      backgroundColor: isDark
          ? (isAmoled ? AppTheme.amoledBackground : Colors.transparent)
          : Colors.transparent,
      flexibleSpace: isAmoled
          ? null
          : ClipRect(
              child: DmxBackdropFilter(
                sigmaX: 12,
                sigmaY: 12,
                child: Container(
                  color: (isDark ? AppTheme.surface : AppTheme.lightSurface)
                      .withValues(alpha: 0.5),
                ),
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scaffold = Scaffold(
      backgroundColor: backgroundColor ?? Colors.transparent,
      appBar: appBar,
      body: body,
      floatingActionButton: floatingActionButton,
      floatingActionButtonLocation: floatingActionButtonLocation,
      bottomNavigationBar: bottomNavigationBar,
      extendBodyBehindAppBar: extendBodyBehindAppBar,
    );

    if (!showGridBackground) {
      return scaffold;
    }

    return RepaintBoundary(
      child: GeometricGridBackground(
        child: scaffold,
      ),
    );
  }
}
