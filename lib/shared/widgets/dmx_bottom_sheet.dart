import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../features/settings/provider/settings_provider.dart';
import '../design/dmx_tokens.dart';

bool _resolveIsDark(BuildContext context, bool? override) {
  if (override != null) return override;
  return Theme.of(context).brightness == Brightness.dark;
}

bool _resolveIsAmoled(BuildContext context, bool? override) {
  if (override != null) return override;
  try {
    return context.watch<SettingsProvider>().isAmoledMode;
  } catch (_) {
    return SettingsProvider.instance.isAmoledMode;
  }
}

/// Shows a modal bottom sheet configured with DMX's unified transparent scrim,
/// safe-area handling, and full height flexibility for [DmxSheetContainer].
Future<T?> showDmxModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = true,
  bool isDismissible = true,
  bool enableDrag = true,
  bool useSafeArea = true,
  bool useRootNavigator = false,
  Color? barrierColor,
  RouteSettings? routeSettings,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return showModalBottomSheet<T>(
    context: context,
    builder: builder,
    isScrollControlled: isScrollControlled,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    useSafeArea: useSafeArea,
    useRootNavigator: useRootNavigator,
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor:
        barrierColor ?? (isDark ? AppTheme.overlayScrim : AppTheme.lightOverlayScrim),
    routeSettings: routeSettings,
    constraints: const BoxConstraints(maxWidth: double.infinity),
  );
}

/// Subtle, centered drag handle pill for DMX bottom sheets.
class DmxSheetDragHandle extends StatelessWidget {
  final Color? color;
  final double width;
  final double height;
  final EdgeInsetsGeometry margin;
  final bool? isDark;

  const DmxSheetDragHandle({
    super.key,
    this.color,
    this.width = DmxTokens.dragHandleWidth,
    this.height = DmxTokens.dragHandleHeight,
    this.margin = const EdgeInsets.only(top: 10, bottom: 8),
    this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final dark = _resolveIsDark(context, isDark);
    final pillColor = color ??
        (dark
            ? AppTheme.borderStrong.withValues(alpha: 0.9)
            : AppTheme.lightBorderStrong);

    return ExcludeSemantics(
      child: Center(
        child: Container(
          width: width,
          height: height,
          margin: margin,
          decoration: BoxDecoration(
            color: pillColor,
            borderRadius: BorderRadius.circular(height / 2),
          ),
        ),
      ),
    );
  }
}

/// Unified bottom sheet shell with drag handle, optional pinned header/footer,
/// scrollable body support, safe-area padding, keyboard inset handling, and
/// responsive desktop/tablet max-width centering.
class DmxSheetContainer extends StatelessWidget {
  final Widget? header;
  final Widget? child;
  final Widget? footer;
  final bool scrollable;
  final bool showDragHandle;
  final bool showHeaderDivider;
  final double maxWidth;
  final double maxHeightFraction;
  final EdgeInsetsGeometry? padding;
  final bool handleKeyboardInset;
  final bool useSafeArea;
  final bool? isDark;
  final bool? isAmoled;
  final Color? backgroundColor;
  final Color? accentColor;
  final double borderRadius;

  const DmxSheetContainer({
    super.key,
    this.header,
    this.child,
    this.footer,
    this.scrollable = false,
    this.showDragHandle = true,
    this.showHeaderDivider = true,
    this.maxWidth = DmxTokens.sheetMaxWidth,
    this.maxHeightFraction = DmxTokens.sheetMaxHeightFraction,
    this.padding,
    this.handleKeyboardInset = true,
    this.useSafeArea = true,
    this.isDark,
    this.isAmoled,
    this.backgroundColor,
    this.accentColor,
    this.borderRadius = DmxTokens.sheetRadius,
  });

  @override
  Widget build(BuildContext context) {
    final dark = _resolveIsDark(context, isDark);
    final amoled = _resolveIsAmoled(context, isAmoled);
    final mediaQuery = MediaQuery.of(context);
    final screenWidth = mediaQuery.size.width;
    final screenHeight = mediaQuery.size.height;
    final viewInsetBottom =
        handleKeyboardInset ? mediaQuery.viewInsets.bottom : 0.0;
    final isWide = screenWidth >= 600;
    final dividerColor = AppTheme.hairlineBorder(dark, isAmoled: amoled);

    final resolvedPadding = padding ??
        EdgeInsets.fromLTRB(
          DmxTokens.sheetHorizontalPadding,
          header != null ? 16 : 8,
          DmxTokens.sheetHorizontalPadding,
          footer != null ? 16 : 20,
        );

    Widget? bodyWidget;
    if (child != null) {
      if (scrollable) {
        bodyWidget = Flexible(
          fit: FlexFit.loose,
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: resolvedPadding,
            child: child,
          ),
        );
      } else {
        bodyWidget = Flexible(
          fit: FlexFit.loose,
          child: resolvedPadding == EdgeInsets.zero
              ? child!
              : Padding(padding: resolvedPadding, child: child!),
        );
      }
    }

