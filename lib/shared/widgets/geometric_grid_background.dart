import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/app_theme.dart';
import '../../features/settings/provider/settings_provider.dart';

class GeometricGridBackground extends StatelessWidget {
  final Widget child;

  const GeometricGridBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final isDark = settings.isDarkMode;
    final bgColor = isDark ? AppTheme.background : AppTheme.lightBackground;
    final violetClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
    final blueClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;

    if (settings.classicUi) {
      return Container(
        color: bgColor,
        child: child,
      );
    }

    // Reduce gradient intensity in light mode for subtlety
    final double blobAlpha1 = isDark ? 0.10 : 0.06;
    final double blobAlpha2 = isDark ? 0.03 : 0.015;
    final double blobAlpha3 = isDark ? 0.08 : 0.05;
    final double blobAlpha4 = isDark ? 0.02 : 0.01;
    final double blobAlpha5 = isDark ? 0.05 : 0.03;
    final double blobAlpha6 = isDark ? 0.01 : 0.005;
    final double centerAlpha = isDark ? 0.04 : 0.02;

    return Stack(
      children: [
        // Base container
        Positioned.fill(child: Container(color: bgColor)),

        // Soft mesh gradient blob — top-left violet
        Positioned(
          top: -120,
          left: -80,
          child: Container(
            width: 400,
            height: 400,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  violetClr.withValues(alpha: blobAlpha1),
                  violetClr.withValues(alpha: blobAlpha2),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.4, 1.0],
                radius: 0.7,
              ),
            ),
          ),
        ),

        // Soft mesh gradient blob — center-right blue
        Positioned(
          top: MediaQuery.of(context).size.height * 0.35,
          right: -100,
          child: Container(
            width: 350,
            height: 350,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  blueClr.withValues(alpha: blobAlpha3),
                  blueClr.withValues(alpha: blobAlpha4),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.4, 1.0],
                radius: 0.7,
              ),
            ),
          ),
        ),

        // Soft mesh gradient blob — bottom-left green
        Positioned(
          bottom: -150,
          left: -60,
          child: Container(
            width: 320,
            height: 320,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  greenClr.withValues(alpha: blobAlpha5),
                  greenClr.withValues(alpha: blobAlpha6),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.4, 1.0],
                radius: 0.7,
              ),
            ),
          ),
        ),

        // Subtle ambient center glow
        Positioned(
          top: MediaQuery.of(context).size.height * 0.15,
          left: MediaQuery.of(context).size.width * 0.2,
          child: Container(
            width: 250,
            height: 250,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  violetClr.withValues(alpha: centerAlpha),
                  Colors.transparent,
                ],
                radius: 0.6,
              ),
            ),
          ),
        ),

        // The screen content
        Positioned.fill(child: child),
      ],
    );
  }
}
