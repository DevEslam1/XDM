import 'package:flutter/material.dart';

/// Performance-optimized corner bracket frame with RepaintBoundary isolation.
class CornerBracketFrame extends StatelessWidget {
  final Widget child;
  final Color color;
  final double bracketSize;
  final double strokeWidth;
  final double borderRadius;
  final EdgeInsetsGeometry padding;

  const CornerBracketFrame({
    super.key,
    required this.child,
    this.color = const Color(0xFF00E5FF),
    this.bracketSize = 12.0,
    this.strokeWidth = 1.5,
    this.borderRadius = 8.0,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        foregroundPainter: _CornerBracketPainter(
          color: color,
          bracketSize: bracketSize,
          strokeWidth: strokeWidth,
          borderRadius: borderRadius,
        ),
        child: Padding(
          padding: padding,
          child: child,
        ),
      ),
    );
  }
}

class _CornerBracketPainter extends CustomPainter {
  final Color color;
  final double bracketSize;
  final double strokeWidth;
  final double borderRadius;

  const _CornerBracketPainter({
    required this.color,
    required this.bracketSize,
    required this.strokeWidth,
    required this.borderRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final w = size.width;
    final h = size.height;
    final b = bracketSize.clamp(0.0, w / 2);

    // Top-Left
    canvas.drawLine(Offset(borderRadius, 0), Offset(b, 0), paint);
    canvas.drawLine(Offset(0, borderRadius), Offset(0, b), paint);

    // Top-Right
    canvas.drawLine(Offset(w - b, 0), Offset(w - borderRadius, 0), paint);
    canvas.drawLine(Offset(w, borderRadius), Offset(w, b), paint);

    // Bottom-Left
    canvas.drawLine(Offset(borderRadius, h), Offset(b, h), paint);
    canvas.drawLine(Offset(0, h - b), Offset(0, h - borderRadius), paint);

    // Bottom-Right
    canvas.drawLine(Offset(w - b, h), Offset(w - borderRadius, h), paint);
    canvas.drawLine(Offset(w, h - b), Offset(w, h - borderRadius), paint);
  }

  @override
  bool? hitTest(Offset position) => false;

  @override
  bool shouldRepaint(covariant _CornerBracketPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.bracketSize != bracketSize ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.borderRadius != borderRadius;
  }
}
