import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../features/add_download/widgets/add_download_dialog.dart';
import '../../features/add_download/widgets/media_quality_sheet.dart';
import '../../features/add_download/widgets/youtube_playlist_sheet.dart';
import '../../features/downloads/provider/download_provider.dart';
import '../../features/settings/provider/settings_provider.dart';
import '../../shared/widgets/themed_snackbar.dart';
import '../app_theme.dart';
import '../utils/localization.dart';
import '../utils/url_utils.dart';
import 'logging_service.dart';
import 'youtube_service.dart';

final _log = LoggingService.logger('ShareUrlHandler');

class ShareUrlHandler {
  static Future<void> handle(
    BuildContext context,
    String url, {
    required bool isShareLaunch,
    String? prefilledName,
  }) async {
    // Validate URL scheme to reject malicious URLs (e.g., file://)
    final trimmedUrl = url.trim();
    final uri = Uri.tryParse(trimmedUrl);
    final scheme = uri?.scheme.toLowerCase() ?? '';
    final allowedSchemes = {'http', 'https', 'magnet', 'file'};
    if (uri == null || !allowedSchemes.contains(scheme)) {
      _log.warning(
          '[ShareUrlHandler] Rejected URL with unsupported scheme "$scheme": $trimmedUrl');
      debugPrint('[ShareUrlHandler] Rejected URL with scheme: ${uri?.scheme}');
      return;
    }
    // Reject file:// URLs from share intent for security
    if (uri.isScheme('file') && isShareLaunch) {
      _log.warning(
          '[ShareUrlHandler] Rejected file:// URL from share intent: $trimmedUrl');
      debugPrint('[ShareUrlHandler] Rejected file:// URL from share intent');
      return;
    }

    if (YoutubeService.isPlaylistUrl(trimmedUrl)) {
      await YoutubePlaylistSheet.show(context, url);
    } else if (YoutubeService.isExtractableMediaUrl(url) &&
        // FIX(20): only route to the extractor backend when the host is
        // actually supported; otherwise unrelated/typo-squatted URLs would be
        // handed to MediaQualitySheet and fail inside the backend.
        YoutubeService.isSupportedMediaHost(url)) {
      final selected = await MediaQualitySheet.show(context, url);
      if (selected == null || !context.mounted) return;

      final title = selected['title'] as String? ?? 'Media Download';
      final ext = selected['ext'] as String? ?? 'mp4';
      final streamUrl =
          (selected['src'] ?? selected['url'] ?? '') as String;
      final streamSize = (selected['size'] as num?)?.toInt() ?? 0;
      final audioUrl = selected['audioSrc'] as String?;
      final audioSize = (selected['audioSize'] as num?)?.toInt();
      final streamType = selected['type'] as String? ?? 'muxed';
      final thumbnailUrl = selected['thumbnailUrl'] as String?;
      final qualityPreset =
          streamType == 'audio' ? 'audio_only' : selected['quality'] as String?;
      final category = streamType == 'audio' ? 'Audio' : 'Video';
      final fileName = prefilledName ?? '$title.$ext';

      final provider = context.read<DownloadProvider>();
      final settings = context.read<SettingsProvider>();
      final threadCount = settings.defaultThreadCount;
      final savePath = settings.customDownloadPath ?? '';

      try {
        await provider.addDownload(
          name: fileName,
          url: streamUrl,
          size: streamSize,
          category: category,
          savePath: savePath,
          threadCount: threadCount,
          downloadPageUrl: url,
          youtubeQualityPreset: qualityPreset,
          mergedAudioUrl: audioUrl,
          audioSize: audioSize ?? 0,
          thumbnailUrl: thumbnailUrl,
        );
      } catch (e) {
        debugPrint('ShareUrlHandler addDownload error: $e');
        if (context.mounted) {
          final isDark = settings.isDarkMode;
          ThemedSnackbar.show(
            context,
            message: 'Download failed: $e',
            color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
            icon: Icons.error_outline,
            isDarkMode: isDark,
          );
        }
        return;
      }

      if (context.mounted) {
        final isDark = settings.isDarkMode;
        if (provider.lastError != null) {
          ThemedSnackbar.show(
            context,
            message: provider.lastError!,
            color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
            icon: Icons.error_outline,
            isDarkMode: isDark,
          );
        } else {
          ThemedSnackbar.show(
            context,
            message:
                L10n.isRtl(context) ? 'تم بدء التحميل' : 'Download started',
            color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
            icon: Icons.check_circle_outline,
            isDarkMode: isDark,
          );
        }
      }
    } else {
      String? requestedFileName = prefilledName;
      if (requestedFileName == null && isMagnetUrl(trimmedUrl)) {
        final parsed = parseMagnetUrl(trimmedUrl);
        final dn = parsed['name'];
        if (dn != null && dn.isNotEmpty) {
          requestedFileName = dn;
        }
      }
      await showDialog(
        context: context,
        builder: (_) => AddDownloadDialog(
          prefilledUrl: url,
          prefilledName: requestedFileName,
          isShareLaunch: isShareLaunch,
        ),
      );
    }
  }

  static VoidCallback? _onPauseAll;
  static VoidCallback? _onResumeAll;

  static void setPauseAllCallback(VoidCallback callback) {
    _onPauseAll = callback;
  }

  static void setResumeAllCallback(VoidCallback callback) {
    _onResumeAll = callback;
  }

  /// Handle incoming deep links from App Intents / Shortcuts / Share Extension.
  static Future<void> handleDeepLink(
    Uri uri, {
    required void Function(String url) onUrl,
  }) async {
    if (uri.scheme != 'dmx') return;

    switch (uri.host) {
      case 'add':
      case 'share':
        final url = uri.queryParameters['url'];
        if (url != null && url.isNotEmpty) {
          onUrl(url);
        }
        break;

      case 'pause-all':
        _onPauseAll?.call();
        break;

      case 'resume-all':
        _onResumeAll?.call();
        break;

      default:
        break;
    }
  }
}
