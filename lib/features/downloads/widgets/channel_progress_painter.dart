// FIX-H7: Numeric comparison in shouldRepaint and RepaintBoundary
import 'package:dmx/core/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/services/engine/engine_models.dart';

/// Repaints in isolation — the parent widget never rebuilds on progress ticks.
/// Pass a `ValueListenable<double>` and only the paint() call re-executes.
class ChannelProgressPainter extends CustomPainter {
  final ValueListenable<double> progress;
  final bool isDark;
  final bool isTorrent;
  final List<ChunkDetail> chunkDetails;
  final int chunkFingerprint;

  /// Optional accent color override. When null, falls back to the theme-aware
  /// neonViolet (torrent) / neonBlue (file) defaults.
  final Color? color;

  ChannelProgressPainter({
    required this.progress,
    required this.isDark,
    required this.isTorrent,
    this.chunkDetails = const [],
    this.chunkFingerprint = 0,
    this.color,
  }) : super(repaint: progress); // ← repaints ONLY when value changes

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final rawVal = progress.value;
    final value =
        (rawVal.isNaN || rawVal.isInfinite) ? 0.0 : rawVal.clamp(0.0, 1.0);
    final radius = size.height / 2;

    // Fill color — use caller-supplied color when available so the bar matches the
    // card's status accent (e.g. red for paused, violet for downloading).
    final accent = color ??
        (isTorrent
            ? (isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet)
            : (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue));

    // Neutral, balanced track so any status accent reads clearly in light & dark.
    final trackColor = (isDark ? Colors.white : Colors.black)
        .withValues(alpha: isDark ? 0.08 : 0.07);
    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.fill;

    if (chunkDetails.isNotEmpty) {
      final count = chunkDetails.length;
      final gap = count > 16 ? 1.5 : 2.0;
      final totalSpacing = (count - 1) * gap;
      final segmentWidth = ((size.width - totalSpacing) / count).clamp(
        1.0,
        size.width,
      );
      final segRadius = Radius.circular(
        (size.height / 2).clamp(1.5, segmentWidth / 2),
      );

      final completePaint = Paint()
        ..color = accent
        ..style = PaintingStyle.fill;
      final highlightPaint = Paint()
        ..color = Colors.white.withValues(alpha: isDark ? 0.16 : 0.24)
        ..style = PaintingStyle.fill;

      for (int i = 0; i < count; i++) {
        final chunk = chunkDetails[i];
        final startX = i * (segmentWidth + gap);
        final segRect = Rect.fromLTWH(startX, 0, segmentWidth, size.height);
        final segmentRRect = RRect.fromRectAndRadius(segRect, segRadius);

        // Pending track
        canvas.drawRRect(segmentRRect, trackPaint);

        if (chunk.isIndeterminate) {
          final stripePaint = Paint()
            ..color = accent.withValues(alpha: 0.34)
            ..style = PaintingStyle.fill;
          canvas.save();
          canvas.clipRRect(segmentRRect);
          const stripeWidth = 4.0;
          const stripeGap = 4.0;
          for (double x = startX;
              x < startX + segmentWidth;
              x += stripeWidth + stripeGap) {
            canvas.drawRRect(
              RRect.fromRectAndRadius(
                Rect.fromLTWH(x, 0, stripeWidth, size.height),
                const Radius.circular(1.5),
              ),
              stripePaint,
            );
          }
          canvas.restore();
        } else {
          final ratio = chunk.ratio.clamp(0.0, 1.0);
          final fillWidth = segmentWidth * ratio;
          if (fillWidth <= 0) continue;

          final isDone = chunk.isComplete || ratio >= 0.999;
          final fillRect = Rect.fromLTWH(startX, 0, fillWidth, size.height);
          final fillRRect = RRect.fromRectAndRadius(fillRect, segRadius);

          if (isDone) {
            canvas.drawRRect(fillRRect, completePaint);
          } else {
            // Active chunk: subtle directional gradient for live motion feel
            final activePaint = Paint()
              ..shader = LinearGradient(
                colors: [
                  accent.withValues(alpha: 0.72),
                  accent,
                ],
              ).createShader(fillRect)
              ..style = PaintingStyle.fill;
            canvas.drawRRect(fillRRect, activePaint);

            // Crisp leading glint on active segment
            if (fillWidth > 3.0) {
              canvas.save();
              canvas.clipRRect(fillRRect);
              canvas.drawRect(
                Rect.fromLTWH(
                  startX + fillWidth - 2.0,
                  0,
                  2.0,
                  size.height,
                ),
                highlightPaint,
              );
              canvas.restore();
            }
          }
        }
      }
      return;
    }

