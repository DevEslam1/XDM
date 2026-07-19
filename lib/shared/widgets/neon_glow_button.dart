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
    this.hasGlow = true,
    this.isExpanded = false,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<SettingsProvider>(context, listen: false).isDarkMode;
    final effectiveGlowColor = glowColor ?? color;
    final glassBgColor = isDark ? AppTheme.glassBg : AppTheme.lightGlassBg;

    // For filled buttons, use a contrast color for text/icons
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
          text.toUpperCase(),
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: isFilled ? filledContentColor : color,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
            fontSize: 13,
          ),
        ),
      ],
    );

    if (isExpanded) {
      buttonContent = Center(child: buttonContent);
    }

    const double height = 48.0;

    final effectiveOnPressed = isLoading ? null : onPressed;

    return Opacity(
      opacity: effectiveOnPressed != null ? 1.0 : 0.5,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Container(
          height: height,
          width: isExpanded ? double.infinity : null,
          decoration: BoxDecoration(
            gradient: isFilled
                ? LinearGradient(
                    colors: [
                      color,
                      Color.lerp(color, Colors.white, 0.15)!,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            color: isFilled ? null : glassBgColor,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isFilled
                  ? color.withValues(alpha: 0.4)
                  : color.withValues(alpha: 0.3),
              width: 1.0,
            ),
            boxShadow: (hasGlow && effectiveOnPressed != null && isDark)
                ? [
                    BoxShadow(
                      color: effectiveGlowColor.withValues(alpha: 0.2),
                      blurRadius: 14.0,
                      spreadRadius: 0,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: effectiveOnPressed,
              overlayColor: WidgetStateProperty.all(
                isFilled
                    ? Colors.white.withValues(alpha: 0.15)
                    : color.withValues(alpha: 0.12),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: buttonContent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
