import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:dmx/core/app_theme.dart';

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
    final value = progress.value.clamp(0.0, 1.0);
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

    // Leading glow dot
    if (value > 0.02 && value < 0.99) {
      final glow = Paint()
        ..color = accent.withValues(alpha: 0.9)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      canvas.drawCircle(
        Offset(size.width * value, size.height / 2),
        size.height / 2.4,
        glow,
      );
    }
  }

  @override
  bool shouldRepaint(covariant ChannelProgressPainter old) =>
      old.progress != progress ||
      old.isDark != isDark ||
      old.isTorrent != isTorrent;
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
    return RepaintBoundary(
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
    );
  }
}
