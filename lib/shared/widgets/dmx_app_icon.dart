import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/app_theme.dart';
import '../../features/settings/provider/settings_provider.dart';

class DmxAppIcon extends StatefulWidget {
  final double size;
  final bool showGlow;
  final Color? customColor;
  const DmxAppIcon({
    super.key,
    this.size = 64,
    this.showGlow = true,
    this.customColor,
  });

  @override
  State<DmxAppIcon> createState() => _DmxAppIconState();
}

class _DmxAppIconState extends State<DmxAppIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ring;

  @override
  void initState() {
    super.initState();
    _ring = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
  }

  @override
  void dispose() {
    _ring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final isDark = settings.isDarkMode;
    final accentClr =
        widget.customColor ??
        (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue);
    final glowOn = isDark && widget.showGlow && settings.enableGlow;

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Rotating dashed status ring
          if (glowOn)
            AnimatedBuilder(
              animation: _ring,
              builder: (context, _) {
                return Transform.rotate(
                  angle: _ring.value * 2 * 3.14159,
                  child: CustomPaint(
                    size: Size.square(widget.size),
                    painter: _DashRingPainter(color: accentClr),
                  ),
                );
              },
            ),
          Container(
            width: widget.size * 0.86,
            height: widget.size * 0.86,
            decoration: BoxDecoration(
              color: (isDark ? AppTheme.background : AppTheme.lightBackground)
                  .withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(widget.size * 0.26),
              border: Border.all(
                color: accentClr.withValues(alpha: 0.85),
                width: widget.size * 0.035,
              ),
              boxShadow: glowOn
                  ? [
                      BoxShadow(
                        color: accentClr.withValues(alpha: 0.35),
                        blurRadius: widget.size * 0.3,
                        spreadRadius: 1.0,
                      ),
                    ]
                  : null,
            ),
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(widget.size * 0.21),
                child: Image.asset(
                  'assets/app_icon/icon.png',
                  fit: BoxFit.cover,
                  width: widget.size * 0.74,
                  height: widget.size * 0.74,
                  errorBuilder: (context, error, stackTrace) {
                    return Text(
                      'X',
                      style: TextStyle(
                        fontFamily: 'Space Grotesk',
                        fontSize: widget.size * 0.46,
                        fontWeight: FontWeight.bold,
                        color: accentClr,
                        shadows: glowOn
                            ? [
                                Shadow(
                                  color: accentClr.withValues(alpha: 0.8),
                                  blurRadius: widget.size * 0.15,
                                ),
                              ]
                            : null,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DashRingPainter extends CustomPainter {
  final Color color;
  final Paint _paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.4;

  _DashRingPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 1.5;
    _paint.color = color.withValues(alpha: 0.45);

    const dashes = 28;
    const gapRatio = 0.45;
    const step = (2 * 3.141592653589793) / dashes;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final path = Path();
    for (var i = 0; i < dashes; i++) {
      final start = i * step;
      final sweep = step * (1 - gapRatio);
      path.addArc(rect, start, sweep);
    }
    canvas.drawPath(path, _paint);
  }

  @override
  bool shouldRepaint(covariant _DashRingPainter old) => old.color != color;
}
