import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/app_theme.dart';
import '../../features/settings/provider/settings_provider.dart';

class NeonGlowButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String text;
  final IconData? icon;
  final Color color;
  final Color? glowColor;
  final bool isFilled;
  final bool hasGlow;
  final bool isExpanded;
  final bool isLoading;

  const NeonGlowButton({
    super.key,
    required this.onPressed,
    required this.text,
    this.icon,
    this.color = AppTheme.neonBlue,
    this.glowColor,
    this.isFilled = false,
    this.hasGlow = false,
    this.isExpanded = false,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<SettingsProvider>(context, listen: false).isDarkMode;
    final filledContentColor = isDark ? AppTheme.background : AppTheme.lightBackground;

    Widget buttonContent = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (isLoading) ...[
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(
                isFilled ? filledContentColor : color,
              ),
            ),
          ),
          const SizedBox(width: 8),
        ] else if (icon != null) ...[
          Icon(icon, size: 18, color: isFilled ? filledContentColor : color),
          const SizedBox(width: 8),
        ],
        Text(
          text,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: isFilled ? filledContentColor : color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );

    if (isExpanded) {
      buttonContent = Center(child: buttonContent);
    }

    final effectiveOnPressed = isLoading ? null : onPressed;

    if (isFilled) {
      return FilledButton(
        onPressed: effectiveOnPressed,
        style: FilledButton.styleFrom(
          backgroundColor: color,
          foregroundColor: filledContentColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          minimumSize: Size(isExpanded ? double.infinity : 0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 24),
        ),
        child: buttonContent,
      );
    } else {
      return OutlinedButton(
        onPressed: effectiveOnPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: color.withValues(alpha: 0.3), width: 1.0),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          minimumSize: Size(isExpanded ? double.infinity : 0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 24),
        ),
        child: buttonContent,
      );
    }
  }
}
