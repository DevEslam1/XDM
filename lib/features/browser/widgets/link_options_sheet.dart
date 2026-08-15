import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../settings/provider/settings_provider.dart';
import '../services/browser_detector.dart';

/// Lightweight bottom sheet shown when the user long-presses a plain **link**
/// (type == 'link') in the browser.
///
/// Unlike [BrowserDownloadSheet], this sheet has no "Signal Lock" animation.
/// It focuses purely on navigation options, with Download shown only when
/// [BrowserDetector] confirms the URL resolves to a known downloadable file.
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
    runHaptic(settings);
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
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
      LoggingService.logger('LinkOptionsSheet').warning('Operation failed with fallback', e, st);
      return url;
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final muted = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final surfaceClr = isDark
        ? (settings.isAmoledMode ? AppTheme.amoledSurface : AppTheme.surface)
        : AppTheme.lightSurface;

    return Directionality(
      textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: DmxBackdropFilter(
          sigmaX: 15,
          sigmaY: 15,
          child: Container(
            decoration: BoxDecoration(
              color: surfaceClr.withValues(
                  alpha: settings.isAmoledMode ? 1.0 : 0.92),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border(
                top: BorderSide(
                  color: isDark && settings.isAmoledMode
                      ? AppTheme.amoledBorder
                      : accent.withValues(alpha: 0.4),
                  width: 1,
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: muted.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: accent.withValues(alpha: 0.25),
                            ),
                          ),
                          child:
                              Icon(Icons.link_rounded, color: accent, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _displayHost,
                                style: TextStyle(
                                  color: textClr,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                url,
                                style: TextStyle(
                                  color: secClr,
                                  fontSize: 11,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
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
                    const SizedBox(height: 4),
                    Divider(color: muted.withValues(alpha: 0.2), height: 1),
                    const SizedBox(height: 4),
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
                    if (_isDetectedFile && onDownload != null) ...[
                      const SizedBox(height: 4),
                      Divider(color: muted.withValues(alpha: 0.2), height: 1),
                      const SizedBox(height: 4),
                      _OptionTile(
                        icon: Icons.download_rounded,
                        label: isRtl
                            ? '\u062a\u062d\u0645\u064a\u0644'
                            : 'Download',
                        accent: isDark
                            ? AppTheme.neonGreen
                            : AppTheme.lightNeonGreen,
                        isDark: isDark,
                        isRtl: isRtl,
                        filled: true,
                        onTap: () {
                          Navigator.pop(context);
                          onDownload?.call();
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
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
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: filled
                      ? accent.withValues(alpha: 0.15)
                      : accent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: accent, size: 18),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: filled ? accent : textClr,
                    fontSize: 14,
                    fontWeight: filled ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              Icon(
                isRtl
                    ? Icons.chevron_left_rounded
                    : Icons.chevron_right_rounded,
                color: accent.withValues(alpha: 0.4),
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
