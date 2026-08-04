import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../../settings/provider/settings_provider.dart';
import '../services/redirect_guard.dart';
import 'package:logging/logging.dart';

enum RedirectAction {
  openOnceInNewTab,
  openInBackgroundTab,
  alwaysOpenInNewTab,
  allowInSameTab,
}

class RedirectSheet extends StatelessWidget {
  const RedirectSheet({
    super.key,
    required this.targetUrl,
    required this.currentTabUrl,
  });

  final String targetUrl;
  final String currentTabUrl;

  static Future<RedirectAction?> show(
    BuildContext context, {
    required String targetUrl,
    required String currentTabUrl,
  }) {
    final isRtl = L10n.isRtl(context);

    return showModalBottomSheet<RedirectAction>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        return Directionality(
          textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
          child: RedirectSheet(
            targetUrl: targetUrl,
            currentTabUrl: currentTabUrl,
          ),
        );
      },
    );
  }

  /// Sanitizes URL to prevent exposing raw tokens/query params while keeping host & path readable
  static String _sanitizeUrlDisplay(String url) {
    if (url.isEmpty) return '';
    try {
      final normalized = url.startsWith('http://') || url.startsWith('https://')
          ? url
          : 'https://$url';
      final uri = Uri.parse(normalized);
      final path = uri.path.isEmpty ? '/' : uri.path;
      return '${uri.host}$path';
    } catch (e, st) {
      Logger('redirect_sheet')
          .warning('[redirect_sheet] operation failed', e, st);
      return url.split('?').first;
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final targetDomain = RedirectGuard.extractDomain(targetUrl);
    final currentDomain = RedirectGuard.extractDomain(currentTabUrl);
    final sanitizedUrl = _sanitizeUrlDisplay(targetUrl);

    final reduceMotion = settings.reduceVisuals || settings.batterySaverMode;

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: reduceMotion ? Duration.zero : AppTheme.motionBase,
      curve: Curves.easeOutCubic,
      builder: (context, val, child) {
        return Transform.translate(
          offset: Offset(0, 30 * (1 - val)),
          child: Opacity(
            opacity: val,
            child: child,
          ),
        );
      },
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: DmxBackdropFilter(
        sigmaX: 15,
        sigmaY: 15,
        child: Container(
          decoration: BoxDecoration(
            color: (isDark ? AppTheme.surface : AppTheme.lightSurface)
                .withValues(alpha: 0.92),
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(28),
            ),
            border: Border(
              top: BorderSide(
                color: accent.withValues(alpha: 0.4),
                width: 1.2,
              ),
            ),
          ),
          child: SafeArea(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 20),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    // Header
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.security_rounded,
                            color: accent,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                L10n.of(context, 'redirect_intercepted'),
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(
                                      color: accent,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                    ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                L10n.of(context, 'redirect_subtitle'),
                                style: TextStyle(
                                  color: isDark
                                      ? AppTheme.textMuted
                                      : AppTheme.lightTextMuted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),

                    // URL & Domain info box (Sanitized & Responsive)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color:
                            (isDark ? AppTheme.glassBg : AppTheme.lightGlassBg)
                                .withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isDark
                              ? AppTheme.glassBorder
                              : AppTheme.lightGlassBorder,
                          width: 0.8,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Icon(
                                  Icons.link_rounded,
                                  size: 14,
                                  color: accent,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  sanitizedUrl,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isDark
                                        ? AppTheme.textPrimary
                                        : AppTheme.lightTextPrimary,
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    height: 1.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (currentDomain.isNotEmpty &&
                              targetDomain.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: (isDark
                                        ? AppTheme.surface
                                        : AppTheme.lightSurface)
                                    .withValues(alpha: 0.6),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          L10n.of(context, 'redirect_from'),
                                          style: TextStyle(
                                            color: isDark
                                                ? AppTheme.textMuted
                                                : AppTheme.lightTextMuted,
                                            fontSize: 10,
                                          ),
                                        ),
                                        Text(
                                          currentDomain,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: isDark
                                                ? AppTheme.textSecondary
                                                : AppTheme.lightTextSecondary,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8),
                                    child: Icon(
                                      isRtl
                                          ? Icons.arrow_back_rounded
                                          : Icons.arrow_forward_rounded,
                                      size: 14,
                                      color: accent,
                                    ),
                                  ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          L10n.of(context, 'redirect_to'),
                                          style: TextStyle(
                                            color: isDark
                                                ? AppTheme.textMuted
                                                : AppTheme.lightTextMuted,
                                            fontSize: 10,
                                          ),
                                        ),
                                        Text(
                                          targetDomain,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: accent,
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Actions — Safe One-Time Primary, Secondary Actions & Allow
                    // Primary Action: Open in New Tab
                    SizedBox(
                      width: double.infinity,
                      child: NeonGlowButton(
                        isFilled: true,
                        color: accent,
                        onPressed: () => Navigator.pop(
                          context,
                          RedirectAction.openOnceInNewTab,
                        ),
                        text: L10n.of(context, 'redirect_new_tab'),
                        icon: Icons.tab_rounded,
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Secondary Actions Row: Open in Background & Always Open
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(
                                color: isDark
                                    ? AppTheme.glassBorder
                                    : AppTheme.lightGlassBorder,
                              ),
                              foregroundColor: isDark
                                  ? AppTheme.textSecondary
                                  : AppTheme.lightTextSecondary,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: () => Navigator.pop(
                              context,
                              RedirectAction.openInBackgroundTab,
                            ),
                            icon: const Icon(Icons.tab_unselected_rounded,
                                size: 16),
                            label: Text(
                              L10n.of(context, 'redirect_in_background'),
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(
                                color: accent.withValues(alpha: 0.5),
                              ),
                              foregroundColor: accent,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: () => Navigator.pop(
                              context,
                              RedirectAction.alwaysOpenInNewTab,
                            ),
                            icon: const Icon(Icons.push_pin_rounded, size: 16),
                            label: Text(
                              L10n.of(context, 'redirect_always_new_tab'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),

                    // Allow in Same Tab
                    Center(
                      child: TextButton(
                        onPressed: () => Navigator.pop(
                          context,
                          RedirectAction.allowInSameTab,
                        ),
                        child: Text(
                          L10n.of(context, 'redirect_allow_same_tab'),
                          style: TextStyle(
                            color: isDark
                                ? AppTheme.textMuted
                                : AppTheme.lightTextMuted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),

                    // Dismiss / Cancel Hint
                    const SizedBox(height: 4),
                    Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.south_rounded,
                            size: 11,
                            color: (isDark
                                    ? AppTheme.textMuted
                                    : AppTheme.lightTextMuted)
                                .withValues(alpha: 0.6),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            L10n.of(context, 'redirect_dismiss_hint'),
                            style: TextStyle(
                              color: (isDark
                                      ? AppTheme.textMuted
                                      : AppTheme.lightTextMuted)
                                  .withValues(alpha: 0.6),
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
    );
  }
}
