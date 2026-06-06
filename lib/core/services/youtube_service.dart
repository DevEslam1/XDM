import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class YoutubeService {
  static final _yt = YoutubeExplode();

  static bool isYoutubeUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('youtube.com/watch') ||
        lower.contains('youtu.be/') ||
        lower.contains('youtube.com/shorts/') ||
        lower.contains('m.youtube.com/watch');
  }

  static String? extractVideoId(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.host.contains('youtu.be')) {
        return uri.pathSegments.first;
      }
      if (uri.path.contains('shorts')) {
        return uri.pathSegments.last;
      }
      return uri.queryParameters['v'];
    } catch (_) {
      // Fallback regex matching in case queries are structured differently
      final regex = RegExp(r'(?:youtube\.com\/(?:[^\/]+\/.+\/|(?:v|e(?:mbed)?)\/|.*[?&]v=)|youtu\.be\/)([^"&?\/\s]{11})');
      final match = regex.firstMatch(url);
      if (match != null && match.groupCount >= 1) {
        return match.group(1);
      }
      return null;
    }
  }

  static String _formatQuality(VideoQuality q) {
    final name = q.name.toLowerCase();
    if (name.contains('144') || name.contains('low144')) return '144p';
    if (name.contains('240') || name.contains('low240')) return '240p';
    if (name.contains('360') || name.contains('medium360')) return '360p';
    if (name.contains('480') || name.contains('medium480')) return '480p';
    if (name.contains('720') || name.contains('high720')) return '720p';
    if (name.contains('1080') || name.contains('high1080')) return '1080p';
    if (name.contains('1440') || name.contains('high1440')) return '1440p';
    if (name.contains('2160') || name.contains('high2160')) return '4K';
    return q.name;
  }

  static Future<List<Map<String, dynamic>>> getStreams(String url) async {
    final videoId = extractVideoId(url);
    if (videoId == null) return [];

    try {
      final manifest = await _yt.videos.streamsClient.getManifest(videoId);
      final list = <Map<String, dynamic>>[];

      // Fetch Video Title
      String title = 'YouTube Video';
      try {
        final video = await _yt.videos.get(videoId);
        title = video.title;
      } catch (_) {}

      // Muxed streams contain both video and audio
      for (final stream in manifest.muxed) {
        final qLabel = _formatQuality(stream.videoQuality);
        list.add({
          'src': stream.url.toString(),
          'label': 'Video: $qLabel (Muxed)',
          'size': stream.size.totalBytes,
          'ext': stream.container.name,
          'title': title,
        });
      }

      // Audio only streams
      for (final stream in manifest.audioOnly) {
        final kbps = stream.bitrate.kiloBitsPerSecond.round();
        list.add({
          'src': stream.url.toString(),
          'label': 'Audio Only: ($kbps Kbps)',
          'size': stream.size.totalBytes,
          'ext': stream.container.name,
          'title': title,
        });
      }

      // Video only streams
      for (final stream in manifest.videoOnly) {
        final qLabel = _formatQuality(stream.videoQuality);
        list.add({
          'src': stream.url.toString(),
          'label': 'Video Only: ($qLabel)',
          'size': stream.size.totalBytes,
          'ext': stream.container.name,
          'title': title,
        });
      }

      return list;
    } catch (_) {
      return [];
    }
  }
}
