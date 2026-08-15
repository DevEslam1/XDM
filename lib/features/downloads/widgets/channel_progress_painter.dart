// FIX-H7: Numeric comparison in shouldRepaint and RepaintBoundary
import 'package:dmx/core/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Repaints in isolation — the parent widget never rebuilds on progress ticks.
/// Pass a `ValueListenable<double>` and only the paint() call re-executes.
class ChannelProgressPainter extends CustomPainter {
  final ValueListenable<double> progress;
  final bool isDark;
  final bool isTorrent;

  ChannelProgressPainter({
    required this.progress,
    required this.isDark,
    required this.isTorrent,
  }) : super(repaint: progress); // ← repaints ONLY when value changes

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width == 0) return;
    if (size.width <= 0 || size.height <= 0) return;
    final rawVal = progress.value;
    final value =
        (rawVal.isNaN || rawVal.isInfinite) ? 0.0 : rawVal.clamp(0.0, 1.0);
    final radius = size.height / 2;

    // Track
    final trackPaint = Paint()
      ..color = (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue)
          .withValues(alpha: isDark ? 0.15 : 0.12)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      trackPaint,
    );

    // Fill
    final accent = isTorrent ? AppTheme.neonViolet : AppTheme.neonBlue;
    if (value > 0.0) {
      final fillPaint = Paint()
        ..shader = LinearGradient(colors: [
          accent.withValues(alpha: 0.7),
          accent,
        ]).createShader(Rect.fromLTWH(0, 0, size.width * value, size.height))
        ..style = PaintingStyle.fill;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width * value, size.height),
          Radius.circular(radius),
        ),
        fillPaint,
      );
    }

    // Leading dot (crisp solid fill without GPU blur filter overhead)
    if (value > 0.02 && value < 0.99) {
      final dotPaint = Paint()
        ..color = accent
        ..style = PaintingStyle.fill;
      canvas.drawCircle(
        Offset(size.width * value, size.height / 2),
        size.height / 2.4,
        dotPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant ChannelProgressPainter old) {
    // FIX-H7: Compare progress.value numerically with epsilon = 0.001
    return (old.progress.value - progress.value).abs() > 0.001 ||
        old.isDark != isDark ||
        old.isTorrent != isTorrent;
  }
}

/// Usage wrapper — parent builds ONCE; painter repaints on ticks.
class IsolatedProgressBar extends StatelessWidget {
  final ValueListenable<double> progress;
  final bool isDark;
  final bool isTorrent;
  final double height;

  const IsolatedProgressBar({
    super.key,
    required this.progress,
    required this.isDark,
    this.isTorrent = false,
    this.height = 6,
  });

  @override
  Widget build(BuildContext context) {
    // FIX-H7: Wrap IsolatedProgressBar in a RepaintBoundary widget
    return RepaintBoundary(
      child: ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (context, val, child) {
          final pct = (val.clamp(0.0, 1.0) * 100).round();
          return Semantics(
            label: 'Download progress',
            value: '$pct%',
            child: child,
          );
        },
        child: RepaintBoundary(
          child: SizedBox(
            height: height,
            child: CustomPaint(
              painter: ChannelProgressPainter(
                progress: progress,
                isDark: isDark,
                isTorrent: isTorrent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
