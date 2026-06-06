import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class YoutubeService {
  static final _yt = YoutubeExplode();

  // ───────────────────────── URL Detection ──────────────────────────

  static bool isYoutubeUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('youtube.com/watch') ||
        lower.contains('youtu.be/') ||
        lower.contains('youtube.com/shorts/') ||
        lower.contains('m.youtube.com/watch') ||
        isPlaylistUrl(url);
  }

  static bool isYoutubeVideoUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('youtube.com/watch') ||
        lower.contains('youtu.be/') ||
        lower.contains('youtube.com/shorts/') ||
        lower.contains('m.youtube.com/watch');
  }

  static bool isPlaylistUrl(String url) {
    final lower = url.toLowerCase();
    if (!lower.contains('youtube.com') && !lower.contains('youtu.be')) {
      return false;
    }
    try {
      final uri = Uri.parse(url);
      final listParam = uri.queryParameters['list'];
      return listParam != null && listParam.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  // ──────────────────────── ID Extraction ────────────────────────────

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

  static String? extractPlaylistId(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.queryParameters['list'];
    } catch (_) {
      return null;
    }
  }

  // ───────────────────────── Quality Helpers ─────────────────────────

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

  // ──────────────────── Single Video Streams ────────────────────────

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
          'quality': qLabel,
          'type': 'muxed',
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
          'quality': '${kbps}kbps',
          'type': 'audio',
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
          'quality': qLabel,
          'type': 'video_only',
        });
      }

      return list;
    } catch (_) {
      return [];
    }
  }

  // ───────────────────── Playlist Info ───────────────────────────────

  /// Returns basic playlist metadata.
  static Future<Map<String, dynamic>?> getPlaylistInfo(String url) async {
    final playlistId = extractPlaylistId(url);
    if (playlistId == null) return null;

    try {
      final playlist = await _yt.playlists.get(playlistId);
      return {
        'id': playlist.id.value,
        'title': playlist.title,
        'author': playlist.author,
        'videoCount': playlist.videoCount ?? 0,
        'thumbnailUrl': playlist.thumbnails.highResUrl,
      };
    } catch (_) {
      return null;
    }
  }

  /// Returns all videos in a playlist as a lightweight list.
  /// Each entry has: id, title, author, duration (seconds), thumbnailUrl.
  static Future<List<Map<String, dynamic>>> getPlaylistVideos(String url) async {
    final playlistId = extractPlaylistId(url);
    if (playlistId == null) return [];

    try {
      final videos = <Map<String, dynamic>>[];
      await for (final video in _yt.playlists.getVideos(playlistId)) {
        videos.add({
          'id': video.id.value,
          'title': video.title,
          'author': video.author,
          'duration': video.duration?.inSeconds ?? 0,
          'thumbnailUrl': video.thumbnails.highResUrl,
          'selected': true,
        });
      }
      return videos;
    } catch (_) {
      return [];
    }
  }

  /// Fetches the best stream URL for a given video ID and quality preference.
  /// [qualityPreset] can be: 'best_muxed', '720p', '480p', '360p', 'audio_only'.
  static Future<Map<String, dynamic>?> getStreamForVideo(
    String videoId,
    String qualityPreset,
  ) async {
    try {
      final manifest = await _yt.videos.streamsClient.getManifest(videoId);

      String title = 'YouTube Video';
      try {
        final video = await _yt.videos.get(videoId);
        title = video.title;
      } catch (_) {}

      if (qualityPreset == 'audio_only') {
        // Pick highest bitrate audio
        if (manifest.audioOnly.isEmpty) return null;
        final sorted = manifest.audioOnly.toList()
          ..sort((a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
        final stream = sorted.first;
        return {
          'src': stream.url.toString(),
          'label': 'Audio Only: (${stream.bitrate.kiloBitsPerSecond.round()} Kbps)',
          'size': stream.size.totalBytes,
          'ext': stream.container.name,
          'title': title,
          'type': 'audio',
        };
      }

      // For muxed streams, find the requested quality or best available
      if (manifest.muxed.isEmpty) return null;

      final targetQualities = switch (qualityPreset) {
        '360p' => ['360p', '480p', '240p', '720p'],
        '480p' => ['480p', '360p', '720p', '240p'],
        '720p' => ['720p', '480p', '1080p', '360p'],
        _ => <String>[], // best_muxed — use the highest available
      };

      MuxedStreamInfo? chosen;
      if (targetQualities.isNotEmpty) {
        for (final target in targetQualities) {
          for (final stream in manifest.muxed) {
            if (_formatQuality(stream.videoQuality) == target) {
              chosen = stream;
              break;
            }
          }
          if (chosen != null) break;
        }
      }

      // Fallback: pick the highest quality muxed stream
      chosen ??= (manifest.muxed.toList()
            ..sort((a, b) => b.videoQuality.index.compareTo(a.videoQuality.index)))
          .first;

      final qLabel = _formatQuality(chosen.videoQuality);
      return {
        'src': chosen.url.toString(),
        'label': 'Video: $qLabel (Muxed)',
        'size': chosen.size.totalBytes,
        'ext': chosen.container.name,
        'title': title,
        'type': 'muxed',
        'quality': qLabel,
      };
    } catch (_) {
      return null;
    }
  }

  /// Formats a duration in seconds to a readable string like "3:45" or "1:02:30".
  static String formatDuration(int totalSeconds) {
    if (totalSeconds <= 0) return '0:00';
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
