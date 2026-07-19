import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:webview_cookie_manager/webview_cookie_manager.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'package:http/http.dart' as http;

class YoutubeService {
  static String? _apiKey;
  static String? _cachedPlaylistId;
  static Map<String, dynamic>? _cachedPlaylistDetails;
  static DateTime? _cacheTimestamp;

  YoutubeService({String? apiKey}) {
    if (apiKey != null) {
      _apiKey = apiKey;
    }
  }

  static String? get effectiveApiKey {
    if (_innerTubeApiKeyOverride != null && _innerTubeApiKeyOverride!.isNotEmpty) {
      return _innerTubeApiKeyOverride;
    }
    if (_apiKey != null && _apiKey!.isNotEmpty) {
      return _apiKey;
    }
    const envKey = String.fromEnvironment('YOUTUBE_API_KEY');
    if (envKey.isNotEmpty) return envKey;
    try {
      final sysEnvKey = Platform.environment['YOUTUBE_API_KEY'];
      if (sysEnvKey != null && sysEnvKey.isNotEmpty) return sysEnvKey;
    } catch (_) {}
    return null;
  }

  static YoutubeExplode _yt = YoutubeExplode();

  static String? _cookies;

  static YoutubeExplode _createYt() {
    if (_cookies == null) return YoutubeExplode();
    final cookieClient = _CookieClient(_cookies!);
    final client = YoutubeHttpClient(cookieClient);
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

  /// Recreates the [YoutubeExplode] instance, busting any internal manifest
  /// cache. Call this before refreshing an expired stream URL so that the
  /// library fetches a fresh manifest from YouTube instead of returning a
  /// cached (and still-expired) response.
  static void resetClient() {
    _yt.close();
    _yt = _createYt();
  }

  /// Whether the service currently has authentication cookies set.
  static bool get isSignedIn => _cookies != null;

  /// Extracts cookies directly from the native WebView cookie jar
  /// using `webview_cookie_manager` and signs into YouTube. This handles
  /// HttpOnly cookies like __Secure-3PSID successfully.
  static Future<void> authenticateFromBrowser() async {
    try {
      final cookieManager = WebviewCookieManager();
      final cookies = await cookieManager.getCookies('https://youtube.com');
      final cookieStr = cookies.map((c) => '${c.name}=${c.value}').join('; ');
      if (cookieStr.isNotEmpty) {
        signIn(cookieStr);
      }
    } catch (e) {
      debugPrint('Failed to authenticate YouTube from browser cookies: $e');
    }
  }

  /// Signs in using cookies from a proper cookie list (e.g. from CookieManager).
  /// Use this instead of [signInFromBrowser] when you need HttpOnly cookies.
  static void signInFromCookieManager(List<Cookie> cookies) {
    final cookieStr = cookies.map((c) => '${c.name}=${c.value}').join('; ');
    if (cookieStr.isNotEmpty) signIn(cookieStr);
  }

  /// Returns the current YouTube auth cookie for display/debug, or null.
  static String? get currentCookies => _cookies;

  // ───────────────────────── URL Detection ──────────────────────────

  static bool isYoutubeUrl(String url) {
    return isYoutubeVideoUrl(url) || isPlaylistUrl(url);
  }

  static bool isYoutubeVideoUrl(String url) {
    return extractVideoId(url) != null;
  }

  /// Returns true when the URL contains a YouTube playlist ID (`list=` param).
  /// This includes mixed watch+list URLs like `watch?v=xxx&list=PLyyy` that
  /// are commonly encountered when browsing within a playlist.
  static bool isPlaylistUrl(String url) {
    return extractPlaylistId(url) != null;
  }

  /// Returns true when the URL is a playlist-only page (no individual video
  /// selected), e.g. `youtube.com/playlist?list=PLxxx`.
  static bool isPurePlaylistUrl(String url) {
    return extractPlaylistId(url) != null && extractVideoId(url) == null;
  }

  // ──────────────────────── ID Extraction ────────────────────────────

  static String? extractVideoId(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.host == 'youtu.be' || uri.host.endsWith('.youtu.be')) {
        if (uri.pathSegments.isNotEmpty) {
          return uri.pathSegments.first;
        }
      }
      if (uri.path.contains('shorts')) {
        final parts = uri.pathSegments;
        final shortsIdx = parts.indexOf('shorts');
        if (shortsIdx >= 0 && shortsIdx + 1 < parts.length) {
          return parts[shortsIdx + 1];
        }
      }
      // Handle /embed/, /v/, /live/ path-based IDs
      for (final prefix in ['/embed/', '/v/', '/live/']) {
        final path = uri.path;
        final idx = path.indexOf(prefix);
        if (idx >= 0) {
          final afterPrefix = path.substring(idx + prefix.length);
          final slashIdx = afterPrefix.indexOf('/');
          return slashIdx >= 0
              ? afterPrefix.substring(0, slashIdx)
              : afterPrefix;
        }
      }
      final v = uri.queryParameters['v'];
      if (v != null) return v;
    } catch (_) {}

