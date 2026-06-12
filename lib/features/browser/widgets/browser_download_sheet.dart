import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:path/path.dart' as p;
import '../../../core/app_theme.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/url_utils.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../add_download/screens/add_screen.dart';
import '../../settings/provider/settings_provider.dart';
import '../../downloads/provider/download_provider.dart';
import '../../downloads/models/download_task.dart';
import '../services/browser_detector.dart';

class BrowserDownloadSheet extends StatelessWidget {
  final String url;
  final String? type;
  final String? text;
  final String? suggestedName;
  final VoidCallback? onQuality;

  const BrowserDownloadSheet({
    super.key,
    required this.url,
    this.type,
    this.text,
    this.suggestedName,
    this.onQuality,
  });

  static Future<void> show(
    BuildContext context,
    String url, {
    String? type,
    String? text,
    String? suggestedName,
    VoidCallback? onQuality,
  }) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    runHaptic(settings);
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => BrowserDownloadSheet(
        url: url,
        type: type,
        text: text,
        suggestedName: suggestedName,
        onQuality: onQuality,
      ),
    );
  }

  IconData get _icon {
    switch (type) {
      case 'video':
        return Icons.movie_outlined;
      case 'audio':
        return Icons.audiotrack_outlined;
      case 'image':
        return Icons.image_outlined;
      case 'link':
      default:
        return Icons.link;
    }
  }

  String get _title {
    final detected = BrowserDetector.detect(url);
    if (detected == null) return 'DOWNLOAD LINK';
    switch (detected.kind) {
      case DetectedMediaKind.video:
        return 'DOWNLOAD VIDEO';
      case DetectedMediaKind.audio:
        return 'DOWNLOAD AUDIO';
      case DetectedMediaKind.image:
        return 'DOWNLOAD IMAGE';
      case DetectedMediaKind.document:
        return 'DOWNLOAD DOCUMENT';
      case DetectedMediaKind.archive:
        return 'DOWNLOAD ARCHIVE';
      case DetectedMediaKind.executable:
        return 'DOWNLOAD EXECUTABLE';
      case DetectedMediaKind.torrent:
        return 'DOWNLOAD TORRENT';
      case DetectedMediaKind.magnet:
        return 'DOWNLOAD MAGNET';
      case DetectedMediaKind.unknown:
        return 'DOWNLOAD FILE';
    }
  }

  Color _accentColor(bool isDark) {
    switch (type) {
      case 'video':
        return isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;
      case 'audio':
        return isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
      case 'image':
        return isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber;
      case 'link':
      default:
        return isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final accent = _accentColor(isDark);

    return Directionality(
      textDirection: TextDirection.ltr,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: DmxBackdropFilter(
          sigmaX: 15,
          sigmaY: 15,
          child: Container(
            decoration: BoxDecoration(
              color: (isDark ? AppTheme.surface : AppTheme.lightSurface)
                  .withValues(alpha: 0.92),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border(
                top: BorderSide(
                    color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                    width: 0.8),
                left: BorderSide(
                    color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                    width: 0.8),
                right: BorderSide(
                    color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                    width: 0.8),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 18),
                        decoration: BoxDecoration(
                          color: (isDark ? AppTheme.textMuted : AppTheme.lightTextMuted)
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
                          ),
                          child: Icon(_icon, color: accent, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _title,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  color: accent,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.0,
                                ),
                          ),
                        ),
                      ],
                    ),
                    if ((text ?? '').isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        text!,
                        style: TextStyle(
                          color: isDark
                              ? AppTheme.textSecondary
                              : AppTheme.lightTextSecondary,
                          fontSize: 12,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: (isDark ? AppTheme.background : AppTheme.lightBackground)
                            .withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: isDark
                                ? AppTheme.glassBorder
                                : AppTheme.lightGlassBorder,
                            width: 0.8),
                      ),
                      child: Text(
                        url,
                        style: TextStyle(
                          color: isDark
                              ? AppTheme.textPrimary
                              : AppTheme.lightTextPrimary,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
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
                                borderRadius: BorderRadius.circular(20),
                              ),
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14),
                            ),
                            onPressed: () => Navigator.pop(context),
                            child: const Text('CANCEL'),
                          ),
                        ),
                        if (type == 'video') ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(color: accent),
                                foregroundColor: accent,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                              ),
                              onPressed: () {
                                Navigator.pop(context);
                                onQuality?.call();
                              },
                              child: const Text('QUALITY'),
                            ),
                          ),
                        ],
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: accent,
                              foregroundColor: Colors.black,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                              ),
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14),
                            ),
                            onPressed: () {
                              Navigator.pop(context);
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) =>
                                      AddScreen(
                                        prefilledUrl: url,
                                        prefilledName: suggestedName,
                                      ),
                                ),
                              );
                            },
                            child: const Text('DOWNLOAD'),
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
