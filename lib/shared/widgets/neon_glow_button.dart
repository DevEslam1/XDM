import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/app_theme.dart';
import '../../core/services/performance_monitor.dart';
import '../../features/settings/provider/settings_provider.dart';
import '../mixins/pausable_loop_animation.dart';

class NeonGlowButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final String text;
  final IconData? icon;
  final Color color;
  final Color? glowColor;
  final bool isFilled;
  final bool hasGlow;
  final bool isExpanded;
  final bool isLoading;

  const NeonGlowButton({
    super.key,
    required this.onPressed,
    required this.text,
    this.icon,
    this.color = AppTheme.neonBlue,
    this.glowColor,
    this.isFilled = false,
    this.hasGlow = false,
    this.isExpanded = false,
    this.isLoading = false,
  });

  @override
  State<NeonGlowButton> createState() => _NeonGlowButtonState();
}

class _NeonGlowButtonState extends State<NeonGlowButton>
    with
        SingleTickerProviderStateMixin,
        WidgetsBindingObserver,
        PausableLoopAnimation<NeonGlowButton> {
  late final AnimationController _shimmer;
  bool _pressed = false;

  @override
  AnimationController get loopController => _shimmer;

  @override
  bool get loopWanted =>
      widget.onPressed != null &&
      !widget.isLoading &&
      !PerformanceMonitor.shouldReduceMotion;

  @override
  void initState() {
    super.initState();
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );
    startPausableLoop();
  }

  @override
  void didUpdateWidget(NeonGlowButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    syncPausableLoop();
  }

  @override
  void dispose() {
    stopPausableLoop();
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (:isDark, :enableGlow) =
        context.select<SettingsProvider, ({bool isDark, bool enableGlow})>(
      (s) => (isDark: s.isDarkMode, enableGlow: s.enableGlow),
    );
    final filledContentColor =
        isDark ? AppTheme.background : AppTheme.lightBackground;
    final effectiveGlow = widget.hasGlow || enableGlow;
    final enabled = widget.onPressed != null && !widget.isLoading;
    final glow = widget.glowColor ?? widget.color;

    Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.isLoading) ...[
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(
                widget.isFilled ? filledContentColor : widget.color,
              ),
            ),
          ),
          const SizedBox(width: 8),
        ] else if (widget.icon != null) ...[
          Icon(
            widget.icon,
            size: 18,
            color: widget.isFilled ? filledContentColor : widget.color,
          ),
          const SizedBox(width: 8),
        ],
        Text(
          widget.text,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: widget.isFilled ? filledContentColor : widget.color,
                fontWeight: FontWeight.w600,
              ),
        ),
      ],
    );
    if (widget.isExpanded) content = Center(child: content);

    final reduceMotion = MediaQuery.disableAnimationsOf(context) ||
        PerformanceMonitor.shouldReduceMotion;

    // Shimmer sweep across filled buttons
    // ignore: deprecated_member_use
    final isTickerActive = TickerMode.of(context);
    final label = (!reduceMotion &&
            effectiveGlow &&
            widget.isFilled &&
            enabled &&
            isTickerActive &&
            !_shimmer.isDismissed)
        ? ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                content,
                Positioned.fill(
                  child: TickerMode(
                    enabled: isTickerActive,
                    child: AnimatedBuilder(
                      animation: _shimmer,
                      builder: (context, _) {
                        return LayoutBuilder(
                          builder: (context, c) {
                            final w = c.maxWidth;
                            final x = (w + 60) * _shimmer.value - 60;
                            return Stack(
                              children: [
                                Positioned(
                                  left: x,
                                  top: 0,
                                  bottom: 0,
                                  child: Container(
                                    width: 44,
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          Colors.white.withValues(alpha: 0),
                                          Colors.white.withValues(alpha: 0.16),
                                          Colors.white.withValues(alpha: 0),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          )
        : content;

    return RepaintBoundary(
      child: Semantics(
        button: true,
        enabled: enabled,
        label: widget.text,
        child: GestureDetector(
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
          child: AnimatedScale(
            scale: (!reduceMotion && _pressed) ? 0.96 : 1.0,
            duration: AppTheme.motionFast,
            curve: AppTheme.motionSpring,
            child: AnimatedOpacity(
              opacity: enabled ? 1.0 : 0.55,
              duration: AppTheme.motionBase,
              child: widget.isFilled
                  ? FilledButton(
                      onPressed: enabled ? () => widget.onPressed!() : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: widget.color,
                        foregroundColor: filledContentColor,
                        overlayColor: isDark
                            ? AppTheme.focusRing.withValues(alpha: 0.3)
                            : AppTheme.lightFocusRing.withValues(alpha: 0.3),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: isDark
                                ? AppTheme.focusRing
                                : AppTheme.lightFocusRing,
                            width: 0,
                          ),
                        ),
                        minimumSize: Size(
                          widget.isExpanded ? double.infinity : 0,
                          48,
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                      ),
                      child: effectiveGlow && enabled
                          ? Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: glow.withValues(alpha: 0.4),
                                  width: 1.0,
                                ),
                              ),
                              child: label,
                            )
                          : label,
                    )
                  : OutlinedButton(
                      onPressed: enabled ? () => widget.onPressed!() : null,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: widget.color,
                        overlayColor: isDark
                            ? AppTheme.focusRing.withValues(alpha: 0.3)
                            : AppTheme.lightFocusRing.withValues(alpha: 0.3),
                        side: BorderSide(
                          color: widget.color.withValues(alpha: 0.3),
                          width: 1.0,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        minimumSize: Size(
                          widget.isExpanded ? double.infinity : 0,
                          48,
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                      ),
                      child: effectiveGlow && enabled
                          ? Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: glow.withValues(alpha: 0.4),
                                  width: 1.0,
                                ),
                              ),
                              child: label,
                            )
                          : label,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
