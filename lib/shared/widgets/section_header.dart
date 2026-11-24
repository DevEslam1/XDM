import 'package:material_ui/material_ui.dart';
import '../../core/app_theme.dart';
import '../design/dmx_tokens.dart';

/// A reusable, polished section header with accent indicator and consistent
/// typography.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? accentColor;
  final Widget? trailing;
  final bool isDark;
  final EdgeInsets padding;

  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.accentColor,
    this.trailing,
    required this.isDark,
    this.padding = const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
  });

  @override
  Widget build(BuildContext context) {
    final accent =
        accentColor ?? (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue);
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    final textSecondary = AppTheme.textSecondaryOf(isDark);

    return Padding(
      padding: padding,
      child: Semantics(
        header: true,
        label: title,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 3,
                height: subtitle != null ? 24 : 16,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              if (icon != null) ...[
                Icon(icon, size: 16, color: accent),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                        fontFamily: AppTheme.fontDisplay,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: textSecondary,
                          fontSize: 11.5,
                          fontFamily: AppTheme.fontBody,
                          fontWeight: FontWeight.w400,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A reusable settings card container with crisp hairline border and consistent
/// light/dark/AMOLED styling.
class SettingsCard extends StatelessWidget {
  final List<Widget> children;
  final bool isDark;
  final bool isAmoled;
  final EdgeInsets margin;
  final double borderRadius;

  const SettingsCard({
    super.key,
    required this.children,
    required this.isDark,
    this.isAmoled = false,
    this.margin = EdgeInsets.zero,
    this.borderRadius = 16,
  });

  @override
  Widget build(BuildContext context) {
    final cardClr = AppTheme.surfaceColor(isDark, isAmoled: isAmoled);
    final borderClr = AppTheme.hairlineBorder(isDark, isAmoled: isAmoled);

    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: cardClr,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: borderClr, width: 0.8),
        boxShadow: AppTheme.cardShadow(isDark),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}

/// A reusable drag handle for bottom sheets.
class DragHandle extends StatelessWidget {
  final Color? color;
  final double width;
  final double height;

  const DragHandle({
    super.key,
    this.color,
    this.width = DmxTokens.dragHandleWidth,
    this.height = DmxTokens.dragHandleHeight,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final resolvedColor = color ??
        (isDark
            ? AppTheme.borderStrong.withValues(alpha: 0.9)
            : AppTheme.lightBorderStrong);

    return ExcludeSemantics(
      child: Center(
        child: Container(
          width: width,
          height: height,
          margin: const EdgeInsets.only(top: 10, bottom: 8),
          decoration: BoxDecoration(
            color: resolvedColor,
            borderRadius: BorderRadius.circular(height / 2),
          ),
        ),
      ),
    );
  }
}

/// A polished empty state widget with icon, title, subtitle, and optional CTA.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Color? accentColor;
  final bool isDark;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.accentColor,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final accent =
        accentColor ?? (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    final badge = Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [
            accent.withValues(alpha: isDark ? 0.18 : 0.12),
            accent.withValues(alpha: isDark ? 0.05 : 0.03),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: accent.withValues(alpha: isDark ? 0.25 : 0.20),
          width: 1.0,
        ),
      ),
      child: Icon(icon, size: 36, color: accent),
    );

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28.0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (reduceMotion)
                badge
              else
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0.9, end: 1.0),
                  duration: AppTheme.motionSlow,
                  curve: AppTheme.motionCurve,
                  builder: (context, value, child) =>
                      Transform.scale(scale: value, child: child),
                  child: badge,
                ),
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppTheme.textPrimaryOf(isDark),
                  fontFamily: AppTheme.fontDisplay,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  letterSpacing: -0.1,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  subtitle!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppTheme.textSecondaryOf(isDark),
                    fontFamily: AppTheme.fontBody,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ],
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: onAction,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: Text(
                    actionLabel!,
                    style: const TextStyle(
                      fontFamily: AppTheme.fontDisplay,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: AppTheme.inkOn(accent),
                    elevation: 0,
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
