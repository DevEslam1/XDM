import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_theme.dart';
import 'youtube_service.dart';
import '../../features/add_download/widgets/add_download_dialog.dart';
import '../../features/add_download/widgets/media_quality_sheet.dart';
import '../../features/add_download/widgets/youtube_playlist_sheet.dart';
import '../../features/downloads/provider/download_provider.dart';
import '../../features/settings/provider/settings_provider.dart';
import '../../shared/widgets/themed_snackbar.dart';
import '../utils/localization.dart';

class ShareUrlHandler {
  static Future<void> handle(
    BuildContext context,
    String url, {
    required bool isShareLaunch,
  }) async {
    if (YoutubeService.isPlaylistUrl(url)) {
      await YoutubePlaylistSheet.show(context, url);
    } else if (YoutubeService.isExtractableMediaUrl(url)) {
      List<Map<String, dynamic>>? streams;
      try {
        streams = await YoutubeService.getStreamsForAnyUrl(url);
      } catch (_) {
        streams = null;
      }

      final contextMounted = context;
      if (!contextMounted.mounted) return;

      if (streams == null || streams.isEmpty) {
        await showDialog(
          context: contextMounted,
          builder: (_) => AddDownloadDialog(
            prefilledUrl: url,
            isShareLaunch: isShareLaunch,
          ),
        );
      } else if (streams.length == 1) {
        final stream = streams.first;
        final title = stream['title'] as String? ?? 'Media Download';
        final ext = stream['ext'] as String? ?? 'mp4';
        final streamUrl = stream['src'] as String;
        final streamSize = stream['size'] as int? ?? 0;
        final audioUrl = stream['audioSrc'] as String?;
        final audioSize = stream['audioSize'] as int?;
        final streamType = stream['type'] as String? ?? 'muxed';
        final qualityPreset = streamType == 'audio'
            ? 'audio_only'
            : stream['quality'] as String?;
        final category = streamType == 'audio' ? 'Audio' : 'Video';
        final fileName = '$title.$ext';

        final provider = contextMounted.read<DownloadProvider>();
        final settings = contextMounted.read<SettingsProvider>();
        final threadCount = settings.defaultThreadCount;
        final savePath = settings.customDownloadPath ?? '';

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
        );

        if (contextMounted.mounted) {
          final isDark = settings.isDarkMode;
          if (provider.lastError != null) {
            ThemedSnackbar.show(
              contextMounted,
              message: provider.lastError!,
              color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
              icon: Icons.error_outline,
              isDarkMode: isDark,
            );
          } else {
            ThemedSnackbar.show(
              contextMounted,
              message: L10n.isRtl(contextMounted)
                  ? 'تم بدء التحميل'
                  : 'Download started',
              color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
              icon: Icons.check_circle_outline,
              isDarkMode: isDark,
            );
          }
        }
      } else {
        final selected = await MediaQualitySheet.show(
          contextMounted,
          url,
          preloadedStreams: streams,
        );
        if (selected == null || !contextMounted.mounted) return;

        final title = selected['title'] as String? ?? 'Media Download';
        final ext = selected['ext'] as String? ?? 'mp4';
        final streamUrl = selected['src'] as String;
        final streamSize = selected['size'] as int? ?? 0;
        final audioUrl = selected['audioSrc'] as String?;
        final audioSize = selected['audioSize'] as int?;
        final streamType = selected['type'] as String? ?? 'muxed';
        final qualityPreset = streamType == 'audio'
            ? 'audio_only'
            : selected['quality'] as String?;
        final category = streamType == 'audio' ? 'Audio' : 'Video';
        final fileName = '$title.$ext';

        final provider = contextMounted.read<DownloadProvider>();
        final settings = contextMounted.read<SettingsProvider>();
        final threadCount = settings.defaultThreadCount;
        final savePath = settings.customDownloadPath ?? '';

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
        );

        if (contextMounted.mounted) {
          final isDark = settings.isDarkMode;
          if (provider.lastError != null) {
            ThemedSnackbar.show(
              contextMounted,
              message: provider.lastError!,
              color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
              icon: Icons.error_outline,
              isDarkMode: isDark,
            );
          } else {
            ThemedSnackbar.show(
              contextMounted,
              message: L10n.isRtl(contextMounted)
                  ? 'تم بدء التحميل'
                  : 'Download started',
              color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
              icon: Icons.check_circle_outline,
              isDarkMode: isDark,
            );
          }
        }
      }
    } else {
      await showDialog(
        context: context,
        builder: (_) =>
            AddDownloadDialog(prefilledUrl: url, isShareLaunch: isShareLaunch),
      );
    }
  }
}
