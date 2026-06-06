import 'dart:math';
import 'package:flutter/material.dart';
import '../../../../core/app_theme.dart';
import '../../../../shared/widgets/dmx_backdrop_filter.dart';

class CircularProgressWidget extends StatelessWidget {
  final double progress; // 0.0 to 1.0
  final String speedText;
  final String etaText;
  final Color accentColor;

  const CircularProgressWidget({
    super.key,
    required this.progress,
    required this.speedText,
    required this.etaText,
    this.accentColor = AppTheme.neonBlue,
  });

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: DmxBackdropFilter(
        sigmaX: 10,
        sigmaY: 10,
        child: Container(
          width: 220,
          height: 220,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: accentColor.withValues(alpha: 0.06),
            border: Border.all(color: AppTheme.glassBorder, width: 1.2),
            boxShadow: [
              BoxShadow(
                color: accentColor.withValues(alpha: 0.08),
                blurRadius: 24.0,
                spreadRadius: 0.0,
              ),
            ],
          ),
          child: Stack(
            children: [
              // Circular progress ring painter
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: CustomPaint(
                    painter: _CircularProgressPainter(
                      progress: progress,
                      accentColor: accentColor,
                    ),
                  ),
                ),
              ),
              // Inside labels
              Positioned.fill(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '${(progress * 100).toStringAsFixed(1)}%',
                        style: Theme.of(context).textTheme.displayLarge?.copyWith(
                          fontSize: 36,
                          color: AppTheme.textPrimary,
                          letterSpacing: -1.0,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.glassBg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: accentColor.withValues(alpha: 0.2),
                            width: 0.8,
                          ),
                        ),
                        child: Text(
                          speedText,
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: accentColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        etaText,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CircularProgressPainter extends CustomPainter {
  final double progress;
  final Color accentColor;

  _CircularProgressPainter({required this.progress, required this.accentColor});

  @override
  void paint(Canvas canvas, Size size) {
    final double radius = min(size.width / 2, size.height / 2);
    final Offset center = Offset(size.width / 2, size.height / 2);

    // 1. Background track paint
    final trackPaint = Paint()
      ..color = AppTheme.border.withValues(alpha: 0.4)
      ..strokeWidth = 6.0
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, radius - 6.0, trackPaint);

    // 2. Glowing active arc paint
    final activePaint = Paint()
      ..color = accentColor
      ..strokeWidth = 7.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final double sweepAngle = 2 * pi * progress;
    final double startAngle = -pi / 2; // Start from top

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - 6.0),
      startAngle,
      sweepAngle,
      false,
      activePaint,
    );

    // 3. Faint tick marks inside the circle for technical aesthetics
    final tickPaint = Paint()
      ..color = AppTheme.border.withValues(alpha: 0.5)
      ..strokeWidth = 1.0;

    const int tickCount = 24;
    for (int i = 0; i < tickCount; i++) {
      final double tickAngle = i * (2 * pi / tickCount);
      final double innerR = radius - 18.0;
      final double outerR = radius - 14.0;

      final Offset startPoint = Offset(
        center.dx + innerR * cos(tickAngle),
        center.dy + innerR * sin(tickAngle),
      );
      final Offset endPoint = Offset(
        center.dx + outerR * cos(tickAngle),
        center.dy + outerR * sin(tickAngle),
      );
      canvas.drawLine(startPoint, endPoint, tickPaint);
    }

    // 4. Glowing leading indicator dot at the end of progress arc
    if (progress > 0.0 && progress < 1.0) {
      final double currentAngle = startAngle + sweepAngle;
      final Offset indicatorPos = Offset(
        center.dx + (radius - 6.0) * cos(currentAngle),
        center.dy + (radius - 6.0) * sin(currentAngle),
      );

      final dotGlow = Paint()
        ..color = accentColor.withValues(alpha: 0.5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6.0);
      canvas.drawCircle(indicatorPos, 8.0, dotGlow);

      final dotPaint = Paint()..color = Colors.white;
      canvas.drawCircle(indicatorPos, 4.0, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _CircularProgressPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.accentColor != accentColor;
  }
}
