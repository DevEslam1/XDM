import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/app_theme.dart';
import '../../features/settings/provider/settings_provider.dart';
import '../widgets/dmx_backdrop_filter.dart';

class DmxCardShell extends StatelessWidget {
  final Widget child;
  final Color? accent;
  final double radius;
  final bool showRail;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const DmxCardShell({
    super.key,
    required this.child,
    this.accent,
    this.radius = 16,
    this.showRail = true,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final classicUi = settings.classicUi;
    final isDark = settings.isDarkMode;
    final glow = settings.enableGlow;

    final backgroundColor = classicUi
        ? (isDark ? AppTheme.surface : AppTheme.lightSurface)
        : (isDark
            ? AppTheme.surface.withValues(alpha: 0.4)
            : AppTheme.lightSurface.withValues(alpha: 0.4));

    final resolvedAccent = accent ?? AppTheme.neonBlue;
    Widget content = Container(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: glow
              ? resolvedAccent.withValues(alpha: isDark ? 0.24 : 0.28)
              : (isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle),
          width: 1,
        ),
        boxShadow: [
          if (glow)
            BoxShadow(
              color: resolvedAccent.withValues(alpha: isDark ? 0.08 : 0.04),
              blurRadius: 16,
              spreadRadius: 1,
              offset: const Offset(0, 4),
            )
          else
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.03),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
        ],
      ),
      child: Stack(
        children: [
          child,
          if (showRail)
            Positioned.directional(
              textDirection: Directionality.of(context),
              start: 0,
              top: 0,
              bottom: 0,
              width: 4,
              child: Container(
                decoration: BoxDecoration(
                  color: resolvedAccent,
                  borderRadius: BorderRadiusDirectional.only(
                    topStart: Radius.circular(radius),
                    bottomStart: Radius.circular(radius),
                  ),
                  boxShadow: [
                    AppTheme.glow(resolvedAccent, alpha: 0.30, blur: 6, spread: 0),
                  ],
                ),
              ),
            ),
        ],
      ),
    );

    if (!classicUi) {
      content = ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: DmxBackdropFilter(
          sigmaX: 12,
          sigmaY: 12,
          child: content,
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(radius),
        child: content,
      ),
    );
  }
}
