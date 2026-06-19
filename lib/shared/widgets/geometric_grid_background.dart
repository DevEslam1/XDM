import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/app_theme.dart';
import '../../features/settings/provider/settings_provider.dart';

class GeometricGridBackground extends StatelessWidget {
  final Widget child;

  const GeometricGridBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final bgColor = isDark ? AppTheme.background : AppTheme.lightBackground;

    if (settings.classicUi) {
      return Container(color: bgColor, child: child);
    }

    final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;

    final double blobAlpha = isDark ? 0.08 : 0.04;

    return Stack(
      children: [
        Positioned.fill(child: Container(color: bgColor)),
        Positioned(top: -120, left: -80, child: _Blob(size: 400, color: violetClr, alpha: blobAlpha)),
        Positioned(right: -100, child: _Blob(size: 350, color: blueClr, alpha: blobAlpha * 0.8)),
        Positioned(bottom: -150, left: -60, child: _Blob(size: 320, color: greenClr, alpha: blobAlpha * 0.6)),
        Positioned.fill(child: child),
      ],
    );
  }
}

class _Blob extends StatelessWidget {
  final double size;
  final Color color;
  final double alpha;

  const _Blob({required this.size, required this.color, required this.alpha});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            color.withValues(alpha: alpha),
            color.withValues(alpha: alpha * 0.3),
            Colors.transparent,
          ],
          stops: const [0.0, 0.4, 1.0],
          radius: 0.7,
        ),
      ),
    );
  }
}