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
  static Future<void> handle(BuildContext context, String url, {required bool isShareLaunch}) async {
    // YouTube playlists get their own dedicated sheet (kept separate because
    // the backend's playlist endpoint is YouTube-specific).
    if (YoutubeService.isPlaylistUrl(url)) {
      await YoutubePlaylistSheet.show(context, url);
    } else if (YoutubeService.isExtractableMediaUrl(url)) {
      // Any HTTP URL that isn't a direct static file — try backend extraction.
      // If the backend says the site is unsupported, fall back to the standard
      // AddDownloadDialog which will treat it as a normal direct download.
      List<Map<String, dynamic>>? streams;
      try {
        streams = await YoutubeService.getStreamsForAnyUrl(url);
      } catch (_) {
        streams = null;
      }

      final contextMounted = context;
      if (!contextMounted.mounted) return;

      if (streams == null || streams.isEmpty) {
        // Backend doesn't support this site — fall back to direct download dialog
        await showDialog(
          context: contextMounted,
          builder: (_) => AddDownloadDialog(
            prefilledUrl: url,
            isShareLaunch: isShareLaunch,
          ),
        );
      } else if (streams.length == 1) {
        // Exactly one stream — auto-download immediately, skip all dialogs.
        final stream = streams.first;
        final title = stream['title'] as String? ?? 'Media Download';
        final ext = stream['ext'] as String? ?? 'mp4';
        final streamUrl = stream['src'] as String;
        final streamSize = stream['size'] as int? ?? 0;
        final audioUrl = stream['audioSrc'] as String?;
        final audioSize = stream['audioSize'] as int?;
        final streamType = stream['type'] as String? ?? 'muxed';
        final qualityPreset = streamType == 'audio' ? 'audio_only' : stream['quality'] as String?;
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
      } else {
        // Multiple streams — show quality picker with pre-fetched data to
        // avoid redundant backend calls that trigger 429 rate limits.
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
        final qualityPreset = streamType == 'audio' ? 'audio_only' : selected['quality'] as String?;
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
      }
    } else {
      // Direct file links (e.g. .zip, .apk, .mp4) — open the standard download dialog
      await showDialog(
        context: context,
        builder: (_) => AddDownloadDialog(
          prefilledUrl: url,
          isShareLaunch: isShareLaunch,
        ),
      );
    }

  }
}
