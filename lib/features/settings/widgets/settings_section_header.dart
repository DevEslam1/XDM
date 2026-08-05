import 'package:flutter/material.dart';
import '../../../core/app_theme.dart';

class SettingsSectionHeader extends StatelessWidget {
  final String title;
  final Color? accentColor;
  final bool isDark;
  final EdgeInsetsGeometry padding;

  const SettingsSectionHeader({
    super.key,
    required this.title,
    this.accentColor,
    required this.isDark,
    this.padding = const EdgeInsets.only(top: 16, bottom: 8, left: 4, right: 4),
  });

  @override
  Widget build(BuildContext context) {
    final accent = accentColor ?? (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue);
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Container(
            width: 3,
            height: 12,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(2),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: 0.5),
                  blurRadius: 4,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
              fontFamily: 'Space Grotesk',
              color: accent,
            ),
          ),
        ],
      ),
    );
  }
}
