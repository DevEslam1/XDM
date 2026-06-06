import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/app_theme.dart';
import '../../features/settings/provider/settings_provider.dart';

class DmxAppIcon extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final isDark = settings.isDarkMode;
    final accentClr = customColor ?? (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: (isDark ? AppTheme.background : AppTheme.lightBackground).withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(size * 0.28),
        border: Border.all(
          color: accentClr.withValues(alpha: 0.85),
          width: size * 0.035, // Responsive border thickness
        ),
        boxShadow: (isDark && showGlow && settings.enableGlow)
            ? [
                BoxShadow(
                  color: accentClr.withValues(alpha: 0.35),
                  blurRadius: size * 0.3,
                  spreadRadius: 1.0,
                ),
              ]
            : null,
      ),
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(size * 0.23),
          child: Image.asset(
            'assets/app_icon/icon.png',
            fit: BoxFit.cover,
            width: size * 0.88,
            height: size * 0.88,
            errorBuilder: (context, error, stackTrace) {
              return Text(
                'X',
                style: TextStyle(
                  fontFamily: 'Space Grotesk',
                  fontSize: size * 0.52,
                  fontWeight: FontWeight.bold,
                  color: accentClr,
                  letterSpacing: 0,
                  shadows: (isDark && showGlow && settings.enableGlow)
                      ? [
                          Shadow(
                            color: accentClr.withValues(alpha: 0.8),
                            blurRadius: size * 0.15,
                          ),
                        ]
                      : null,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
