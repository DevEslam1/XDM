import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/services/background_gate.dart';
import '../../core/services/performance_monitor.dart';
import '../../core/services/power_monitor.dart';
import '../accessibility/high_contrast_detector.dart';

/// A surface panel with an optional accent rail, tinted border, and a subtle
/// press response.
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
  /// are screen-level only; list items must render static semi-transparent
  /// surfaces so the GPU never allocates a per-item backdrop snapshot.
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
    final isLowEnd = PowerMonitor.isLowEndDevice || !GlassCard.enabled;
    final shouldBlur = widget.enableBlur &&
        !isLowEnd &&
        !PowerMonitor.batterySaverMode.isAggressive &&
        !HighContrastDetector.isActive(context) &&
        BackgroundGate.shouldAnimate;

    if (!shouldBlur || isLowEnd) {
      return Container(
        padding: widget.padding,
        decoration: BoxDecoration(
          color: widget.isDarkMode
              ? AppTheme.surface.withValues(alpha: 0.70)
              : AppTheme.lightSurface.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(widget.borderRadius),
          border: widget.border,
        ),
        child: widget.child,
      );
    }

    final isDark = widget.isDarkMode;
    final accent = widget.accentColor ??
        (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue);

    // Performance Optimization: Replace expensive BackdropFilter with semi-transparent
    // solid fallback background to maintain 60/120fps during list scrolling.
    final baseCard = RepaintBoundary(
      child: Container(
        padding: widget.padding,
        decoration: BoxDecoration(
          color: isDark
              ? AppTheme.surface.withValues(alpha: 0.70)
              : AppTheme.lightSurface.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(widget.borderRadius),
          border: widget.border ??
              Border.all(
                color: widget.accentColor != null
                    ? accent.withValues(alpha: 0.30)
                    : (isDark ? AppTheme.border : AppTheme.lightBorder),
                width: widget.accentColor != null ? 1.0 : 0.5,
              ),
        ),
        child: widget.child,
      ),
    );

    final withRail = widget.showRail
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
                      boxShadow: [
                        AppTheme.glow(accent, alpha: 0.5, blur: 6, spread: 0),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          )
        : baseCard;

    final withBorder = widget.gradientBorder != null
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

    if (widget.onTap == null) return RepaintBoundary(child: withBorder);

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
                scale: (!reduceMotion && _pressed) ? 0.98 : 1.0,
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
