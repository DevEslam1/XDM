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

    return Directionality(
      textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: DmxBackdropFilter(
          sigmaX: 15,
          sigmaY: 15,
          child: Container(
            decoration: BoxDecoration(
              color: (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(alpha: 0.85),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border(
                top: BorderSide(color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder, width: 0.8),
                left: BorderSide(color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder, width: 0.8),
                right: BorderSide(color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder, width: 0.8),
              ),
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Handle bar
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 20),
                        decoration: BoxDecoration(
                          color: (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted).withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: (isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                            Icons.content_paste,
                            color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          L10n.of(context, 'clipboard_detected'),
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.0,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      L10n.of(context, 'clipboard_desc'),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: (isDark ? AppTheme.background : AppTheme.lightBackground).withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder, width: 0.8),
                      ),
                      child: Text(
                        url,
                        style: TextStyle(
                          color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                          fontSize: 12,
                          fontFamily: 'monospace',
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
                              side: BorderSide(color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder),
                              foregroundColor: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
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
                            color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                            onPressed: () {
                              Navigator.pop(context);
                              onEstablish();
                            },
                            text: L10n.of(context, 'clipboard_establish'),
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