    final sheetRadius = isWide
        ? BorderRadius.circular(borderRadius)
        : BorderRadius.vertical(top: Radius.circular(borderRadius));

    Widget sheet = Container(
      decoration: AppTheme.sheetDecoration(
        isDark: dark,
        isAmoled: amoled,
        radius: borderRadius,
        roundedAll: isWide,
        backgroundColor: backgroundColor,
        accentColor: accentColor,
      ),
      child: ClipRRect(
        borderRadius: sheetRadius,
        child: Material(
          color: Colors.transparent,
          child: SafeArea(
            top: false,
            left: useSafeArea,
            right: useSafeArea,
            bottom: useSafeArea && !isWide,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showDragHandle) DmxSheetDragHandle(isDark: dark),
                if (header != null) ...[
                  header!,
                  if (showHeaderDivider)
                    Divider(height: 1, thickness: 0.8, color: dividerColor),
                ],
                if (bodyWidget != null) bodyWidget,
                if (footer != null) footer!,
              ],
            ),
          ),
        ),
      ),
    );

    final availableHeight =
        (screenHeight - viewInsetBottom).clamp(200.0, screenHeight);
    final maxH = (availableHeight * maxHeightFraction).clamp(200.0, availableHeight);

    return AnimatedPadding(
      duration: AppTheme.motionFast,
      curve: AppTheme.motionCurve,
      padding: EdgeInsets.only(
        bottom: viewInsetBottom + (isWide ? 16 : 0),
        left: isWide ? 16 : 0,
        right: isWide ? 16 : 0,
      ),
      child: Align(
        alignment: Alignment.bottomCenter,
        heightFactor: 1.0,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxWidth,
            maxHeight: maxH,
          ),
          child: sheet,
        ),
      ),
    );
  }
}

/// Clean bottom sheet header with optional leading icon badge, title, subtitle,
/// trailing action, and tactile close button.
class DmxSheetHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? accentColor;
  final Widget? leading;
  final Widget? trailing;
  final bool showCloseButton;
  final VoidCallback? onClose;
  final EdgeInsetsGeometry padding;
  final bool? isDark;

  const DmxSheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.accentColor,
    this.leading,
    this.trailing,
    this.showCloseButton = true,
    this.onClose,
    this.padding = const EdgeInsetsDirectional.fromSTEB(20, 4, 12, 14),
    this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final dark = _resolveIsDark(context, isDark);
    final accent =
        accentColor ?? (dark ? AppTheme.neonBlue : AppTheme.lightNeonBlue);
    final textPrimary = AppTheme.textPrimaryOf(dark);
    final textSecondary = AppTheme.textSecondaryOf(dark);
    final mutedClr = AppTheme.textMutedOf(dark);

    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: 12),
          ] else if (icon != null) ...[
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: dark ? 0.14 : 0.10),
                borderRadius: BorderRadius.circular(DmxTokens.badgeRadius),
                border: Border.all(
                  color: accent.withValues(alpha: dark ? 0.24 : 0.20),
                  width: 0.8,
                ),
              ),
              child: Icon(icon, size: 19, color: accent),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Semantics(
              header: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: AppTheme.fontDisplay,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.1,
                      color: textPrimary,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: AppTheme.fontBody,
                        fontSize: 12,
                        height: 1.35,
                        color: textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
          if (showCloseButton) ...[
            const SizedBox(width: 4),
            IconButton(
              onPressed: onClose ?? () => Navigator.of(context).maybePop(),
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              icon: Icon(Icons.close_rounded, size: 20, color: mutedClr),
              style: IconButton.styleFrom(
                minimumSize: const Size(40, 40),
                tapTargetSize: MaterialTapTargetSize.padded,
                backgroundColor: dark
                    ? AppTheme.surfaceRaised.withValues(alpha: 0.7)
                    : AppTheme.lightBgSunken.withValues(alpha: 0.9),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Grouped section block inside a bottom sheet with an optional uppercase
/// micro-label header and a crisp hairline-bordered surface container.
class DmxSheetSection extends StatelessWidget {
  final String? title;
  final Widget? trailing;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final Color? accentColor;
  final bool elevated;
  final double borderRadius;
  final bool? isDark;
  final bool? isAmoled;

  const DmxSheetSection({
    super.key,
    this.title,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.margin = EdgeInsets.zero,
    this.accentColor,
    this.elevated = false,
    this.borderRadius = 14.0,
    this.isDark,
    this.isAmoled,
  });

  @override
  Widget build(BuildContext context) {
    final dark = _resolveIsDark(context, isDark);
    final amoled = _resolveIsAmoled(context, isAmoled);
    final bgColor = elevated
        ? AppTheme.surfaceColor(dark, isAmoled: amoled, elevated: true)
        : (dark
            ? (amoled ? AppTheme.amoledBgSunken : AppTheme.bgSunken)
            : AppTheme.lightBgSunken.withValues(alpha: 0.65));
    final borderClr = accentColor != null
        ? accentColor!.withValues(alpha: dark ? 0.28 : 0.24)
        : AppTheme.hairlineBorder(dark, isAmoled: amoled);

    return Padding(
      padding: margin,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null || trailing != null) ...[
            Padding(
              padding: const EdgeInsets.only(left: 2, right: 2, bottom: 8),
              child: Row(
                children: [
                  if (title != null)
                    Expanded(
                      child: Text(
                        title!.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.microLabel(
                          isDark: dark,
                          color: accentColor ?? AppTheme.textSecondaryOf(dark),
                        ),
                      ),
                    ),
                  if (trailing != null) trailing!,
                ],
              ),
            ),
          ],
          Container(
            padding: padding,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(borderRadius),
              border: Border.all(color: borderClr, width: 0.8),
            ),
            child: child,
          ),
        ],
      ),
    );
  }
}

