import 'package:flutter/material.dart';
import '../../core/app_theme.dart';

/// A surface panel with an optional accent rail, tinted border, and a subtle
/// press response.
class GlassCard extends StatefulWidget {
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

  const GlassCard({
    super.key,
    required this.child,
    this.borderRadius = 16.0,
    this.padding,
    required this.isDarkMode,
    this.border,
    this.accentColor,
    this.showRail = false,
    this.elevated = false,
    this.gradientBorder,
    this.onTap,
  });

  @override
  State<GlassCard> createState() => _GlassCardState();
}

class _GlassCardState extends State<GlassCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDarkMode;
    final accent = widget.accentColor ??
        (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue);

    final base = AnimatedContainer(
      duration: AppTheme.motionBase,
      curve: AppTheme.motionCurve,
      padding: widget.padding,
      decoration: BoxDecoration(
        color: isDark ? AppTheme.surface : AppTheme.lightSurface,
        borderRadius: BorderRadius.circular(widget.borderRadius),
        border: widget.border ??
            Border.all(
              color: widget.accentColor != null
                  ? accent.withValues(alpha: 0.30)
                  : (isDark ? AppTheme.border : AppTheme.lightBorder),
              width: widget.accentColor != null ? 1.0 : 0.5,
            ),
        boxShadow: widget.elevated
            ? [
                if (widget.accentColor != null)
                  AppTheme.glow(
                    accent,
                    alpha: isDark ? 0.12 : 0.08,
                    blur: 14,
                    spread: -4,
                  ),
                BoxShadow(
                  color: (isDark
                          ? Colors.black
                          : Colors.black.withValues(alpha: 0.5))
                      .withValues(alpha: 0.25),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                  spreadRadius: -1,
                ),
                BoxShadow(
                  color: accent.withValues(alpha: 0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ]
            : [
                if (widget.accentColor != null)
                  AppTheme.glow(
                    accent,
                    alpha: isDark ? 0.12 : 0.08,
                    blur: 14,
                    spread: -4,
                  ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.20 : 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
      ),
      child: widget.child,
    );

    final withRail = widget.showRail
        ? ClipRRect(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            child: Stack(
              children: [
                base,
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
        : base;

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

    if (widget.onTap == null) return withBorder;

    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return Semantics(
      button: true,
      enabled: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _pressed = false),
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
    );
  }
}
