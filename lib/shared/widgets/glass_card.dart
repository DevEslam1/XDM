import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/services/background_gate.dart';
import '../../core/services/performance_monitor.dart';
import '../../core/services/power_monitor.dart';
import '../accessibility/high_contrast_detector.dart';

/// A refined surface panel with crisp hairline border, optional accent rail,
/// subtle elevation, and tactile press response.
class GlassCard extends StatefulWidget {
  static bool enabled = true;

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final bool isDarkMode;
  final Border? border;
  final Color? accentColor;
  final bool showRail;
  final bool elevated;
  final LinearGradient? gradientBorder;
  final VoidCallback? onTap;
  final bool enableBlur;

  const GlassCard({
    super.key,
    required this.child,
    this.borderRadius = 16.0,
    this.padding,
    this.isDarkMode = true,
    this.border,
    this.accentColor,
    this.showRail = false,
    this.elevated = false,
    this.gradientBorder,
    this.onTap,
    this.enableBlur = true,
  });

  const GlassCard.placeholder({
    super.key,
    required this.child,
    this.borderRadius = 16.0,
    this.padding,
    this.isDarkMode = true,
    this.border,
    this.accentColor,
    this.showRail = false,
    this.elevated = false,
    this.gradientBorder,
    this.onTap,
    this.enableBlur = false,
  });

  /// Non-blurred variant for scrolling list/grid items. Policy: blur filters
  /// are screen-level only; list items render static high-clarity surfaces so
  /// the GPU never allocates a per-item backdrop snapshot.
  const GlassCard.listItem({
    super.key,
    required this.child,
    this.borderRadius = 16.0,
    this.padding,
    this.isDarkMode = true,
    this.border,
    this.accentColor,
    this.showRail = false,
    this.elevated = false,
    this.gradientBorder,
    this.onTap,
  }) : enableBlur = false;

  @override
  State<GlassCard> createState() => _GlassCardState();
}

class _GlassCardState extends State<GlassCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDarkMode;
    final highContrast = HighContrastDetector.isActive(context);
    final isLowEnd = PowerMonitor.isLowEndDevice || !GlassCard.enabled;
    final translucent = widget.enableBlur &&
        !isLowEnd &&
        !PowerMonitor.batterySaverMode.isAggressive &&
        !highContrast &&
        BackgroundGate.shouldAnimate;

    final accent = widget.accentColor ??
        (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue);

    final baseSurface =
        AppTheme.surfaceColor(isDark, elevated: widget.elevated);
    final bgColor = highContrast
        ? (isDark ? AppTheme.hcSurfaceDark : AppTheme.hcSurfaceLight)
        : (translucent
            ? baseSurface.withValues(alpha: isDark ? 0.88 : 0.94)
            : baseSurface);

    final resolvedBorder = widget.border ??
        Border.all(
          color: highContrast
              ? (isDark ? AppTheme.hcBorderDark : AppTheme.hcBorderLight)
              : (widget.accentColor != null
                  ? accent.withValues(alpha: isDark ? 0.30 : 0.26)
                  : AppTheme.hairlineBorder(
                      isDark,
                      strong: widget.elevated,
                    )),
          width: highContrast
              ? 1.5
              : (widget.accentColor != null ? 1.0 : 0.8),
        );

    final shadows = (isLowEnd || highContrast)
        ? null
        : (widget.elevated
            ? AppTheme.cardShadow(isDark, elevated: true)
            : AppTheme.cardShadow(isDark));

    final Widget baseCard = Container(
      padding: widget.padding,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(widget.borderRadius),
        border: resolvedBorder,
        boxShadow: shadows,
      ),
      child: widget.child,
    );

    final Widget withRail = widget.showRail
        ? ClipRRect(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            child: Stack(
              children: [
                baseCard,
                PositionedDirectional(
                  start: 0,
                  top: 10,
                  bottom: 10,
                  child: Container(
                    width: 3,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ),
          )
        : baseCard;

    final Widget withBorder = widget.gradientBorder != null
        ? Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.borderRadius + 1.5),
              gradient: widget.gradientBorder,
            ),
            padding: const EdgeInsets.all(1.5),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              child: withRail,
            ),
          )
        : withRail;

    if (widget.onTap == null) {
      return RepaintBoundary(child: withBorder);
    }

    final reduceMotion = MediaQuery.disableAnimationsOf(context) ||
        PerformanceMonitor.shouldReduceMotion;

    return RepaintBoundary(
      child: Semantics(
        button: true,
        enabled: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onExit: (_) {
              if (_pressed && mounted) setState(() => _pressed = false);
            },
            child: GestureDetector(
              onTapDown: (_) => setState(() => _pressed = true),
              onTapUp: (_) => setState(() => _pressed = false),
              onTapCancel: () => setState(() => _pressed = false),
              onTap: widget.onTap,
              child: AnimatedScale(
                scale: (!reduceMotion && _pressed) ? 0.985 : 1.0,
                duration: AppTheme.motionFast,
                curve: AppTheme.motionSpring,
                child: withBorder,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
