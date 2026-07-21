import 'package:flutter/material.dart';
import '../../core/app_theme.dart';

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
    this.borderRadius = 16.0,
    this.padding,
    required this.isDarkMode,
    this.enableBlur = false,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: isDarkMode ? const Color(0xFF1E1E1E) : AppTheme.lightSurface,
        border:
            border ??
            Border.all(
              color: isDarkMode
                  ? const Color(0xFF333333)
                  : AppTheme.lightBorder,
              width: 0.5,
            ),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: child,
    );
  }
}