    // Fallback regex matching in case queries are structured differently
    final regex = RegExp(
      r'(?:youtube\.com\/(?:[^\/]+\/.+\/|(?:v|e(?:mbed)?)\/|.*[?&]v=)|youtu\.be\/)([^"&?\/\s]{11})',
    );
    final match = regex.firstMatch(url);
    if (match != null && match.groupCount >= 1) {
      return match.group(1);
    }
    return null;
  }

  static String? extractPlaylistId(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.queryParameters['list'];
    } catch (_) {
      return null;
    }
  }

  /// Constructs a YouTube watch URL from a video ID.
  static String videoUrl(String videoId) =>
      'https://www.youtube.com/watch?v=$videoId';

  // ───────────────────────── Quality Helpers ─────────────────────────

  static String _formatQuality(VideoQuality q) {
    final name = q.name.toLowerCase();
    if (name.contains('2160') || name == 'high2160') return '4K';
    if (name.contains('1440') || name == 'high1440') return '1440p';
    if (name.contains('1080') || name == 'high1080') return '1080p';
    if (name.contains('720') || name == 'high720') return '720p';
    if (name.contains('480') || name == 'medium480') return '480p';
    if (name.contains('360') || name == 'medium360') return '360p';
    if (name.contains('240') || name == 'low240') return '240p';
    if (name == 'low144') return '144p';
    if (name.contains('144')) return '144p';
    return q.name;
  }

  // ──────────────────────── Cleanup ─────────────────────────────────

  /// Closes the underlying HTTP client. Call this when the service
  /// is no longer needed to prevent the Dart process from hanging.
  static void close() {
    _yt.close();
    _InnerTubeFallback.close();
  }

  // ────────────────────── Logging / Troubleshooting ─────────────────

  static bool _loggingEnabled = false;

  /// Enables verbose logging from YoutubeExplode.
  /// Call this before any other YoutubeService method.
  static void enableLogging() {
    if (_loggingEnabled) return;
    _loggingEnabled = true;
    Logger('YoutubeExplode').level = Level.FINER;
    Logger('YoutubeExplode').onRecord.listen((e) {
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

  // ──────────────────── Fallback & Refresh Helpers ──────────────────

  static Future<({StreamManifest manifest, String title})> _fetchWithFallback(
    String videoId,
  ) async {
    // Retry up to 2 times on transient failures
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        return await _fetchWithFallbackInternal(videoId);
      } catch (e) {
        if (attempt == 1) rethrow;
        final errStr = e.toString().toLowerCase();
        // Only retry on transient errors
        if (errStr.contains('timeout') ||
            errStr.contains('connection') ||
            errStr.contains('socket') ||
            errStr.contains('reset')) {
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        rethrow;
      }
    }
    throw Exception('Failed after retries');
  }

  static Future<({StreamManifest manifest, String title})>
  _fetchWithFallbackInternal(String videoId) async {
    StreamManifest? manifest;
    const timeout = Duration(seconds: 8);
    Object? lastError;

    final clientsToTry = [
      null, // default
      [YoutubeApiClient.android],
      [YoutubeApiClient.ios],
      [YoutubeApiClient.safari],
      [YoutubeApiClient.tv],
      [YoutubeApiClient.mweb],
    ];

    for (final clients in clientsToTry) {
      try {
        if (clients == null) {
          manifest = await _yt.videos.streamsClient
              .getManifest(videoId)
              .timeout(timeout);
        } else {
          manifest = await _yt.videos.streamsClient
              .getManifest(videoId, ytClients: clients)
              .timeout(timeout);
        }
        if (manifest.streams.isNotEmpty) {
          break; // Found working manifest!
        }
      } catch (e) {
        lastError = e;
        Logger.root.warning(
          'YoutubeService._fetchWithFallback: getManifest failed for client $clients: $e',
        );
      }
    }

    // Last resort: require the watch page
    if (manifest == null || manifest.streams.isEmpty) {
      try {
        manifest = await _yt.videos.streamsClient
            .getManifest(videoId, requireWatchPage: true)
            .timeout(const Duration(seconds: 30));
      } catch (e) {
        lastError = e;
        Logger.root.warning(
          'YoutubeService._fetchWithFallback: requireWatchPage fallback failed: $e',
        );
      }
    }

    if (manifest == null || manifest.streams.isEmpty) {
      if (lastError != null) {
        final errStr = lastError.toString().toLowerCase();
        if (errStr.contains('age') ||
            errStr.contains('restricted') ||
            errStr.contains('agerecorded') ||
            errStr.contains('signin') ||
            errStr.contains('sign in')) {
          throw Exception('This video is age-restricted and requires sign-in.');
        } else if (errStr.contains('private')) {
          throw Exception('This video is private.');
        } else if (errStr.contains('geo') ||
            errStr.contains('blocked') ||
            errStr.contains('country')) {
          throw Exception(
            'This video is not available in your country/region.',
          );
        } else {
          throw Exception('Failed to get manifest: $lastError');
        }
      }
      throw Exception('No playable streams found.');
    }

    // Fetch Video Title
    String title = 'YouTube Video';
    try {
      final video = await _yt.videos
          .get(videoId)
          .timeout(const Duration(seconds: 15));
      title = video.title;
    } catch (_) {}

    return (manifest: manifest, title: title);
  }

  /// Refreshes an expired stream URL by fetching the latest manifest and matching the itag.
  /// Refreshes an expired stream URL by fetching the latest manifest.
  ///
  /// First tries to match by `itag` query parameter. If that fails, falls
  /// back to returning a fresh URL from a stream of the same type as
  /// [oldStreamUrl] (muxed / video‑only / audio‑only). This avoids retrying
  /// the same expired URL when the itag is absent from the URL format.
  static Future<Map<String, dynamic>?> refreshStreamUrl(
    String downloadPageUrl,
    String oldStreamUrl,
  ) async {
    final videoId = extractVideoId(downloadPageUrl);
    if (videoId == null) return null;

    try {
      final result = await _fetchWithFallback(videoId);
      final manifest = result.manifest;

      final oldUri = Uri.tryParse(oldStreamUrl);
      if (oldUri == null) return null;

      final oldItag = oldUri.queryParameters['itag'];
      Logger.root.info(
        'Refreshing stream URL for video $videoId, itag=$oldItag',
      );

      Map<String, dynamic>? candidate;
      if (oldItag != null) {
        for (final stream in manifest.streams) {
          final newUri = Uri.tryParse(stream.url.toString());
          if (newUri != null && newUri.queryParameters['itag'] == oldItag) {
            candidate = {
              'url': stream.url.toString(),
              'size': stream.size.totalBytes,
            };
            break;
          }
        }
      }

      // Fallback: itag not found or absent. Return a fresh URL from the
      // same stream type so the download never stalls on an expired URL.
      if (candidate == null) {
        final fallbackStream = _firstStreamByType(manifest, oldStreamUrl);
        if (fallbackStream != null) {
          candidate = {
            'url': fallbackStream.url.toString(),
            'size': fallbackStream.size.totalBytes,
          };
        }
      }

      // Guard: if the library returned the exact same URL, the manifest is
      // stale / cached. Treat this as a failed refresh so the caller can
      // escalate to getFreshStreams (which recreates the client).
      if (candidate != null && _urlsAreEquivalent(candidate['url'] as String, oldStreamUrl)) {
        Logger.root.warning(
          'refreshStreamUrl: new URL is identical to old URL — manifest is stale. Returning null.',
        );
        return null;
      }

      return candidate;
    } catch (e) {
      Logger.root.severe('Failed to refresh YouTube stream URL: $e');
    }
    return null;
  }

  /// Returns true when two YouTube stream URLs are equivalent (same `expire`
  /// and `sig` parameters), meaning they will produce the same result.
  static bool _urlsAreEquivalent(String a, String b) {
    final ua = Uri.tryParse(a);
    final ub = Uri.tryParse(b);
    if (ua == null || ub == null) return a == b;
    
    final expireA = ua.queryParameters['expire'];
    final expireB = ub.queryParameters['expire'];
    final sigA = ua.queryParameters['sig'];
    final sigB = ub.queryParameters['sig'];
    
    if (expireA == null || expireB == null || sigA == null || sigB == null) {
      return a == b;
    }
    
    // Compare the parts that actually determine freshness.
    return expireA == expireB && sigA == sigB;
  }

  /// Fetches completely fresh stream URLs for a YouTube video, bypassing any
  /// attempt to match the old URL. Used as a last‑resort fallback when
  /// [refreshStreamUrl] fails so the download gets a working URL from scratch.
  ///
  /// Returns a map with `'url'` and optionally `'audioUrl'`, or `null` if no
  /// streams are available.
  static Future<Map<String, String?>?> getFreshStreams(
    String downloadPageUrl,
  ) async {
    final videoId = extractVideoId(downloadPageUrl);
    if (videoId == null) return null;

    try {
      final result = await _fetchWithFallback(videoId);
      final manifest = result.manifest;

      // Prefer muxed (simplest — single URL)
      if (manifest.muxed.isNotEmpty) {
        return {'url': manifest.muxed.first.url.toString(), 'audioUrl': null};
      }

      // Combined: best video-only + best audio
      if (manifest.videoOnly.isNotEmpty && manifest.audioOnly.isNotEmpty) {
        final sorted = manifest.audioOnly.toList()
          ..sort((a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
        return {
          'url': manifest.videoOnly.first.url.toString(),
          'audioUrl': sorted.first.url.toString(),
        };
      }

      // Video-only (no audio available — rare)
      if (manifest.videoOnly.isNotEmpty) {
        return {'url': manifest.videoOnly.first.url.toString(), 'audioUrl': null};
      }

      // Audio-only
      if (manifest.audioOnly.isNotEmpty) {
        return {'url': manifest.audioOnly.first.url.toString(), 'audioUrl': null};
      }
    } catch (e) {
      Logger.root.severe('Failed to get fresh YouTube streams: $e');
    }
    return null;
  }

  /// Returns the first URL from the manifest whose stream type matches the
  /// nature of [oldStreamUrl] (muxed / video‑only / audio‑only).
  static StreamInfo? _firstStreamByType(
    StreamManifest manifest,
    String oldStreamUrl,
  ) {
    final lower = oldStreamUrl.toLowerCase();

    // Heuristic: audio-only stream URLs often contain "mime=audio".
    final isAudio =
        lower.contains('mime%3Daudio') || lower.contains('mime=audio');
    if (isAudio) {
      if (manifest.audioOnly.isNotEmpty) return manifest.audioOnly.first;
    }

    // Return muxed first (preferred), then video-only.
    if (manifest.muxed.isNotEmpty) return manifest.muxed.first;
    if (manifest.videoOnly.isNotEmpty) return manifest.videoOnly.first;
    if (manifest.audioOnly.isNotEmpty) return manifest.audioOnly.first;
    return null;
  }

  // ──────────────────── Single Video Streams ────────────────────────

  static Future<List<Map<String, dynamic>>> getStreams(String url) async {
    final videoId = extractVideoId(url);
    if (videoId == null) return [];

    final result = await _fetchWithFallback(videoId);
    final manifest = result.manifest;
    final title = result.title;
    final list = <Map<String, dynamic>>[];

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

    // Combined streams (video-only + best audio-only) for higher qualities
    if (manifest.videoOnly.isNotEmpty && manifest.audioOnly.isNotEmpty) {
      final sortedAudio = manifest.audioOnly.toList()
        ..sort(
          (a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond),
        );
      final bestAudio = sortedAudio.first;
      for (final stream in manifest.videoOnly) {
        final qLabel = _formatQuality(stream.videoQuality);
        list.add({
          'src': stream.url.toString(),
          'audioSrc': bestAudio.url.toString(),
          'label': 'Video: $qLabel + Audio (Best)',
          'size': stream.size.totalBytes + bestAudio.size.totalBytes,
          'ext': stream.container.name,
          'title': title,
          'quality': qLabel,
          'type': 'combined',
          'videoSize': stream.size.totalBytes,
          'audioSize': bestAudio.size.totalBytes,
          'audioExt': bestAudio.container.name,
        });
      }
    }

    return list;
  }

  // ───────────────────── Playlist Info ───────────────────────────────

  /// Returns both playlist metadata and the list of videos in a single unified flow.
  /// Result contains:
  /// - 'info': basic metadata Map (id, title, author, videoCount, thumbnailUrl)
  /// - 'videos': List of video maps (id, title, author, duration, thumbnailUrl, selected)
  static Future<Map<String, dynamic>?> getPlaylistDetails(String url) async {
    final playlistId = extractPlaylistId(url);
    if (playlistId == null) return null;

    final now = DateTime.now();
    if (_cachedPlaylistId == playlistId &&
        _cachedPlaylistDetails != null &&
        _cacheTimestamp != null &&
        now.difference(_cacheTimestamp!) < const Duration(seconds: 60)) {
      return _cachedPlaylistDetails;
    }

    // Try InnerTube fallback first (more reliable, faster, and consolidated)
    try {
      final details = await _InnerTubeFallback.getPlaylistDetails(playlistId);
      if (details != null && (details['videos'] as List).isNotEmpty) {
        _cachedPlaylistId = playlistId;
        _cachedPlaylistDetails = details;
        _cacheTimestamp = now;
        return details;
      }
    } catch (e) {
      Logger.root.warning(
        'YoutubeService.getPlaylistDetails fallback failed: $e',
      );
    }

    // Library fallback (last resort backup)
    try {
      final playlist = await _yt.playlists
          .get(playlistId)
          .timeout(const Duration(seconds: 15));
      if (playlist.title.isNotEmpty) {
        final videos = <Map<String, dynamic>>[];
        try {
          final stream = _yt.playlists.getVideos(playlistId);
          await for (final video in stream.timeout(
            const Duration(seconds: 15),
          )) {
            videos.add({
              'id': video.id.value,
              'title': video.title,
              'author': video.author,
              'duration': video.duration?.inSeconds ?? 0,
              'thumbnailUrl': video.thumbnails.highResUrl,
              'selected': true,
            });
          }
        } catch (_) {}

        final details = {
          'info': {
            'id': playlist.id.value,
            'title': playlist.title,
            'author': playlist.author,
            'videoCount': playlist.videoCount ?? 0,
            'thumbnailUrl': playlist.thumbnails.highResUrl,
          },
          'videos': videos,
        };
        
        _cachedPlaylistId = playlistId;
        _cachedPlaylistDetails = details;
        _cacheTimestamp = now;
        return details;
      }
    } catch (e) {
      Logger.root.warning(
        'YoutubeService.getPlaylistDetails library failed: $e',
      );
    }

    return null;
  }

  /// Returns basic playlist metadata.
  static Future<Map<String, dynamic>?> getPlaylistInfo(String url) async {
    final details = await getPlaylistDetails(url);
    return details?['info'] as Map<String, dynamic>?;
  }

  /// Returns all videos in a playlist as a lightweight list.
  /// Each entry has: id, title, author, duration (seconds), thumbnailUrl.
  static Future<List<Map<String, dynamic>>> getPlaylistVideos(
    String url,
  ) async {
    final details = await getPlaylistDetails(url);
    return (details?['videos'] as List<Map<String, dynamic>>?) ?? [];
  }

  /// Fetches the best stream URL for a given video ID and quality preference.
  /// [qualityPreset] can be: 'best_combined', 'best_muxed', '720p', '480p', '360p', 'audio_only'.
  static Future<Map<String, dynamic>?> getStreamForVideo(
    String videoId,
    String qualityPreset, {
    bool forceMuxed = false,
  }) async {
    final result = await _fetchWithFallback(videoId);
    final manifest = result.manifest;
    final title = result.title;

    if (qualityPreset == 'audio_only') {
      if (manifest.audioOnly.isEmpty) return null;
      final sorted = manifest.audioOnly.toList()
        ..sort(
          (a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond),
        );
      final stream = sorted.first;
      return {
        'src': stream.url.toString(),
        'label':
            'Audio Only: (${stream.bitrate.kiloBitsPerSecond.round()} Kbps)',
        'size': stream.size.totalBytes,
        'ext': stream.container.name,
        'title': title,
        'type': 'audio',
      };
    }

    if (qualityPreset == 'best_combined') {
      forceMuxed = false;
    }

    // For muxed streams, find the requested quality or best available
    MuxedStreamInfo? chosen;

    if (manifest.muxed.isNotEmpty && 
        (qualityPreset == 'best_combined' || qualityPreset == 'best_muxed' || 
         ['1080p', '720p', '480p', '360p'].contains(qualityPreset))) {
      final targetQualities = switch (qualityPreset) {
        '1080p' => ['1080p', '720p', '480p', '360p', '240p'],
        '720p' => ['720p', '480p', '360p', '240p', '1080p'],
        '480p' => ['480p', '360p', '240p', '720p', '1080p'],
        '360p' => ['360p', '240p', '480p', '720p', '1080p'],
        _ => <String>[], // best_muxed — use the highest available
      };

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

      chosen ??=
          (manifest.muxed.toList()..sort(
                (a, b) => b.videoQuality.index.compareTo(a.videoQuality.index),
              ))
              .first;
    }

    // If muxed found, return it
    if (chosen != null) {
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

    if (forceMuxed) {
      return null;
    }

    // Fallback: combine video-only + audio-only for the requested quality
    if (manifest.videoOnly.isNotEmpty && manifest.audioOnly.isNotEmpty) {
      final targetQualities = switch (qualityPreset) {
        '360p' => ['360p', '480p', '240p', '720p'],
        '480p' => ['480p', '360p', '720p', '240p'],
        '720p' => ['720p', '480p', '1080p', '360p'],
        '1080p' => ['1080p', '720p', '1440p', '2160p', '480p', '360p'],
        _ => <String>[],
      };

      VideoOnlyStreamInfo? chosenVideo;
      if (targetQualities.isNotEmpty) {
        for (final target in targetQualities) {
          for (final stream in manifest.videoOnly) {
            if (_formatQuality(stream.videoQuality) == target) {
              chosenVideo = stream;
              break;
            }
          }
          if (chosenVideo != null) break;
        }
      } else {
        // best_muxed — use highest video-only
        final sorted = manifest.videoOnly.toList()
          ..sort(
            (a, b) => b.videoQuality.index.compareTo(a.videoQuality.index),
          );
        chosenVideo = sorted.first;
      }

      if (chosenVideo != null) {
        final sortedAudio = manifest.audioOnly.toList()
          ..sort(
            (a, b) =>
                b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond),
          );
        final bestAudio = sortedAudio.first;
        final qLabel = _formatQuality(chosenVideo.videoQuality);
        return {
          'src': chosenVideo.url.toString(),
          'audioSrc': bestAudio.url.toString(),
          'label': 'Video: $qLabel + Audio (Best)',
          'size': chosenVideo.size.totalBytes + bestAudio.size.totalBytes,
          'videoSize': chosenVideo.size.totalBytes,
          'audioSize': bestAudio.size.totalBytes,
          'ext': chosenVideo.container.name,
          'audioExt': bestAudio.container.name,
          'title': title,
          'type': 'combined',
          'quality': qLabel,
        };
      }
    }

    return null;
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
  @Deprecated('Not supported by the current map-based API approach.')
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
class _CookieClient extends http.BaseClient {
  final String _cookie;
  final http.Client _inner = http.Client();

  _CookieClient(this._cookie);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['cookie'] = _cookie;
    debugPrint('[YoutubeService] Outgoing request to ${request.url} with headers: ${request.headers}');
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}

String? _innerTubeApiKeyOverride;

/// Override the default InnerTube API key. Call this to hot-patch if
/// YouTube rotates the key without a full app release.
void updateInnerTubeApiKey(String key) {
  _innerTubeApiKeyOverride = key;
}

/// Direct InnerTube API fallback for when youtube_explode_dart's parsing
/// is broken due to YouTube HTML/API changes.
///
/// YouTube migrated playlists to use `lockupViewModel` instead of
/// `playlistVideoRenderer` for video items, which breaks the library.
/// This fallback parses both formats.
class _InnerTubeFallback {
  static String? get _browseUrl {
    final key = YoutubeService.effectiveApiKey;
    if (key == null || key.isEmpty) return null;
    return 'https://www.youtube.com/youtubei/v1/browse?key=$key';
  }

  static final _log = Logger('YoutubeService._InnerTubeFallback');
  static HttpClient? __client;
  static bool __closed = false;
  static HttpClient get _client {
    if (__client == null || __closed) {
      __client = HttpClient();
      __closed = false;
    }
    return __client!;
  }

  static void close() {
    __client?.close(force: true);
    __closed = true;
  }

  static Map<String, dynamic> _clientContext() => {
    'context': {
      'client': {
        'clientName': 'WEB',
        'clientVersion': '2.20240327.01.00',
        'browserName': 'Chrome',
        'browserVersion': '131.0.0.0',
        'clientFormFactor': 'UNKNOWN_FORM_FACTOR',
      },
    },
  };

  /// Sends a POST to the InnerTube browse endpoint and returns the JSON body.
  static Future<Map<String, dynamic>> _browse(
    String browseId, {
    String? continuationToken,
  }) async {
    final url = _browseUrl;
    if (url == null) {
      throw Exception('InnerTube API key not configured.');
    }
    final request = await _client.postUrl(Uri.parse(url));
    request.headers.set('Content-Type', 'application/json');
    request.headers.set(
      'User-Agent',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/131.0.0.0 Safari/537.36',
    );

    // Inject authenticated cookies if available
    if (YoutubeService.currentCookies != null) {
      request.headers.set('cookie', YoutubeService.currentCookies!);
    }

    final body = <String, dynamic>{..._clientContext()};
    if (continuationToken != null) {
      body['continuation'] = continuationToken;
    } else {
      body['browseId'] = browseId;
    }

    request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 30));
    final raw = await response.transform(utf8.decoder).join();
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Fetches basic metadata and all videos in a single unified flow.
  static Future<Map<String, dynamic>?> getPlaylistDetails(
    String playlistId,
  ) async {
    final key = YoutubeService.effectiveApiKey;
    if (key == null || key.isEmpty) {
      _log.warning('No InnerTube API key provided, skipping fallback.');
      return null;
    }
    // First request
    Map<String, dynamic> data;
    try {
      data = await _browse('VL$playlistId');
    } catch (e) {
      _log.warning('InnerTube fallback browse failed: $e');
      return null;
    }

    // Check for error alerts (e.g. "The playlist does not exist.")
    final alerts = data['alerts'] as List?;
    if (alerts != null && alerts.isNotEmpty) {
      final alertType =
          (alerts[0] as Map?)?['alertRenderer']?['type'] as String?;
      if (alertType == 'ERROR') {
        _log.warning('Playlist $playlistId: alert ERROR');
        return null;
      }
    }

    // Extract title from metadata
    final title =
        _extractString(data, 'metadata/playlistMetadataRenderer/title') ?? '';

    // Extract author from header or sidebar
    String author = '';
    final header = data['header'] as Map?;
    if (header != null) {
      if (header.containsKey('playlistHeaderRenderer')) {
        final ownerRuns = _extractList(
          header['playlistHeaderRenderer'] as Map,
          'ownerText/runs',
        );
        if (ownerRuns != null && ownerRuns.isNotEmpty) {
          author = (ownerRuns[0] as Map?)?['text'] as String? ?? '';
        }
      }
    }
    if (author.isEmpty) {
      // Try sidebar secondary info
      final sidebarItems = _extractList(
        data,
        'sidebar/playlistSidebarRenderer/items',
      );
      if (sidebarItems != null && sidebarItems.length > 1) {
        final ownerRuns = _extractList(
          sidebarItems[1] as Map,
          'playlistSidebarSecondaryInfoRenderer/videoOwner/videoOwnerRenderer/title/runs',
        );
        if (ownerRuns != null && ownerRuns.isNotEmpty) {
          author = (ownerRuns[0] as Map?)?['text'] as String? ?? '';
        }
      }
    }

    // Extract video count from header or sidebar stats
    int videoCount = 0;
    if (header != null && header.containsKey('playlistHeaderRenderer')) {
      final numRuns = _extractList(
        header['playlistHeaderRenderer'] as Map,
        'numVideosText/runs',
      );
      if (numRuns != null && numRuns.isNotEmpty) {
        videoCount =
            int.tryParse(
              (numRuns[0] as Map?)?['text']?.toString().replaceAll(',', '') ??
                  '',
            ) ??
            0;
      }
    }
    if (videoCount == 0) {
      final sidebarItems = _extractList(
        data,
        'sidebar/playlistSidebarRenderer/items',
      );
      if (sidebarItems != null && sidebarItems.isNotEmpty) {
        final stats = _extractList(
          sidebarItems[0] as Map,
          'playlistSidebarPrimaryInfoRenderer/stats',
        );
        if (stats != null && stats.isNotEmpty) {
          final firstStatRuns = _extractList(stats[0] as Map, 'runs');
          if (firstStatRuns != null && firstStatRuns.isNotEmpty) {
            videoCount =
                int.tryParse(
                  (firstStatRuns[0] as Map?)?['text']?.toString().replaceAll(
                        ',',
                        '',
                      ) ??
                      '',
                ) ??
                0;
          }
        }
      }
    }

    // Get thumbnail from first video
    final videoItems = _extractVideoItems(data);
    String thumbnailUrl = '';
    if (videoItems.isNotEmpty) {
      thumbnailUrl = _extractThumbnailUrl(videoItems.first);
    }

    final info = {
      'id': playlistId,
      'title': title,
      'author': author,
      'videoCount': videoCount,
      'thumbnailUrl': thumbnailUrl,
    };

    final allVideos = <Map<String, dynamic>>[];
    String? continuationToken;
    var pageNum = 0;
    const maxPages = 50; // Safety limit (~5000 videos)

    while (pageNum < maxPages) {
      List<Map<String, dynamic>> items;
      if (pageNum == 0) {
        items = videoItems;
        continuationToken = _extractContinuationToken(
          data,
          isContinuation: false,
        );
      } else {
        items = _extractVideoItems(data);
        continuationToken = _extractContinuationToken(
          data,
          isContinuation: true,
        );
      }

      for (final item in items) {
        final video = _parseVideoItem(item, author);
        if (video != null) allVideos.add(video);
      }

      if (continuationToken == null || continuationToken.isEmpty) break;

      pageNum++;
      try {
        data = await _browse(
          'VL$playlistId',
          continuationToken: continuationToken,
        );
      } catch (e) {
        _log.warning(
          'InnerTube fallback browse continuation failed at page $pageNum: $e',
        );
        break;
      }
    }

    return {'info': info, 'videos': allVideos};
  }

  // ──────────────── Parsing helpers ──────────────────

  /// Extracts the flat list of video items from a browse response,
  /// handling both initial and continuation formats.
  static List<Map<String, dynamic>> _extractVideoItems(
    Map<String, dynamic> data,
  ) {
    // Continuation responses
    final actions =
        (data['onResponseReceivedActions'] as List?) ??
        (data['onResponseReceivedCommands'] as List?);
    if (actions != null) {
      for (final action in actions) {
        final actionMap = action as Map?;
        final items =
            actionMap?['appendContinuationItemsAction']?['continuationItems']
                as List? ??
            actionMap?['reloadContinuationItemsCommand']?['continuationItems']
                as List?;
        if (items != null) {
          return items.whereType<Map<String, dynamic>>().toList();
        }
      }
    }

    // Initial page: tabs → sectionList → itemSection
    final tabs = _extractList(
      data,
      'contents/twoColumnBrowseResultsRenderer/tabs',
    );
    if (tabs == null) return [];

    for (final tab in tabs) {
      final sections = _extractList(
        tab as Map,
        'tabRenderer/content/sectionListRenderer/contents',
      );
      if (sections == null) continue;

      for (final section in sections) {
        final itemContents = _extractList(
          section as Map,
          'itemSectionRenderer/contents',
        );
        if (itemContents == null) continue;

        // Old format: playlistVideoListRenderer/contents
        for (final item in itemContents) {
          final pvlContents = _extractList(
            item as Map,
            'playlistVideoListRenderer/contents',
          );
          if (pvlContents != null) {
            return pvlContents.whereType<Map<String, dynamic>>().toList();
          }
        }

        // New format: items are directly lockupViewModels in itemSectionRenderer/contents
        if (itemContents.isNotEmpty &&
            itemContents.first is Map &&
            (itemContents.first as Map).containsKey('lockupViewModel')) {
          return itemContents.whereType<Map<String, dynamic>>().toList();
        }
      }
    }
    return [];
  }

  /// Parses a single video item from either `playlistVideoRenderer` (old)
  /// or `lockupViewModel` (new) format.
  static Map<String, dynamic>? _parseVideoItem(
    Map<String, dynamic> item,
    String fallbackAuthor,
  ) {
    // Old format: playlistVideoRenderer
    final pvr = item['playlistVideoRenderer'] as Map?;
    if (pvr != null) {
      final id = pvr['videoId'] as String? ?? '';
      if (id.isEmpty) return null;
      final title = _parseRuns(pvr['title']?['runs'] as List?);
      final author =
          _parseRuns(pvr['ownerText']?['runs'] as List?) ??
          _parseRuns(pvr['shortBylineText']?['runs'] as List?) ??
          fallbackAuthor;
      final durationText = pvr['lengthText']?['simpleText'] as String?;
      final duration = _parseDuration(durationText);
      final thumbnailUrl = _extractThumbnailUrl(item);
      return {
        'id': id,
        'title': title ?? 'Video',
        'author': author,
        'duration': duration,
        'thumbnailUrl': thumbnailUrl,
        'selected': true,
      };
    }

    // New format: lockupViewModel
    final lockup = item['lockupViewModel'] as Map?;
    if (lockup != null) {
      final id = lockup['contentId'] as String? ?? '';
      if (id.isEmpty) return null;

      final metaVM =
          (lockup['metadata'] as Map?)?['lockupMetadataViewModel'] as Map?;
      final titleMap = metaVM?['title'] as Map?;
      final title = titleMap?['content'] as String? ?? 'Video';

      // Duration from thumbnail overlay
      int duration = 0;
      final overlays =
          (lockup['contentImage'] as Map?)?['thumbnailViewModel']?['overlays']
              as List?;
      if (overlays != null) {
        for (final overlay in overlays) {
          final bottomOverlay =
              (overlay as Map?)?['thumbnailBottomOverlayViewModel'] as Map?;
          if (bottomOverlay != null) {
            final badges = bottomOverlay['badges'] as List?;
            if (badges != null && badges.isNotEmpty) {
              final durationText =
                  (badges[0] as Map?)?['thumbnailBadgeViewModel']?['text']
                      as String?;
              duration = _parseDuration(durationText);
            }
          }
        }
      }

      // Thumbnail URL
      final thumbnailUrl = _extractThumbnailUrl(item);

      return {
        'id': id,
        'title': title,
        'author': fallbackAuthor,
        'duration': duration,
        'thumbnailUrl': thumbnailUrl,
        'selected': true,
      };
    }

    return null; // continuationItemRenderer or unknown format
  }

  /// Extracts the continuation token from the video items list.
  static String? _extractContinuationToken(
    Map<String, dynamic> data, {
    required bool isContinuation,
  }) {
    List<dynamic>? items;

    if (isContinuation) {
      final actions =
          (data['onResponseReceivedActions'] as List?) ??
          (data['onResponseReceivedCommands'] as List?);
      if (actions != null) {
        for (final action in actions) {
          final actionMap = action as Map?;
          items =
              actionMap?['appendContinuationItemsAction']?['continuationItems']
                  as List? ??
              actionMap?['reloadContinuationItemsCommand']?['continuationItems']
                  as List?;
          if (items != null) break;
        }
      }
    } else {
      // Initial page — find in the video list
      final videoItems = _extractVideoItems(data);
      items = videoItems;
    }

    if (items == null) return null;

    for (final item in items) {
      final cont = (item as Map?)?['continuationItemRenderer'] as Map?;
      if (cont != null) {
        final endpoint = cont['continuationEndpoint'] as Map?;
        if (endpoint != null) {
          // Direct token
          final token = endpoint['continuationCommand']?['token'] as String?;
          if (token != null) return token;
          // Nested inside commandExecutorCommand
          final commands =
              endpoint['commandExecutorCommand']?['commands'] as List?;
          if (commands != null) {
            for (final cmd in commands) {
              final t =
                  (cmd as Map?)?['continuationCommand']?['token'] as String?;
              if (t != null) return t;
            }
          }
        }
      }
    }
    return null;
  }

  // ──────────────── Utility helpers ──────────────────

  /// Navigates a nested JSON path like "a/b/c" and returns the value.
  static dynamic _navigate(Map data, String path) {
    dynamic current = data;
    for (final key in path.split('/')) {
      if (current is Map) {
        current = current[key];
      } else if (current is List) {
        final idx = int.tryParse(key);
        if (idx != null && idx < current.length) {
          current = current[idx];
        } else {
          return null;
        }
      } else {
        return null;
      }
    }
    return current;
  }

  static String? _extractString(Map data, String path) {
    final value = _navigate(data, path);
    return value is String ? value : null;
  }

  static List? _extractList(Map data, String path) {
    final value = _navigate(data, path);
    return value is List ? value : null;
  }

  /// Joins text from a "runs" array.
  static String? _parseRuns(List? runs) {
    if (runs == null || runs.isEmpty) return null;
    return runs.map((r) => (r as Map?)?['text'] as String? ?? '').join();
  }

  /// Parses a duration string like "4:00" or "1:23:45" into seconds.
  static int _parseDuration(String? text) {
    if (text == null || text.isEmpty) return 0;
    final parts = text.split(':').map((p) => int.tryParse(p) ?? 0).toList();
    if (parts.length == 3) {
      return parts[0] * 3600 + parts[1] * 60 + parts[2];
    } else if (parts.length == 2) {
      return parts[0] * 60 + parts[1];
    } else if (parts.length == 1) {
      return parts[0];
    }
    return 0;
  }

  /// Extracts the best thumbnail URL from a video item.
  static String _extractThumbnailUrl(Map<String, dynamic> item) {
    // lockupViewModel format
    final lockup = item['lockupViewModel'] as Map?;
    if (lockup != null) {
      final sources =
          (lockup['contentImage']
                  as Map?)?['thumbnailViewModel']?['image']?['sources']
              as List?;
      if (sources != null && sources.isNotEmpty) {
        return (sources.last as Map?)?['url'] as String? ?? '';
      }
      // Fallback: construct from video ID
      final id = lockup['contentId'] as String?;
      if (id != null) return 'https://i.ytimg.com/vi/$id/hqdefault.jpg';
    }

    // playlistVideoRenderer format
    final pvr = item['playlistVideoRenderer'] as Map?;
    if (pvr != null) {
      final thumbnails = (pvr['thumbnail'] as Map?)?['thumbnails'] as List?;
      if (thumbnails != null && thumbnails.isNotEmpty) {
        return (thumbnails.last as Map?)?['url'] as String? ?? '';
      }
      final id = pvr['videoId'] as String?;
      if (id != null) return 'https://i.ytimg.com/vi/$id/hqdefault.jpg';
    }

    return '';
  }
}
