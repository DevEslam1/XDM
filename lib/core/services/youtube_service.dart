import 'package:logging/logging.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class YoutubeService {
  static YoutubeExplode _yt = _createYt();

  static String? _cookies;

  static YoutubeExplode _createYt() {
    if (_cookies == null) return YoutubeExplode();
    final client = _AuthenticatedHttpClient(_cookies!);
    return YoutubeExplode(httpClient: client);
  }

  /// Recreates the underlying [YoutubeExplode] with the given cookie string.
  /// Call this before any stream fetch to access authenticated content.
  ///
  /// To get cookies: sign into YouTube in a browser, open DevTools →
  /// Application → Cookies → copy the full cookie string and pass it here.
  static void signIn(String cookieString) {
    _yt.close();
    _cookies = cookieString;
    _yt = _createYt();
  }

  /// Clears any stored cookies and resets to the default unauthenticated client.
  static void signOut() {
    _yt.close();
    _cookies = null;
    _yt = _createYt();
  }

  /// Whether the service currently has authentication cookies set.
  static bool get isSignedIn => _cookies != null;

  /// Signs in using cookies from the in-app browser's WebView.
  /// Call this immediately after the user navigates to youtube.com
  /// and the page finishes loading.
  ///
  /// To extract cookies from the WebView, inject JavaScript:
  /// ```dart
  /// final cookies = await controller.runJavaScriptReturningResult(
  ///   'document.cookie',
  /// );
  /// YoutubeService.signInFromBrowser(cookies);
  /// ```
  static void signInFromBrowser(String rawDocumentCookie) {
    if (rawDocumentCookie.trim().isEmpty) return;
    signIn(rawDocumentCookie.trim());
  }

  /// Returns the current YouTube auth cookie for display/debug, or null.
  static String? get currentCookies => _cookies;


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

  // ──────────────────────── Cleanup ─────────────────────────────────

  /// Closes the underlying HTTP client. Call this when the service
  /// is no longer needed to prevent the Dart process from hanging.
  static void close() {
    _yt.close();
  }

  // ────────────────────── Logging / Troubleshooting ─────────────────

  /// Enables verbose logging from YoutubeExplode.
  /// Call this before any other YoutubeService method.
  static void enableLogging() {
    Logger.root.level = Level.FINER;
    Logger.root.onRecord.listen((e) {
      // ignore: avoid_print
      print(e);
      if (e.error != null) {
        // ignore: avoid_print
        print(e.error);
        // ignore: avoid_print
        print(e.stackTrace);
      }
    });
  }

  // ──────────────────── Single Video Streams ────────────────────────

  static Future<List<Map<String, dynamic>>> getStreams(String url) async {
    final videoId = extractVideoId(url);
    if (videoId == null) return [];

    StreamManifest? manifest;

    const timeout = Duration(seconds: 12);

    // Try default client first (has internal tv fallback)
    try {
      manifest = await _yt.videos.streamsClient
          .getManifest(videoId)
          .timeout(timeout);
    } catch (_) {
      // Fallback: tv client works for more restrictive videos
      try {
        manifest = await _yt.videos.streamsClient
            .getManifest(videoId, ytClients: [YoutubeApiClient.tv])
            .timeout(timeout);
      } catch (_) {}
    }

    if (manifest == null || manifest.streams.isEmpty) return [];

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
    StreamManifest? manifest;

    const timeout = Duration(seconds: 12);

    try {
      manifest = await _yt.videos.streamsClient
          .getManifest(videoId)
          .timeout(timeout);
    } catch (_) {
      try {
        manifest = await _yt.videos.streamsClient
            .getManifest(videoId, ytClients: [YoutubeApiClient.tv])
            .timeout(timeout);
      } catch (_) {}
    }

    if (manifest == null || manifest.streams.isEmpty) return null;

    String title = 'YouTube Video';
    try {
      final video = await _yt.videos.get(videoId);
      title = video.title;
    } catch (_) {}

    if (qualityPreset == 'audio_only') {
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
  }

  // ──────────────────── Closed Captions ─────────────────────────────

  /// Returns the closed caption manifest for a video.
  /// Use [manifest.tracks] to list all available tracks,
  /// or [manifest.getByLanguage(lang)] to filter.
  static Future<ClosedCaptionManifest?> getClosedCaptionsManifest(
    String url,
  ) async {
    final videoId = extractVideoId(url);
    if (videoId == null) return null;
    try {
      return await _yt.videos.closedCaptions.getManifest(videoId);
    } catch (_) {
      return null;
    }
  }

  /// Returns the actual closed caption track for the given [trackInfo].
  /// Call [track.captions] to list captions, or [track.getByTime(duration)].
  static Future<ClosedCaptionTrack?> getClosedCaptionsTrack(
    ClosedCaptionTrackInfo trackInfo,
  ) async {
    try {
      return await _yt.videos.closedCaptions.get(trackInfo);
    } catch (_) {
      return null;
    }
  }

  /// Shorthand: get caption text at a specific time for a video and language.
  /// Returns the caption text at [position] or null.
  static Future<String?> getClosedCaptionAtTime(
    String url,
    String language,
    Duration position,
  ) async {
    final manifest = await getClosedCaptionsManifest(url);
    if (manifest == null) return null;
    final tracks = manifest.getByLanguage(language);
    if (tracks.isEmpty) return null;
    final track = await getClosedCaptionsTrack(tracks.first);
    return track?.getByTime(position)?.text;
  }

  /// Lists all available closed caption languages for a video.
  static Future<List<Map<String, dynamic>>> getClosedCaptionLanguages(
    String url,
  ) async {
    final manifest = await getClosedCaptionsManifest(url);
    if (manifest == null) return [];
    return manifest.tracks.map((t) {
      return {
        'language': t.language.name,
        'languageCode': t.language.code,
        'isAutoGenerated': t.isAutoGenerated,
        'format': t.format.formatCode,
      };
    }).toList();
  }

  // ───────────────────── Related Videos ─────────────────────────────

  /// Returns related videos for a given YouTube video URL.
  /// Returns null if no related videos are available.
  static Future<List<Map<String, dynamic>>?> getRelatedVideos(
    String url,
  ) async {
    final videoId = extractVideoId(url);
    if (videoId == null) return null;
    try {
      final video = await _yt.videos.get(videoId);
      final related = await _yt.videos.getRelatedVideos(video);
      if (related == null) return null;
      return related.map((v) => _videoToMap(v)).toList();
    } catch (_) {
      return null;
    }
  }

  /// Fetches the next page of related videos from a previous result list.
  /// [currentList] is the raw map list returned by [getRelatedVideos].
  /// Returns null if there are no more pages.
  static Future<List<Map<String, dynamic>>?> getRelatedVideosNextPage(
    List<Map<String, dynamic>> currentList,
  ) async {
    // This requires holding the original RelatedVideosList reference,
    // which isn't possible with the current map-based approach.
    // Users should call getRelatedVideos() again for a fresh fetch.
    return null;
  }

  // ──────────────────── Private Helpers ─────────────────────────────

  static Map<String, dynamic> _videoToMap(Video v) {
    return {
      'id': v.id.value,
      'title': v.title,
      'author': v.author,
      'duration': v.duration?.inSeconds ?? 0,
      'thumbnailUrl': v.thumbnails.highResUrl,
    };
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

/// Internal HTTP client that injects custom cookies for authenticated requests.
class _AuthenticatedHttpClient extends YoutubeHttpClient {
  final String _cookieString;

  _AuthenticatedHttpClient(this._cookieString) : super();

  @override
  Map<String, String> get headers => {
        ...super.headers,
        'cookie': _cookieString,
      };
}