    // Continuous track
    final fullRRect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    canvas.drawRRect(fullRRect, trackPaint);

    if (value > 0.0) {
      final fillWidth = (size.width * value).clamp(size.height, size.width);
      final fillRect = Rect.fromLTWH(0, 0, fillWidth, size.height);
      final isActive = value > 0.02 && value < 0.995;

      final fillPaint = Paint()
        ..shader = LinearGradient(
          colors: isActive
              ? [
                  accent.withValues(alpha: 0.72),
                  accent,
                  Color.lerp(accent, Colors.white, isDark ? 0.25 : 0.18) ??
                      accent,
                ]
              : [
                  accent.withValues(alpha: 0.85),
                  accent,
                ],
          stops: isActive ? const [0.0, 0.82, 1.0] : const [0.0, 1.0],
        ).createShader(fillRect)
        ..style = PaintingStyle.fill;

      canvas.save();
      canvas.clipRRect(fullRRect);
      canvas.drawRRect(
        RRect.fromRectAndRadius(fillRect, Radius.circular(radius)),
        fillPaint,
      );
      canvas.restore();

      // Subtle leading highlight dot (zero GPU blur overhead)
      if (isActive) {
        final tipX = (size.width * value).clamp(radius, size.width - radius);
        final tipCenter = Offset(tipX, size.height / 2);
        final haloPaint = Paint()
          ..color = accent.withValues(alpha: isDark ? 0.30 : 0.22)
          ..style = PaintingStyle.fill;
        final corePaint = Paint()
          ..color =
              Color.lerp(accent, Colors.white, isDark ? 0.55 : 0.35) ?? accent
          ..style = PaintingStyle.fill;

        canvas.drawCircle(tipCenter, size.height * 0.52, haloPaint);
        canvas.drawCircle(tipCenter, size.height * 0.28, corePaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant ChannelProgressPainter oldDelegate) {
    // FIX-P0-5: When the chunk fingerprint is unchanged the chunk set is
    // byte-identical, so skip the per-chunk diff loop entirely.
    if (oldDelegate.chunkFingerprint == chunkFingerprint &&
        chunkFingerprint != 0) {
      return (oldDelegate.progress.value - progress.value).abs() > 0.001 ||
          oldDelegate.progress != progress ||
          oldDelegate.isDark != isDark ||
          oldDelegate.isTorrent != isTorrent ||
          oldDelegate.color != color;
    }
    if (oldDelegate.chunkDetails.length != chunkDetails.length) return true;
    for (int i = 0; i < chunkDetails.length; i++) {
      if (oldDelegate.chunkDetails[i].downloaded !=
              chunkDetails[i].downloaded ||
          oldDelegate.chunkDetails[i].isComplete !=
              chunkDetails[i].isComplete) {
        return true;
      }
    }
    return (oldDelegate.progress.value - progress.value).abs() > 0.001 ||
        oldDelegate.progress != progress ||
        oldDelegate.isDark != isDark ||
        oldDelegate.isTorrent != isTorrent ||
        oldDelegate.color != color;
  }
}

/// Usage wrapper — parent builds ONCE; painter repaints on ticks.
class IsolatedProgressBar extends StatelessWidget {
  final ValueListenable<double> progress;
  final bool isDark;
  final bool isTorrent;
  final double height;
  final int chunkFingerprint;

  /// Optional accent color override forwarded to [ChannelProgressPainter].
  final Color? color;

  const IsolatedProgressBar({
    super.key,
    required this.progress,
    required this.isDark,
    this.isTorrent = false,
    this.height = 6,
    this.chunkFingerprint = 0,
    this.color,
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
            width: double.infinity,
            child: CustomPaint(
              painter: ChannelProgressPainter(
                progress: progress,
                isDark: isDark,
                isTorrent: isTorrent,
                chunkFingerprint: chunkFingerprint,
                color: color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
