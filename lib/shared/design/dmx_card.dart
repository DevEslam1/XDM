import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/app_theme.dart';
import '../../features/settings/provider/settings_provider.dart';
import 'dmx_tokens.dart';

enum DmxCardVariant {
  flat, // No shadow, subtle border
  elevated, // Shadow + border
  glass, // Blur + transparency (use sparingly)
  accent, // Colored left rail + border
}

class DmxCard extends StatelessWidget {
  final Widget child;
  final DmxCardVariant variant;
  final Color? accentColor;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool showRail;
  final double? maxWidth;

  const DmxCard({
    super.key,
    required this.child,
    this.variant = DmxCardVariant.flat,
    this.accentColor,
    this.padding = const EdgeInsets.all(DmxTokens.cardPadding),
    this.radius = DmxTokens.radiusLg,
    this.onTap,
    this.onLongPress,
    this.showRail = false,
    this.maxWidth,
  });

  @override
  Widget build(BuildContext context) {
    final (:isDark, :isAmoled, :classicUi, :glow) =
        context.select<SettingsProvider,
            ({bool isDark, bool isAmoled, bool classicUi, bool glow})>(
      (s) => (
        isDark: s.isDarkMode,
        isAmoled: s.isAmoledMode,
        classicUi: s.classicUi,
        glow: s.enableGlow,
      ),
    );

    final bgColor = switch (variant) {
      DmxCardVariant.flat => isDark
          ? (isAmoled ? AppTheme.amoledSurface : AppTheme.surface)
          : AppTheme.lightSurface,
      DmxCardVariant.elevated => isDark
          ? (isAmoled ? AppTheme.amoledSurfaceRaised : AppTheme.surfaceRaised)
          : AppTheme.lightSurfaceRaised,
      DmxCardVariant.glass =>
        (isDark ? AppTheme.surface : AppTheme.lightSurface)
            .withValues(alpha: classicUi ? 1.0 : 0.4),
      DmxCardVariant.accent => isDark
          ? (isAmoled ? AppTheme.amoledCardBg : AppTheme.cardBg)
          : AppTheme.lightCardBg,
    };

    final borderColor = accentColor != null && glow
        ? accentColor!.withValues(alpha: isDark ? 0.24 : 0.28)
        : (isDark
            ? (isAmoled ? AppTheme.amoledBorder : AppTheme.borderSubtle)
            : AppTheme.lightBorderSubtle);

    Widget content = Container(
      constraints:
          maxWidth != null ? BoxConstraints(maxWidth: maxWidth!) : null,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor, width: DmxTokens.borderThin),
        boxShadow: variant == DmxCardVariant.elevated
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.03),
                  blurRadius: DmxTokens.elevationMd,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: !(showRail && accentColor != null)
            ? Padding(padding: padding, child: child)
            : Stack(
                children: [
                  Padding(padding: padding, child: child),
                  PositionedDirectional(
                    start: 0,
                    top: DmxTokens.spaceSm,
                    bottom: DmxTokens.spaceSm,
                    width: 3.5,
                    child: Container(
                      decoration: BoxDecoration(
                        color: accentColor!,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );

    if (onTap != null || onLongPress != null) {
      content = Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(radius),
          child: content,
        ),
      );
    }

    return content;
  }
}
