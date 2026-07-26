import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/app_theme.dart';
import '../../core/utils/localization.dart';
import '../../features/settings/provider/settings_provider.dart';
import 'neon_glow_button.dart';
import 'dmx_backdrop_filter.dart';

class ClipboardDetectionSheet extends StatelessWidget {
  final String url;
  final VoidCallback onEstablish;
  const ClipboardDetectionSheet({
    super.key,
    required this.url,
    required this.onEstablish,
  });

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    return Directionality(
      textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: DmxBackdropFilter(
          sigmaX: 15,
          sigmaY: 15,
          child: Container(
            decoration: BoxDecoration(
              color: (isDark ? AppTheme.surface : AppTheme.lightSurface)
                  .withValues(alpha: 0.9),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
              border: Border(
                top: BorderSide(
                  color: accent.withValues(alpha: 0.45),
                  width: 1.2,
                ),
              ),
            ),
            child: SafeArea(
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
                          color:
                              (isDark
                                      ? AppTheme.textMuted
                                      : AppTheme.lightTextMuted)
                                  .withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: accent.withValues(alpha: 0.3),
                              width: 0.8,
                            ),
                          ),
                          child: Icon(
                            Icons.radar_rounded,
                            color: accent,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                L10n.of(context, 'clipboard_detected'),
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      color: accent,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1.0,
                                    ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                isRtl
                                    ? 'إشارة مكتشفة في الحافظة'
                                    : 'SIGNAL FOUND IN CLIPBOARD',
                                style: AppTheme.microLabel(
                                  isDark: isDark,
                                  size: 9,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      L10n.of(context, 'clipboard_desc'),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: isDark
                            ? AppTheme.textSecondary
                            : AppTheme.lightTextSecondary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    // URL readout in a recessed well with mono type
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: AppTheme.well(isDark: isDark),
                      child: Text(
                        url,
                        style: TextStyle(
                          color: isDark
                              ? AppTheme.textPrimary
                              : AppTheme.lightTextPrimary,
                          fontSize: 12,
                          fontFamily: 'monospace',
                          height: 1.4,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(
                                color: isDark
                                    ? AppTheme.border
                                    : AppTheme.lightBorder,
                              ),
                              foregroundColor: isDark
                                  ? AppTheme.textSecondary
                                  : AppTheme.lightTextSecondary,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            onPressed: () => Navigator.pop(context),
                            child: Text(L10n.of(context, 'clipboard_ignore')),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: NeonGlowButton(
                            isFilled: true,
                            color: accent,
                            onPressed: () {
                              Navigator.pop(context);
                              onEstablish();
                            },
                            text: L10n.of(context, 'clipboard_establish'),
                            icon: Icons.download_rounded,
                          ),
                        ),
                      ],
                    ),
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
