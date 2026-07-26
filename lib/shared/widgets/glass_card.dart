import 'package:flutter/material.dart';
import '../../core/app_theme.dart';

/// A surface panel with an optional accent rail, tinted border, and a subtle
/// press response. `enableBlur` is kept for API compatibility but the card
/// now renders as a solid layered surface (crisper + cheaper than glass).
class GlassCard extends StatefulWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final bool isDarkMode;
  final bool enableBlur;
  final Border? border;
  final Color? accentColor;
  final bool showRail;
  final VoidCallback? onTap;

  const GlassCard({
    super.key,
    required this.child,
    this.borderRadius = 16.0,
    this.padding,
    required this.isDarkMode,
    this.enableBlur = false,
    this.border,
    this.accentColor,
    this.showRail = false,
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
    final accent =
        widget.accentColor ??
        (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue);

    final base = AnimatedContainer(
      duration: AppTheme.motionBase,
      curve: AppTheme.motionCurve,
      padding: widget.padding,
      decoration: BoxDecoration(
        color: isDark ? AppTheme.surface : AppTheme.lightSurface,
        borderRadius: BorderRadius.circular(widget.borderRadius),
        border:
            widget.border ??
            Border.all(
              color: widget.accentColor != null
                  ? accent.withValues(alpha: 0.30)
                  : (isDark ? AppTheme.border : AppTheme.lightBorder),
              width: widget.accentColor != null ? 1.0 : 0.5,
            ),
        boxShadow: [
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
                Positioned(
                  left: 0,
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

    if (widget.onTap == null) return withRail;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1.0,
        duration: AppTheme.motionFast,
        curve: AppTheme.motionSpring,
        child: withRail,
      ),
    );
  }
}
