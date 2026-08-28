import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/app_theme.dart';
import '../../core/utils/localization.dart';
import '../../features/downloads/models/download_task.dart';
import '../../features/settings/provider/settings_provider.dart';
import '../widgets/dmx_backdrop_filter.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Status Colors Mapping
// ─────────────────────────────────────────────────────────────────────────────
class DmxStatusColors {
  DmxStatusColors._();

  static Color of(DownloadStatus status, bool isDark) {
    return switch (status) {
      DownloadStatus.queued =>
        isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
      DownloadStatus.downloading =>
        isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
      DownloadStatus.paused =>
        isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
      DownloadStatus.completed =>
        isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
      DownloadStatus.failed =>
        isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
      DownloadStatus.merging =>
        isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber, // FIX-B11
    };
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Card Shell
// ─────────────────────────────────────────────────────────────────────────────
class DmxCardShell extends StatelessWidget {
  final Widget child;
  final Color? accent;
  final double radius;
  final bool showRail;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const DmxCardShell({
    super.key,
    required this.child,
    this.accent,
    this.radius = 16,
    this.showRail = true,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    SettingsProvider settings;
    try {
      settings = context.watch<SettingsProvider>();
    } catch (_) {
      settings = SettingsProvider.instance;
    }
    final classicUi = settings.classicUi;
    final isDark = settings.isDarkMode;
    final glow = settings.enableGlow;

    final backgroundColor = classicUi
        ? (isDark ? AppTheme.surface : AppTheme.lightSurface)
        : (isDark
            ? AppTheme.surface.withValues(alpha: 0.4)
            : AppTheme.lightSurface.withValues(alpha: 0.4));

    final resolvedAccent = accent ?? AppTheme.neonBlue;
    final Widget content = Container(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: glow
              ? resolvedAccent.withValues(alpha: isDark ? 0.24 : 0.28)
              : (isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle),
          width: 1,
        ),
        boxShadow: [
          if (glow)
            BoxShadow(
              color: resolvedAccent.withValues(alpha: isDark ? 0.08 : 0.04),
              blurRadius: 16,
              spreadRadius: 1,
              offset: const Offset(0, 4),
            )
          else
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.03),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: !showRail
            ? child
            : Stack(
                children: [
                  child,
                  Positioned.directional(
                    textDirection: Directionality.of(context),
                    start: 0,
                    top: 0,
                    bottom: 0,
                    width: 3.5,
                    child: Container(
                      decoration: BoxDecoration(
                        color: resolvedAccent,
                        borderRadius: BorderRadiusDirectional.only(
                          topStart: Radius.circular(radius),
                          bottomStart: Radius.circular(radius),
                        ),
                        boxShadow: [
                          AppTheme.glow(resolvedAccent,
                              alpha: 0.30, blur: 6, spread: 0),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(radius),
        child: content,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Divider
// ─────────────────────────────────────────────────────────────────────────────
class DmxDivider extends StatelessWidget {
  final double height;
  final double indent;
  final double endIndent;

  const DmxDivider({
    super.key,
    this.height = 1,
    this.indent = 16,
    this.endIndent = 16,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<SettingsProvider>().isDarkMode;
    return Divider(
      height: height,
      thickness: 1,
      color: isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle,
      indent: indent,
      endIndent: endIndent,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Section Header
// ─────────────────────────────────────────────────────────────────────────────
class DmxSectionHeader extends StatelessWidget {
  final String title;
  final Color? accentColor;
  final bool isDark;
  final EdgeInsetsGeometry padding;
  final Widget? trailing;

  const DmxSectionHeader({
    super.key,
    required this.title,
    this.accentColor,
    required this.isDark,
    this.padding = const EdgeInsets.only(top: 16, bottom: 8, left: 4, right: 4),
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final accent =
        accentColor ?? (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue);
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
          Expanded(
            child: Text(
              title.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
                fontFamily: 'Space Grotesk',
                color: accent,
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Section Group (Card wrapper around grouped list tiles)
// ─────────────────────────────────────────────────────────────────────────────
class DmxSectionGroup extends StatelessWidget {
  final List<Widget> children;
  final Color? accentColor;

  const DmxSectionGroup({
    super.key,
    required this.children,
    this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final classicUi = settings.classicUi;
    final isDark = settings.isDarkMode;
    final glow = settings.enableGlow && accentColor != null;

    final backgroundColor = classicUi
        ? (isDark ? AppTheme.surface : AppTheme.lightSurface)
        : (isDark
            ? AppTheme.surface.withValues(alpha: 0.4)
            : AppTheme.lightSurface.withValues(alpha: 0.4));

    Widget content = Material(
      color: backgroundColor,
      child: Column(
        children: List.generate(children.length, (index) {
          final child = children[index];
          if (index == children.length - 1) return child;
          return Column(
            children: [
              child,
              const DmxDivider(indent: 16, endIndent: 16),
            ],
          );
        }),
      ),
    );

    if (!classicUi) {
      content = DmxBackdropFilter(
        sigmaX: 12,
        sigmaY: 12,
        child: content,
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: glow
              ? accentColor!.withValues(alpha: isDark ? 0.24 : 0.28)
              : (isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle),
          width: 1,
        ),
        boxShadow: [
          if (glow)
            BoxShadow(
              color: accentColor!.withValues(alpha: isDark ? 0.08 : 0.04),
              blurRadius: 16,
              spreadRadius: 1,
              offset: const Offset(0, 4),
            )
          else
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.03),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: content,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unified Dialog Base
// ─────────────────────────────────────────────────────────────────────────────
class DmxDialog extends StatelessWidget {
  final String title;
  final Widget content;
  final List<Widget>? actions;
  final Color? accentColor;
  final IconData? icon;

  const DmxDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions,
    this.accentColor,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final accent =
        accentColor ?? (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;

    final screenHeight = MediaQuery.sizeOf(context).height;
    final Widget dialogContent = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 560,
        maxHeight: screenHeight * 0.75,
      ),
      child: DmxCardShell(
        accent: accent,
        radius: 20,
        showRail: false,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (icon != null) ...[
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(icon, color: accent, size: 20),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontFamily: 'Space Grotesk',
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: textClr,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Flexible(child: SingleChildScrollView(child: content)),
              if (actions != null && actions!.isNotEmpty) ...[
                const SizedBox(height: 20),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: actions!,
                ),
              ],
            ],
          ),
        ),
      ),
    );

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Directionality(
        textDirection:
            L10n.isRtl(context) ? TextDirection.rtl : TextDirection.ltr,
        child: dialogContent,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unified Confirmation Dialog
// ─────────────────────────────────────────────────────────────────────────────
class DmxConfirmDialog extends StatelessWidget {
  final String title;
  final String message;
  final String? confirmLabel;
  final String? cancelLabel;
  final bool isDestructive;
  final VoidCallback onConfirm;
  final IconData? icon;

  const DmxConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    this.confirmLabel,
    this.cancelLabel,
    this.isDestructive = false,
    required this.onConfirm,
    this.icon,
  });

  static Future<bool?> show(
    BuildContext context, {
    required String title,
    required String message,
    String? confirmLabel,
    String? cancelLabel,
    bool isDestructive = false,
    IconData? icon,
  }) async {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => DmxConfirmDialog(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        isDestructive: isDestructive,
        icon: icon,
        onConfirm: () => Navigator.of(ctx).pop(true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final accent = isDestructive
        ? (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed)
        : (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue);

    return DmxDialog(
      title: title,
      accentColor: accent,
      icon: icon ??
          (isDestructive ? Icons.warning_rounded : Icons.help_outline_rounded),
      content: Text(
        message,
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 13,
          color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(
            cancelLabel ?? L10n.of(context, 'cancel'),
            style: TextStyle(color: mutedClr, fontFamily: 'Space Grotesk'),
          ),
        ),
        const SizedBox(width: 8),
        DmxButton.filled(
          label: confirmLabel ?? L10n.of(context, 'confirm'),
          color: accent,
          onPressed: onConfirm,
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unified Button Component
// ─────────────────────────────────────────────────────────────────────────────
enum DmxButtonVariant { filled, outline, destructive, ghost }

class DmxButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color? color;
  final DmxButtonVariant variant;
  final bool isLoading;
  final double radius;

  const DmxButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.color,
    this.variant = DmxButtonVariant.filled,
    this.isLoading = false,
    this.radius = 10,
  });

  const DmxButton.filled({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.color,
    this.isLoading = false,
    this.radius = 10,
  }) : variant = DmxButtonVariant.filled;

  const DmxButton.outline({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.color,
    this.isLoading = false,
    this.radius = 10,
  }) : variant = DmxButtonVariant.outline;

  const DmxButton.destructive({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.color,
    this.isLoading = false,
    this.radius = 10,
  }) : variant = DmxButtonVariant.destructive;

  const DmxButton.ghost({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.color,
    this.isLoading = false,
    this.radius = 10,
  }) : variant = DmxButtonVariant.ghost;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final glow = settings.enableGlow && !settings.classicUi;

    final baseAccent = color ??
        (variant == DmxButtonVariant.destructive
            ? (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed)
            : (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue));

    final textColor = switch (variant) {
      DmxButtonVariant.filled => AppTheme.inkOn(baseAccent),
      DmxButtonVariant.outline => baseAccent,
      DmxButtonVariant.destructive => Colors.white,
      DmxButtonVariant.ghost => baseAccent,
    };

    final bgColor = switch (variant) {
      DmxButtonVariant.filled => baseAccent,
      DmxButtonVariant.outline => Colors.transparent,
      DmxButtonVariant.destructive => baseAccent,
      DmxButtonVariant.ghost => baseAccent.withValues(alpha: 0.1),
    };

    final border = variant == DmxButtonVariant.outline
        ? Border.all(color: baseAccent.withValues(alpha: 0.4), width: 1)
        : null;

    final shadows = (glow &&
            (variant == DmxButtonVariant.filled ||
                variant == DmxButtonVariant.destructive))
        ? [
            BoxShadow(
              color: baseAccent.withValues(alpha: 0.35),
              blurRadius: 12,
              spreadRadius: 0,
              offset: const Offset(0, 2),
            )
          ]
        : null;

    return AnimatedOpacity(
      duration: AppTheme.motionFast,
      opacity: onPressed == null ? 0.5 : 1.0,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(radius),
          border: border,
          boxShadow: shadows,
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(radius),
          child: InkWell(
            onTap: isLoading ? null : onPressed,
            borderRadius: BorderRadius.circular(radius),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (isLoading) ...[
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(textColor),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ] else if (icon != null) ...[
                    Icon(icon, size: 16, color: textColor),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    label.toUpperCase(),
                    style: TextStyle(
                      color: textColor,
                      fontFamily: 'Space Grotesk',
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unified TextField Component
// ─────────────────────────────────────────────────────────────────────────────
class DmxTextField extends StatelessWidget {
  final TextEditingController? controller;
  final String? hintText;
  final IconData? prefixIcon;
  final Widget? suffixIcon;
  final ValueChanged<String>? onChanged;
  final bool autofocus;

  const DmxTextField({
    super.key,
    this.controller,
    this.hintText,
    this.prefixIcon,
    this.suffixIcon,
    this.onChanged,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<SettingsProvider>().isDarkMode;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      decoration: BoxDecoration(
        color: AppTheme.panelBg(isDark),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle,
          width: 1,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          if (prefixIcon != null) ...[
            Icon(prefixIcon, size: 18, color: mutedClr),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: autofocus,
              style: TextStyle(
                color: textClr,
                fontSize: 13,
                fontFamily: 'Inter',
              ),
              onChanged: onChanged,
              decoration: InputDecoration(
                hintText: hintText,
                hintStyle: TextStyle(color: mutedClr, fontSize: 12),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (suffixIcon != null) suffixIcon!,
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unified Empty State View
// ─────────────────────────────────────────────────────────────────────────────
class DmxEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? buttonText;
  final VoidCallback? onButtonPressed;
  final Color? accentColor;

  const DmxEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.buttonText,
    this.onButtonPressed,
    this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final accent =
        accentColor ?? (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue);
    final textClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isLandscape =
            MediaQuery.of(context).orientation == Orientation.landscape ||
                constraints.maxHeight < 360;
        final iconSize = isLandscape ? 28.0 : 36.0;
        final containerPadding = isLandscape ? 14.0 : 22.0;
        final verticalSpacing = isLandscape ? 8.0 : 16.0;

        return Center(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.symmetric(
              horizontal: 24,
              vertical: isLandscape ? 12 : 24,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: EdgeInsets.all(containerPadding),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accent.withValues(alpha: 0.08),
                    border: Border.all(
                      color: accent.withValues(alpha: 0.2),
                      width: 1,
                    ),
                  ),
                  child: Icon(icon, size: iconSize, color: accent),
                ),
                SizedBox(height: verticalSpacing),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Space Grotesk',
                    fontSize: isLandscape ? 13 : 14,
                    fontWeight: FontWeight.bold,
                    color: textClr,
                  ),
                ),
                SizedBox(height: isLandscape ? 4 : 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: isLandscape ? 11 : 12,
                      color: mutedClr,
                      height: 1.35,
                    ),
                  ),
                ),
                if (buttonText != null && onButtonPressed != null) ...[
                  SizedBox(height: verticalSpacing),
                  DmxButton.filled(
                    label: buttonText!,
                    onPressed: onButtonPressed,
                    color: accent,
                    icon: Icons.add_rounded,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unified Notice Banner Component
// ─────────────────────────────────────────────────────────────────────────────
class DmxBanner extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color? accentColor;

  const DmxBanner({
    super.key,
    required this.text,
    this.icon = Icons.info_outline_rounded,
    this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<SettingsProvider>().isDarkMode;
    final accent =
        accentColor ?? (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                color: textClr,
                fontFamily: 'Inter',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared Helper: Media Choice Dialog (Single vs Playlist)
// ─────────────────────────────────────────────────────────────────────────────
Future<String?> showMediaChoiceDialog(
  BuildContext context, {
  required String videoTitle,
}) async {
  final isDark =
      Provider.of<SettingsProvider>(context, listen: false).isDarkMode;
  return showDialog<String>(
    context: context,
    builder: (ctx) => DmxDialog(
      title: L10n.of(context, 'media_choice_title'),
      icon: Icons.video_collection_rounded,
      content: Text(
        L10n.of(context, 'media_choice_message', args: {'title': videoTitle}),
        style: TextStyle(
          color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
          fontSize: 13,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop('single'),
          child: Text(
            L10n.of(context, 'media_choice_single'),
            style: const TextStyle(fontFamily: 'Space Grotesk'),
          ),
        ),
        const SizedBox(width: 8),
        DmxButton.filled(
          label: L10n.of(context, 'media_choice_playlist'),
          onPressed: () => Navigator.of(ctx).pop('playlist'),
        ),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Pressable Interaction Wrapper
// ─────────────────────────────────────────────────────────────────────────────
class DmxPressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scaleOnPress;

  const DmxPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scaleOnPress = 0.96,
  });

  @override
  State<DmxPressable> createState() => _DmxPressableState();
}

class _DmxPressableState extends State<DmxPressable> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          scale: (!reduceMotion && _pressed) ? widget.scaleOnPress : 1.0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: widget.child,
        ),
      ),
    );
  }
}
