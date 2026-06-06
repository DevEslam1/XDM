import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import 'dmx_backdrop_filter.dart';

class GlassCard extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final bool isDarkMode;
  final double blurSigma;
  final Border? border;
  final Color? color;

  const GlassCard({
    super.key,
    required this.child,
    this.borderRadius = 20.0,
    this.padding,
    required this.isDarkMode,
    this.blurSigma = 10.0,
    this.border,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final baseDeco = AppTheme.glassDecoration(
      borderRadius: borderRadius,
      isDark: isDarkMode,
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: DmxBackdropFilter(
        sigmaX: blurSigma,
        sigmaY: blurSigma,
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: color ?? baseDeco.color,
            border: border ?? baseDeco.border,
            borderRadius: baseDeco.borderRadius,
            boxShadow: baseDeco.boxShadow,
            gradient: baseDeco.gradient,
          ),
          child: child,
        ),
      ),
    );
  }
}

