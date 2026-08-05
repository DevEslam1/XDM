import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../provider/settings_provider.dart';
/// Unified container for grouping setting tiles inside a single clean card
class SettingsSectionGroup extends StatelessWidget {
  final List<Widget> children;
  final Color? accentColor;

  const SettingsSectionGroup({
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
          if (index == children.length - 1) {
            return child;
          }
          return Column(
            children: [
              child,
              Divider(
                height: 1,
                thickness: 1,
                color: isDark
                    ? AppTheme.borderSubtle
                    : AppTheme.lightBorderSubtle,
                indent: 16,
                endIndent: 16,
              ),
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

/// Standardized Switch tile
class SwitchTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color accentColor;
  final bool batterySaverOverride;

  const SwitchTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    required this.accentColor,
    this.batterySaverOverride = false,
  });

  void _showBatterySaverLockedMessage(BuildContext context) {
    final isRtl = L10n.isRtl(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    HapticFeedback.vibrate();
    ThemedSnackbar.show(
      context,
      message: isRtl
          ? 'وضع توفير البطارية نشط حالياً. قم بإيقافه من علامة تبويب الأداء والطاقة لتغيير هذا الخيار.'
          : 'Battery Saver is active. Turn it off in the "Power & Perf" tab to change this option.',
      color: isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
      icon: Icons.battery_alert_rounded,
      isDarkMode: isDark,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isRtl = L10n.isRtl(context);
    final disabled = onChanged == null || batterySaverOverride;

    final Widget tile = Directionality(
      textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
      child: SwitchListTile(
        value: value,
        onChanged: disabled
            ? null
            : (val) {
                HapticFeedback.lightImpact();
                onChanged!(val);
              },
        activeThumbColor: accentColor,
        activeTrackColor: accentColor.withValues(alpha: 0.3),
        inactiveThumbColor:
            isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
        inactiveTrackColor:
            isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 6,
        ),
        title: Wrap(
          spacing: 6,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color:
                    isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                fontFamily: 'Space Grotesk',
                fontSize: 13.0,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
            if (batterySaverOverride) ...[
              const Tooltip(
                message: 'Controlled by Battery Saver mode',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.battery_saver_rounded,
                      size: 13,
                      color: AppTheme.neonAmber,
                    ),
                    SizedBox(width: 2),
                    Text(
                      'Battery Saver',
                      style: TextStyle(
                        fontSize: 9,
                        color: AppTheme.neonAmber,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
            fontFamily: 'Inter',
            fontSize: 11.0,
            height: 1.25,
            fontWeight: FontWeight.w400,
          ),
        ),
      ),
    );

    if (batterySaverOverride) {
      return GestureDetector(
        onTap: () => _showBatterySaverLockedMessage(context),
        behavior: HitTestBehavior.opaque,
        child: IgnorePointer(
          child: tile,
        ),
      );
    }
    return tile;
  }
}

/// Standardized Slider tile
class SliderTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final Color accentColor;
  final bool batterySaverOverride;

  const SliderTile({
    super.key,
    required this.title,
    this.subtitle,
    this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    this.onChangeEnd,
    required this.accentColor,
    this.batterySaverOverride = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    String badgeText = valueLabel ?? '';
    String? descriptionText = subtitle;

    if (badgeText.isEmpty && subtitle != null) {
      final spaceIndex = subtitle!.indexOf(' ');
      if (spaceIndex > 0 &&
          (subtitle!.startsWith(RegExp(r'\d')) || subtitle!.endsWith('%'))) {
        badgeText = subtitle!.substring(0, spaceIndex);
        descriptionText = subtitle!.substring(spaceIndex + 1);
      } else {
        badgeText = subtitle!;
        descriptionText = null;
      }
    }

    final disabled = onChanged == null || batterySaverOverride;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isDark
                            ? AppTheme.textPrimary
                            : AppTheme.lightTextPrimary,
                        fontFamily: 'Space Grotesk',
                        fontSize: 13.0,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (descriptionText != null &&
                        descriptionText.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          descriptionText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isDark
                                ? AppTheme.textMuted
                                : AppTheme.lightTextMuted,
                            fontFamily: 'Inter',
                            fontSize: 11.0,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (badgeText.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: accentColor.withValues(alpha: 0.3),
                      width: 1,
                    ),
                  ),
                  child: Text(
                    badgeText,
                    style: TextStyle(
                      color: accentColor,
                      fontFamily: 'Space Grotesk',
                      fontSize: 11.0,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor:
                  disabled ? accentColor.withValues(alpha: 0.4) : accentColor,
              inactiveTrackColor:
                  isDark ? AppTheme.borderSubtle : AppTheme.lightBorderSubtle,
              thumbColor:
                  disabled ? accentColor.withValues(alpha: 0.4) : accentColor,
              overlayColor: accentColor.withValues(alpha: 0.2),
              trackHeight: 3.0,
              thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius: 6.0,
              ),
              overlayShape: const RoundSliderOverlayShape(
                overlayRadius: 14.0,
              ),
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: disabled ? null : onChanged,
              onChangeEnd: disabled ? null : onChangeEnd,
            ),
          ),
        ],
      ),
    );
  }
}

/// Standardized Dropdown tile
class DropdownTile<T> extends StatelessWidget {
  final String title;
  final String subtitle;
  final T value;
  final List<T> items;
  final Map<T, String>? itemLabels;
  final ValueChanged<T?>? onChanged;
  final Color accentColor;
  final bool batterySaverOverride;

