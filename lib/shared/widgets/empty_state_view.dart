import 'package:material_ui/material_ui.dart';
import '../../core/app_theme.dart';

/// Reusable empty-state placeholder view with crisp icon badge, balanced
/// typography, and optional call-to-action.
class EmptyStateView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;
  final Color? accentColor;
  final bool compact;

  const EmptyStateView({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
    this.accentColor,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = AppTheme.textPrimaryOf(isDark);
    final secondaryColor = AppTheme.textSecondaryOf(isDark);
    final accent =
        accentColor ?? (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue);

    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 24.0,
          vertical: compact ? 20.0 : 32.0,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: compact ? 56 : 72,
                height: compact ? 56 : 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      accent.withValues(alpha: isDark ? 0.16 : 0.12),
                      accent.withValues(alpha: isDark ? 0.05 : 0.04),
                    ],
                  ),
                  border: Border.all(
                    color: accent.withValues(alpha: isDark ? 0.24 : 0.20),
                    width: 1.0,
                  ),
                ),
                child: Icon(
                  icon,
                  size: compact ? 26 : 34,
                  color: accent,
                ),
              ),
              SizedBox(height: compact ? 12 : 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: compact ? 15 : 16,
                  fontWeight: FontWeight.w700,
                  fontFamily: AppTheme.fontDisplay,
                  letterSpacing: -0.1,
                  color: primaryColor,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  subtitle!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    fontFamily: AppTheme.fontBody,
                    color: secondaryColor,
                  ),
                ),
              ],
              if (action != null) ...[
                SizedBox(height: compact ? 16 : 20),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
