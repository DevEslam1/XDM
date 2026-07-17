import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/app_theme.dart';
import '../../features/settings/provider/settings_provider.dart';

class GlassCard extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final bool isDarkMode;
  final bool enableBlur;
  final Border? border;

  const GlassCard({
    super.key,
    required this.child,
    this.borderRadius = 20.0,
    this.padding,
    required this.isDarkMode,
    this.enableBlur = false,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsProvider>();
    if (settings.classicUi || !enableBlur) {
      return Container(
        padding: padding,
        decoration: BoxDecoration(
          color: isDarkMode ? AppTheme.surface : AppTheme.lightSurface,
          border: border ?? Border.all(
            color: isDarkMode ? AppTheme.border : AppTheme.lightBorder,
            width: 1.0,
          ),
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: child,
      );
    }

    return Container(
      padding: padding,
      decoration: AppTheme.glassDecoration(
        borderRadius: borderRadius,
        isDark: isDarkMode,
      ).copyWith(
        border: border,
      ),
      child: child,
    );
  }
}