  const DropdownTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.items,
    this.itemLabels,
    required this.onChanged,
    required this.accentColor,
    this.batterySaverOverride = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final disabled = onChanged == null || batterySaverOverride;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isDark
                              ? AppTheme.textPrimary
                              : AppTheme.lightTextPrimary,
                          fontFamily: 'Space Grotesk',
                          fontSize: 13.0,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (batterySaverOverride) ...[
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.battery_saver_rounded,
                        size: 13,
                        color: AppTheme.neonAmber,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color:
                        isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                    fontFamily: 'Inter',
                    fontSize: 11.0,
                    height: 1.2,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 104,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: accentColor.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<T>(
                isDense: true,
                isExpanded: true,
                dropdownColor:
                    isDark ? AppTheme.surface : AppTheme.lightSurface,
                borderRadius: BorderRadius.circular(14),
                elevation: 4,
                menuMaxHeight: 250,
                value: value,
                icon: Icon(
                  Icons.expand_more_rounded,
                  color: accentColor,
                  size: 18,
                ),
                style: TextStyle(
                  color: accentColor,
                  fontFamily: 'Space Grotesk',
                  fontSize: 11.0,
                  fontWeight: FontWeight.w700,
                ),
                items: items.map((item) {
                  return DropdownMenuItem<T>(
                    value: item,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        itemLabels != null
                            ? itemLabels![item]!
                            : item.toString(),
                        style: TextStyle(
                          color: isDark
                              ? AppTheme.textPrimary
                              : AppTheme.lightTextPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 11.0,
                        ),
                      ),
                    ),
                  );
                }).toList(),
                onChanged: disabled
                    ? null
                    : (val) {
                        HapticFeedback.lightImpact();
                        onChanged!(val);
                      },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Standardized TextField tile
class TextFieldTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Color accentColor;
  final bool obscureText;
  final TextInputType? keyboardType;

  const TextFieldTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.controller,
    this.onChanged,
    this.onSubmitted,
    required this.accentColor,
    this.obscureText = false,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.textPrimary
                        : AppTheme.lightTextPrimary,
                    fontFamily: 'Space Grotesk',
                    fontSize: 13.0,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color:
                        isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                    fontFamily: 'Inter',
                    fontSize: 11.0,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 5,
            child: Container(
              height: 38,
              decoration: BoxDecoration(
                color: isDark
                    ? AppTheme.surfaceRaised
                    : AppTheme.lightSurfaceRaised,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: accentColor.withValues(alpha: 0.24),
                  width: 1,
                ),
              ),
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                onSubmitted: onSubmitted,
                obscureText: obscureText,
                keyboardType: keyboardType,
                style: TextStyle(
                  color:
                      isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                  fontFamily: 'Inter',
                  fontSize: 12,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: subtitle,
                  hintStyle: TextStyle(
                    color:
                        isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                    fontFamily: 'Inter',
                    fontSize: 11,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Standardized PathPicker tile
class PathPickerTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onClear;
  final Color accentColor;

  const PathPickerTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.onClear,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 4,
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
          fontFamily: 'Space Grotesk',
          fontSize: 13.0,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
          fontFamily: 'Inter',
          fontSize: 11.0,
          height: 1.2,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onClear != null)
            IconButton(
              icon: Icon(
                Icons.clear,
                color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                size: 18,
              ),
              tooltip: L10n.isRtl(context)
                  ? 'إعادة تعيين الافتراضي'
                  : 'Reset to default',
              onPressed: onClear,
            ),
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: accentColor.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
            child: Icon(Icons.folder_open, size: 16, color: accentColor),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// Standardized Action tile
class ActionSettingTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final String buttonText;
  final VoidCallback onTap;
  final Color accentColor;
  final bool isDestructive;

  const ActionSettingTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.buttonText,
    required this.onTap,
    required this.accentColor,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = isDestructive
        ? (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed)
        : accentColor;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.textPrimary
                        : AppTheme.lightTextPrimary,
                    fontFamily: 'Space Grotesk',
                    fontSize: 13.0,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color:
                          isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                      fontFamily: 'Inter',
                      fontSize: 10.0,
                      height: 1.1,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          NeonGlowButton(
            isFilled: !isDestructive,
            color: color,
            onPressed: () {
              HapticFeedback.lightImpact();
              onTap();
            },
            text: buttonText,
          ),
        ],
      ),
    );
  }
}
