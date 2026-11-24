import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../../shared/widgets/dmx_bottom_sheet.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../settings/provider/settings_provider.dart';
import '../services/browser_detector.dart';

/// Lightweight bottom sheet shown when the user long-presses a plain **link**
/// (`type == 'link'`) in the browser.
///
/// Focuses on compact, scannable link preview + grouped navigation/share
/// actions, with Download surfaced when [BrowserDetector] confirms a known
/// downloadable file.
class LinkOptionsSheet extends StatelessWidget with HapticHelper {
  final String url;
  final VoidCallback? onOpen;
  final VoidCallback? onOpenInNewTab;
  final VoidCallback? onOpenInBackground;
  final VoidCallback? onOpenInIncognito;
  final VoidCallback? onDownload;

  const LinkOptionsSheet({
    super.key,
    required this.url,
    this.onOpen,
    this.onOpenInNewTab,
    this.onOpenInBackground,
    this.onOpenInIncognito,
    this.onDownload,
  });

  static Future<void> show(
    BuildContext context,
    String url, {
    VoidCallback? onOpen,
    VoidCallback? onOpenInNewTab,
    VoidCallback? onOpenInBackground,
    VoidCallback? onOpenInIncognito,
    VoidCallback? onDownload,
  }) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    HapticHelper.triggerHaptic(settings);
    return showDmxModalBottomSheet<void>(
      context: context,
      builder: (_) => LinkOptionsSheet(
        url: url,
        onOpen: onOpen,
        onOpenInNewTab: onOpenInNewTab,
        onOpenInBackground: onOpenInBackground,
        onOpenInIncognito: onOpenInIncognito,
        onDownload: onDownload,
      ),
    );
  }

  bool get _isDetectedFile => BrowserDetector.detect(url) != null;

  String get _displayHost {
    try {
      var host = Uri.parse(url).host;
      if (host.startsWith('www.')) host = host.substring(4);
      return host.isNotEmpty ? host : url;
    } catch (e, st) {
      LoggingService.logger('LinkOptionsSheet')
          .warning('Operation failed with fallback', e, st);
      return url;
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isAmoled = settings.isAmoledMode;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final green = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final dividerColor = AppTheme.hairlineBorder(isDark, isAmoled: isAmoled);

    return Directionality(
      textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
      child: DmxSheetContainer(
        scrollable: true,
        isDark: isDark,
        isAmoled: isAmoled,
        accentColor: _isDetectedFile ? green : accent,
        header: DmxSheetHeader(
          isDark: isDark,
          icon: _isDetectedFile
              ? Icons.download_for_offline_rounded
              : Icons.link_rounded,
          accentColor: _isDetectedFile ? green : accent,
          title: _displayHost,
          subtitle: url,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_isDetectedFile && onDownload != null) ...[
              DmxSheetSection(
                isDark: isDark,
                isAmoled: isAmoled,
                elevated: true,
                accentColor: green,
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: _OptionTile(
                  icon: Icons.download_rounded,
                  label: isRtl ? '\u062a\u062d\u0645\u064a\u0644' : 'Download',
                  accent: green,
                  isDark: isDark,
                  isRtl: isRtl,
                  filled: true,
                  onTap: () {
                    Navigator.pop(context);
                    onDownload?.call();
                  },
                ),
              ),
              const SizedBox(height: DmxTokens.cardGap),
            ],

            // Navigation actions group
            DmxSheetSection(
              isDark: isDark,
              isAmoled: isAmoled,
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _OptionTile(
                    icon: Icons.open_in_browser_rounded,
                    label: isRtl ? '\u0641\u062a\u062d' : 'Open',
                    accent: accent,
                    isDark: isDark,
                    isRtl: isRtl,
                    onTap: () {
                      Navigator.pop(context);
                      onOpen?.call();
                    },
                  ),
                  Divider(
                    height: 1,
                    thickness: DmxTokens.borderThin,
                    color: dividerColor,
                  ),
                  _OptionTile(
                    icon: Icons.tab_rounded,
                    label: isRtl
                        ? '\u0641\u062a\u062d \u0641\u064a \u0639\u0644\u0627\u0645\u0629 \u062a\u0628\u0648\u064a\u0628 \u062c\u062f\u064a\u062f\u0629'
                        : 'Open in new tab',
                    accent: accent,
                    isDark: isDark,
                    isRtl: isRtl,
                    onTap: () {
                      Navigator.pop(context);
                      onOpenInNewTab?.call();
                    },
                  ),
                  Divider(
                    height: 1,
                    thickness: DmxTokens.borderThin,
                    color: dividerColor,
                  ),
                  _OptionTile(
                    icon: Icons.tab_unselected_rounded,
                    label: isRtl
                        ? '\u0641\u062a\u062d \u0641\u064a \u0627\u0644\u062e\u0644\u0641\u064a\u0629'
                        : 'Open in background',
                    accent: accent,
                    isDark: isDark,
                    isRtl: isRtl,
                    onTap: () {
                      Navigator.pop(context);
                      onOpenInBackground?.call();
                    },
                  ),
                  Divider(
                    height: 1,
                    thickness: DmxTokens.borderThin,
                    color: dividerColor,
                  ),
                  _OptionTile(
                    icon: Icons.visibility_off_rounded,
                    label: isRtl
                        ? '\u0641\u062a\u062d \u0641\u064a \u0627\u0644\u062a\u0635\u0641\u062d \u0627\u0644\u062e\u0641\u064a'
                        : 'Open in incognito',
                    accent: accent,
                    isDark: isDark,
                    isRtl: isRtl,
                    onTap: () {
                      Navigator.pop(context);
                      onOpenInIncognito?.call();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: DmxTokens.cardGap),

            // Copy & Share group
            DmxSheetSection(
              isDark: isDark,
              isAmoled: isAmoled,
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _OptionTile(
                    icon: Icons.copy_rounded,
                    label: isRtl
                        ? '\u0646\u0633\u062e \u0627\u0644\u0631\u0627\u0628\u0637'
                        : 'Copy link',
                    accent: accent,
                    isDark: isDark,
                    isRtl: isRtl,
                    onTap: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final navigator = Navigator.of(context);
                      final rootCtx = navigator.context;
                      Navigator.pop(context);
                      await Clipboard.setData(ClipboardData(text: url));
                      if (messenger.mounted && rootCtx.mounted) {
                        ThemedSnackbar.show(
                          rootCtx,
                          message: isRtl ? 'تم نسخ الرابط' : 'Link copied',
                          color: accent,
                          icon: Icons.copy_rounded,
                          isDarkMode: isDark,
                        );
                      }
                    },
                  ),
                  Divider(
                    height: 1,
                    thickness: DmxTokens.borderThin,
                    color: dividerColor,
                  ),
                  _OptionTile(
                    icon: Icons.share_rounded,
                    label: isRtl
                        ? '\u0645\u0634\u0627\u0631\u0643\u0629 \u0627\u0644\u0631\u0627\u0628\u0637'
                        : 'Share link',
                    accent: accent,
                    isDark: isDark,
                    isRtl: isRtl,
                    onTap: () async {
                      Navigator.pop(context);
                      await SharePlus.instance.share(ShareParams(text: url));
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color accent;
  final bool isDark;
  final bool filled;
  final bool isRtl;
  final VoidCallback? onTap;

  const _OptionTile({
    required this.icon,
    required this.label,
    required this.accent,
    required this.isDark,
    this.filled = false,
    this.isRtl = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    final textMuted = AppTheme.textMutedOf(isDark);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(minHeight: DmxTokens.touchTargetMin),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: accent.withValues(
                      alpha: filled
                          ? (isDark ? 0.18 : 0.14)
                          : (isDark ? 0.12 : 0.08),
                    ),
                    borderRadius: BorderRadius.circular(DmxTokens.badgeRadius),
                  ),
                  child: Icon(icon, color: accent, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily:
                          filled ? AppTheme.fontDisplay : AppTheme.fontBody,
                      color: filled ? accent : textPrimary,
                      fontSize: 14,
                      fontWeight: filled ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                Icon(
                  isRtl
                      ? Icons.chevron_left_rounded
                      : Icons.chevron_right_rounded,
                  color: filled ? accent.withValues(alpha: 0.7) : textMuted,
                  size: 18,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