/// Pinned bottom action bar for DMX bottom sheets.
///
/// Provide either [primaryLabel]/[onPrimary] (with optional [secondaryLabel]/
/// [onSecondary]) OR custom [children].
class DmxSheetActionBar extends StatelessWidget {
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final IconData? primaryIcon;
  final Color? primaryColor;
  final bool primaryLoading;
  final bool primaryDestructive;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final IconData? secondaryIcon;
  final List<Widget>? children;
  final EdgeInsetsGeometry padding;
  final bool showTopDivider;
  final bool? isDark;
  final bool? isAmoled;

  const DmxSheetActionBar({
    super.key,
    this.primaryLabel,
    this.onPrimary,
    this.primaryIcon,
    this.primaryColor,
    this.primaryLoading = false,
    this.primaryDestructive = false,
    this.secondaryLabel,
    this.onSecondary,
    this.secondaryIcon,
    this.children,
    this.padding = const EdgeInsets.fromLTRB(20, 12, 20, 16),
    this.showTopDivider = true,
    this.isDark,
    this.isAmoled,
  });

  @override
  Widget build(BuildContext context) {
    final dark = _resolveIsDark(context, isDark);
    final amoled = _resolveIsAmoled(context, isAmoled);
    final dividerColor = AppTheme.hairlineBorder(dark, isAmoled: amoled);
    final primaryBg = primaryColor ??
        (primaryDestructive
            ? (dark ? AppTheme.neonRed : AppTheme.lightNeonRed)
            : (dark ? AppTheme.neonBlue : AppTheme.lightNeonBlue));
    final primaryFg = primaryDestructive ? Colors.white : AppTheme.inkOn(primaryBg);

    Widget content;
    if (children != null && children!.isNotEmpty) {
      content = Row(
        children: [
          for (var i = 0; i < children!.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            children![i],
          ],
        ],
      );
    } else {
      content = Row(
        children: [
          if (secondaryLabel != null) ...[
            Expanded(
              child: OutlinedButton(
                onPressed: onSecondary,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  foregroundColor: AppTheme.textPrimaryOf(dark),
                  side: BorderSide(
                    color: AppTheme.hairlineBorder(
                      dark,
                      isAmoled: amoled,
                      strong: true,
                    ),
                    width: 1.0,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (secondaryIcon != null) ...[
                      Icon(secondaryIcon, size: 17),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(
                        secondaryLabel!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: AppTheme.fontDisplay,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (primaryLabel != null) const SizedBox(width: 10),
          ],
          if (primaryLabel != null)
            Expanded(
              flex: secondaryLabel != null ? 2 : 1,
              child: FilledButton(
                onPressed: primaryLoading ? null : onPrimary,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  backgroundColor: primaryBg,
                  foregroundColor: primaryFg,
                  disabledBackgroundColor: primaryBg.withValues(alpha: 0.45),
                  disabledForegroundColor: primaryFg.withValues(alpha: 0.8),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (primaryLoading) ...[
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(primaryFg),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ] else if (primaryIcon != null) ...[
                      Icon(primaryIcon, size: 18),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(
                        primaryLabel!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: AppTheme.fontDisplay,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showTopDivider)
          Divider(height: 1, thickness: 0.8, color: dividerColor),
        Padding(padding: padding, child: content),
      ],
    );
  }
}
