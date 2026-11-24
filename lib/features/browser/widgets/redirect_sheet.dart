import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../../shared/widgets/dmx_bottom_sheet.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../settings/provider/settings_provider.dart';

/// A bottom sheet that displays potential redirect targets extracted from
/// an ad-bridge or shortener page. Allows the user to open, copy, or dismiss.
class RedirectSheet extends StatelessWidget {
  final List<String> candidates;
  final ValueChanged<String> onSelected;

  const RedirectSheet({
    super.key,
    required this.candidates,
    required this.onSelected,
  });

  /// Helper to show the sheet cleanly.
  static Future<void> show(
    BuildContext context, {
    required List<String> candidates,
    required ValueChanged<String> onSelected,
  }) {
    if (candidates.isEmpty) return Future.value();
    final navigator = Navigator.of(context);
    return showDmxModalBottomSheet<void>(
      context: context,
      builder: (_) => RedirectSheet(
        candidates: candidates,
        onSelected: (url) {
          navigator.pop();
          onSelected(url);
        },
      ),
    );
  }

  bool _resolveDark(BuildContext context) {
    try {
      return context.watch<SettingsProvider>().isDarkMode;
    } catch (_) {
      return Theme.of(context).brightness == Brightness.dark;
    }
  }

  bool _resolveAmoled(BuildContext context) {
    try {
      return context.watch<SettingsProvider>().isAmoledMode;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = _resolveDark(context);
    final isAmoled = _resolveAmoled(context);
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final amber = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;

    return Directionality(
      textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
      child: DmxSheetContainer(
        scrollable: false,
        isDark: isDark,
        isAmoled: isAmoled,
        accentColor: amber,
        maxHeightFraction: 0.78,
        padding: const EdgeInsets.fromLTRB(
          DmxTokens.sheetHorizontalPadding,
          12,
          DmxTokens.sheetHorizontalPadding,
          12,
        ),
        header: DmxSheetHeader(
          isDark: isDark,
          icon: Icons.alt_route_rounded,
          accentColor: amber,
          title: isRtl ? 'تم رصد إعادة توجيه' : 'Redirect Detected',
          subtitle: isRtl
              ? 'تبدو هذه الصفحة كجسر إعلاني. اختر الوجهة الحقيقية:'
              : 'This page appears to be an ad bridge. Select the real destination:',
        ),
        footer: DmxSheetActionBar(
          isDark: isDark,
          isAmoled: isAmoled,
          secondaryLabel: isRtl ? 'البقاء في الصفحة' : 'Stay on page',
          onSecondary: () => Navigator.of(context).pop(),
          primaryLabel: candidates.length == 1
              ? (isRtl ? 'فتح الوجهة' : 'Open destination')
              : null,
          primaryIcon:
              candidates.length == 1 ? Icons.open_in_new_rounded : null,
          primaryColor: accent,
          onPrimary: candidates.length == 1
              ? () => onSelected(candidates.first)
              : null,
        ),
        child: ListView.separated(
          shrinkWrap: true,
          physics: const BouncingScrollPhysics(),
          itemCount: candidates.length,
          separatorBuilder: (_, __) =>
              const SizedBox(height: DmxTokens.cardGap),
          itemBuilder: (context, index) {
            final url = candidates[index];
            return _RedirectCandidateTile(
              url: url,
              isDark: isDark,
              isAmoled: isAmoled,
              isRtl: isRtl,
              onTap: () => onSelected(url),
            );
          },
        ),
      ),
    );
  }
}

class _RedirectCandidateTile extends StatelessWidget {
  final String url;
  final bool isDark;
  final bool isAmoled;
  final bool isRtl;
  final VoidCallback onTap;

  const _RedirectCandidateTile({
    required this.url,
    required this.isDark,
    required this.isAmoled,
    required this.isRtl,
    required this.onTap,
  });

  static final RegExp _directFileRegex = RegExp(
    r'\.(mp4|mkv|mp3|zip|rar|7z|apk|exe|dmg|iso|m4a|pdf|epub)(\?|$)',
    caseSensitive: false,
  );

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(url);
    final isSecure = uri?.scheme == 'https';
    final host = (uri?.host.isNotEmpty ?? false) ? uri!.host : 'Unknown Host';
    final path = uri?.path ?? '';
    final query = uri?.query ?? '';
    final isDirectFile = _directFileRegex.hasMatch(path);

    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final green = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final amber = isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
    final textPrimary = AppTheme.textPrimaryOf(isDark);
    final textSecondary = AppTheme.textSecondaryOf(isDark);
    final textMuted = AppTheme.textMutedOf(isDark);
    final badgeColor = isDirectFile ? green : accent;

    final pathDisplay = path.isEmpty && query.isEmpty
        ? '/'
        : '$path${query.isNotEmpty ? '?$query' : ''}';

    return Container(
      decoration: BoxDecoration(
        color:
            AppTheme.surfaceColor(isDark, isAmoled: isAmoled, elevated: true),
        borderRadius: BorderRadius.circular(DmxTokens.radiusLg),
        border: Border.all(
          color: AppTheme.hairlineBorder(isDark, isAmoled: isAmoled),
          width: DmxTokens.borderThin,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(DmxTokens.radiusLg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(DmxTokens.radiusLg),
          child: Padding(
            padding: const EdgeInsets.all(DmxTokens.cardPadding),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: isDark ? 0.14 : 0.10),
                    borderRadius: BorderRadius.circular(DmxTokens.badgeRadius),
                    border: Border.all(
                      color: badgeColor.withValues(alpha: 0.25),
                      width: DmxTokens.borderThin,
                    ),
                  ),
                  child: Icon(
                    isDirectFile
                        ? Icons.download_rounded
                        : Icons.language_rounded,
                    color: badgeColor,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              host,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: AppTheme.fontDisplay,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: textPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(
                            isSecure
                                ? Icons.lock_rounded
                                : Icons.lock_open_rounded,
                            size: 13,
                            color: isSecure ? green : amber,
                          ),
                          if (isDirectFile) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: green.withValues(
                                  alpha: isDark ? 0.16 : 0.12,
                                ),
                                borderRadius:
                                    BorderRadius.circular(DmxTokens.radiusSm),
                                border: Border.all(
                                  color: green.withValues(alpha: 0.30),
                                  width: DmxTokens.borderThin,
                                ),
                              ),
                              child: Text(
                                'FILE',
                                style: TextStyle(
                                  fontFamily: AppTheme.fontDisplay,
                                  fontSize: DmxTokens.textXs,
                                  fontWeight: FontWeight.w700,
                                  color: green,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        pathDisplay,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: AppTheme.fontBody,
                          fontSize: DmxTokens.textSm,
                          color: textSecondary,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Tooltip(
                  message: isRtl ? 'نسخ الرابط' : 'Copy link',
                  child: IconButton(
                    icon: Icon(
                      Icons.copy_rounded,
                      size: 18,
                      color: textMuted,
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: url));
                      ThemedSnackbar.show(
                        context,
                        message: isRtl
                            ? 'تم نسخ الرابط'
                            : 'Link copied to clipboard',
                        color: accent,
                        icon: Icons.copy_rounded,
                        isDarkMode: isDark,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
