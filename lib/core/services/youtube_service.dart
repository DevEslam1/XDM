// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:webview_cookie_manager/webview_cookie_manager.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/challenges/ejs/base_ejs_solver.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/challenges/ejs/ejs.dart';

class FlutterJsSolver extends BaseEJSSolver {
  JavascriptRuntime? _jsRuntime;
  bool _initialized = false;
  final _initLock = SynchronizedLock();

  Future<JavascriptRuntime> _getRuntime() async {
    if (_initialized && _jsRuntime != null) {
      return _jsRuntime!;
    }
    return await _initLock.synchronized(() async {
      if (_initialized && _jsRuntime != null) {
        return _jsRuntime!;
      }
      final runtime = getJavascriptRuntime();
      final initScript = await EJSBuilder.getJSModules();
      final evalResult = runtime.evaluate(initScript);
      if (evalResult.isError) {
        throw Exception('Failed to initialize JS runtime for YoutubeExplode: ${evalResult.stringResult}');
      }
      _jsRuntime = runtime;
      _initialized = true;
      return _jsRuntime!;
    });
  }

  @override
  Future<String> executeJavaScript(String jsCode) async {
    return await _initLock.synchronized(() async {
      final runtime = await _getRuntime();
      final evalResult = runtime.evaluate(jsCode);
      if (evalResult.isError) {
        throw Exception('JS Solver evaluation error: ${evalResult.stringResult}');
      }
      return evalResult.stringResult;
    });
  }

  @override
  void dispose() {
    try {
      _jsRuntime?.dispose();
    } catch (_) {}
    _jsRuntime = null;
    _initialized = false;
    super.dispose();
  }
}

class SynchronizedLock {
  Completer<void>? _completer;

  Future<T> synchronized<T>(Future<T> Function() action) async {
    while (_completer != null) {
      await _completer!.future;
    }
    final completer = Completer<void>();
    _completer = completer;
    try {
      return await action();
    } finally {
      _completer = null;
      completer.complete();
    }
  }
}

class YoutubeService {
  static String? _cookies;
  static String? _oauthToken;

  /// The OAuth access token if set via [signInWithOAuth], or null.
  /// Can be used to add an `Authorization: Bearer` header on custom
  /// InnerTube API requests that [youtube_explode_dart] does not
  /// natively support.
  static String? get oauthToken => _oauthToken;
  static final _authStateController = StreamController<bool>.broadcast();
  static YoutubeExplode? _ytInstance;
  static FlutterJsSolver? _jsSolverInstance;

  static YoutubeExplode get _yt {
    _jsSolverInstance ??= FlutterJsSolver();
    _ytInstance ??= YoutubeExplode(jsSolver: _jsSolverInstance);
    return _ytInstance!;
  }

  /// Stream that emits `true` when signed in, `false` when signed out.
  static Stream<bool> get onAuthStateChanged => _authStateController.stream;

  static void _notifyAuthState() {
    _authStateController.add(isSignedIn);
  }

  /// Signs into YouTube with browser cookies.
  static Future<void> signIn(String cookieString) async {
    _cookies = cookieString;
    _notifyAuthState();
  }

  /// Signs in using an OAuth access token from Google Sign-In.
  /// The token is stored as [oauthToken] and should be passed separately
  /// as an `Authorization: Bearer` header (not stuffed into cookies).
  static Future<void> signInWithOAuth(String accessToken) async {
    _oauthToken = accessToken;
    await resetClient();
    _notifyAuthState();
  }

  /// Clears the OAuth token (called on Google sign-out).
  static Future<void> clearOAuth() async {
    _oauthToken = null;
    _notifyAuthState();
  }

  /// Whether the service has an OAuth token set.
  static bool get hasOAuth => _oauthToken != null && _oauthToken!.isNotEmpty;

  /// Signs out from all authentication methods (OAuth + cookies).
  static Future<void> signOut() async {
    _cookies = null;
    _oauthToken = null;
    await resetClient();
    try {
      await WebviewCookieManager().clearCookies();
    } catch (_) {}
    _notifyAuthState();
  }

  /// Refreshes the OAuth token.
  static Future<void> refreshOAuthToken(String newToken) async {
    _oauthToken = newToken;
    _notifyAuthState();
  }

  /// Resets client state.
  static Future<void> resetClient() async {
    _streamsCache.clear();
    try {
      _ytInstance?.close();
    } catch (_) {}
    _ytInstance = null;
    try {
      _jsSolverInstance?.dispose();
    } catch (_) {}
    _jsSolverInstance = null;
  }


  /// Whether the service currently has authentication cookies or OAuth set.
  static bool get isSignedIn =>
      (_cookies != null && _cookies!.isNotEmpty) ||
      (_oauthToken != null && _oauthToken!.isNotEmpty);

  /// Extracts cookies directly from the native WebView cookie jar.
  static Future<void> fetchCookiesFromWebView() async {
    try {
      final cookieManager = WebviewCookieManager();
      final urls = [
        'https://www.youtube.com',
        'https://youtube.com',
        'https://accounts.google.com',
        'https://google.com',
      ];
      final Map<String, String> allCookies = {};

      for (final u in urls) {
        try {
          final cookies = await cookieManager.getCookies(u);
          for (final c in cookies) {
            if (c.name.isNotEmpty && c.value.isNotEmpty) {
              allCookies[c.name] = c.value;
            }
          }
        } catch (_) {}
      }

      if (allCookies.isNotEmpty) {
        final cookieStr =
            allCookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
        await signIn(cookieStr);
      }
    } catch (e) {
      debugPrint('Failed to authenticate YouTube from browser cookies: $e');
    }
  }

  /// Signs in using cookies from a cookie list, or fetches from browser if null.
  static Future<void> authenticateFromBrowser([List<Cookie>? cookies]) async {
    if (cookies != null && cookies.isNotEmpty) {
      await signInFromCookieManager(cookies);
    } else {
      await fetchCookiesFromWebView();
    }
  }

  /// Signs in using cookies from a cookie list.
  static Future<void> signInFromCookieManager(List<Cookie> cookies) async {
    final cookieStr = cookies.map((c) => '${c.name}=${c.value}').join('; ');
    if (cookieStr.isNotEmpty) await signIn(cookieStr);
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

  static bool isPlaylistUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final host = uri.host.toLowerCase();
      if (!host.contains('youtube.com') && !host.contains('youtu.be')) {
        return false;
      }
      return extractPlaylistId(url) != null;
    } catch (_) {
      return false;
    }
  }

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
      if (uri.queryParameters.containsKey('v')) {
        return uri.queryParameters['v'];
      }
      if (uri.pathSegments.contains('watch')) {
        return uri.queryParameters['v'];
      }
    } catch (_) {}
    return null;
  }

  static String? extractPlaylistId(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.queryParameters.containsKey('list')) {
        final listId = uri.queryParameters['list'];
        if (listId != null && listId.isNotEmpty) {
          return listId;
        }
      }
    } catch (_) {}
    return null;
  }

  static String videoUrl(String videoId) =>
      'https://www.youtube.com/watch?v=$videoId';

  static void close() {
    resetClient();
  }

  static final Map<String, (DateTime, List<Map<String, dynamic>>)> _streamsCache = {};
  static const _cacheDuration = Duration(minutes: 5);

  /// Formats all available streams for a given YouTube URL or Video ID into structured maps.
  static Future<List<Map<String, dynamic>>> getStreams(String url) async {
    final videoId = extractVideoId(url) ?? (url.length == 11 ? url : null);
    if (videoId == null) {
      throw Exception('Invalid YouTube URL or Video ID.');
    }

    final cached = _streamsCache[videoId];
    if (cached != null && DateTime.now().difference(cached.$1) < _cacheDuration) {
      return cached.$2;
    }

    try {
      final video = await _yt.videos.get(videoId);
      final manifest = await _yt.videos.streamsClient.getManifest(videoId);
      final title = video.title;

      final results = <Map<String, dynamic>>[];

      // 1. Group video-only streams by height and pair with best audio stream (combined)
      final videoOnlyStreams = manifest.videoOnly.toList();
      final audioOnlyStreams = manifest.audioOnly.toList();

      if (videoOnlyStreams.isNotEmpty && audioOnlyStreams.isNotEmpty) {
        // Find best audio stream (prefer M4A / AAC)
        final bestAudio = audioOnlyStreams.where((a) => a.container.name == 'mp4').isNotEmpty
            ? audioOnlyStreams.where((a) => a.container.name == 'mp4').withHighestBitrate()
            : audioOnlyStreams.withHighestBitrate();

        // Group video streams by quality height (descending)
        final heightMap = <int, VideoOnlyStreamInfo>{};
        for (final v in videoOnlyStreams) {
          final h = v.videoResolution.height;
          if (!heightMap.containsKey(h)) {
            heightMap[h] = v;
          } else {
            // Prefer MP4 container if available for same height
            if (v.container.name == 'mp4' && heightMap[h]!.container.name != 'mp4') {
              heightMap[h] = v;
            } else if (v.size.totalBytes > heightMap[h]!.size.totalBytes) {
              heightMap[h] = v;
            }
          }
        }

        final sortedHeights = heightMap.keys.toList()..sort((a, b) => b.compareTo(a));

        for (final h in sortedHeights) {
          final vStream = heightMap[h]!;
          final ext = 'mp4';
          final qLabel = '${h}p';
          final vSize = vStream.size.totalBytes;
          final aSize = bestAudio.size.totalBytes;

          results.add({
            'type': 'combined',
            'quality': qLabel,
            'label': '$qLabel MP4 + M4A',
            'src': vStream.url.toString(),
            'audioSrc': bestAudio.url.toString(),
            'videoSize': vSize,
            'audioSize': aSize,
            'size': vSize + aSize,
            'ext': ext,
            'title': title,
          });
        }
      }

      // 2. Muxed streams (video + audio together)
      for (final m in manifest.muxed) {
        final h = m.videoResolution.height;
        final qLabel = '${h}p';
        final ext = m.container.name;
        results.add({
          'type': 'muxed',
          'quality': qLabel,
          'label': '$qLabel ${ext.toUpperCase()}',
          'src': m.url.toString(),
          'size': m.size.totalBytes,
          'ext': ext,
          'title': title,
        });
      }

      // 3. Audio-only streams
      for (final a in audioOnlyStreams) {
        final bitrateKbps = a.bitrate.kiloBitsPerSecond.round();
        final ext = a.container.name == 'mp4' ? 'm4a' : a.container.name;
        results.add({
          'type': 'audio',
          'quality': '${bitrateKbps}kbps',
          'label': 'Audio Only ${ext.toUpperCase()}',
          'src': a.url.toString(),
          'size': a.size.totalBytes,
          'ext': ext,
          'title': title,
        });
      }

      // 4. Video-only streams
      for (final v in videoOnlyStreams) {
        final h = v.videoResolution.height;
        final qLabel = '${h}p';
        final ext = v.container.name;
        results.add({
          'type': 'video_only',
          'quality': qLabel,
          'label': '$qLabel Video Only',
          'src': v.url.toString(),
          'size': v.size.totalBytes,
          'ext': ext,
          'title': title,
        });
      }

      if (results.isEmpty) {
        throw Exception(
            'YouTube requires an updated resolver — some videos may be temporarily unavailable');
      }

      _streamsCache[videoId] = (DateTime.now(), results);
      return results;
    } catch (e) {
      debugPrint('YoutubeService.getStreams error for $url: $e');
      throw Exception(_parseErrorMessage(e));
    }
  }

  /// Selects a stream map for a specific video ID and quality preset/resolution.
  static Future<Map<String, dynamic>?> getStreamForVideo(
    String videoId, [
    String? qualityPreset,
  ]) async {
    try {
      final streams = await getStreams(videoId);
      if (streams.isEmpty) return null;

      final preset = (qualityPreset ?? 'best_combined').toLowerCase().trim();

      if (preset == 'audio_only') {
        final audioStreams = streams.where((s) => s['type'] == 'audio').toList();
        if (audioStreams.isNotEmpty) return audioStreams.first;
        return streams.first;
      }

      if (preset == 'best_muxed') {
        final muxedStreams = streams.where((s) => s['type'] == 'muxed').toList();
        if (muxedStreams.isNotEmpty) return muxedStreams.first;
        final combinedStreams = streams.where((s) => s['type'] == 'combined').toList();
        if (combinedStreams.isNotEmpty) return combinedStreams.first;
        return streams.first;
      }

      if (preset == 'best_combined' || preset == 'best') {
        final combinedStreams = streams.where((s) => s['type'] == 'combined').toList();
        if (combinedStreams.isNotEmpty) return combinedStreams.first;
        final muxedStreams = streams.where((s) => s['type'] == 'muxed').toList();
        if (muxedStreams.isNotEmpty) return muxedStreams.first;
        return streams.first;
      }

      // Exact quality matching (e.g. 2160p, 1080p, 720p, etc.)
      final reqHeight = parseQualityHeight(preset);
      if (reqHeight > 0) {
        final combinedStreams = streams.where((s) => s['type'] == 'combined').toList();
        final exactCombined = combinedStreams.where((s) => parseQualityHeight(s['quality'] as String? ?? '') == reqHeight);
        if (exactCombined.isNotEmpty) return exactCombined.first;

        final muxedStreams = streams.where((s) => s['type'] == 'muxed').toList();
        final exactMuxed = muxedStreams.where((s) => parseQualityHeight(s['quality'] as String? ?? '') == reqHeight);
        if (exactMuxed.isNotEmpty) return exactMuxed.first;

        // Closest lower quality match among combined
        final lowerCombined = combinedStreams.where((s) => parseQualityHeight(s['quality'] as String? ?? '') <= reqHeight).toList();
        if (lowerCombined.isNotEmpty) return lowerCombined.first;

        // Closest lower quality match among muxed
        final lowerMuxed = muxedStreams.where((s) => parseQualityHeight(s['quality'] as String? ?? '') <= reqHeight).toList();
        if (lowerMuxed.isNotEmpty) return lowerMuxed.first;
      }

      return streams.first;
    } catch (e) {
      debugPrint('YoutubeService.getStreamForVideo error for $videoId: $e');
      throw Exception(_parseErrorMessage(e));
    }
  }

  /// Fetches playlist info and video list for `YoutubePlaylistSheet`.
  static Future<Map<String, dynamic>?> getPlaylistDetails(String url) async {
    final playlistId = extractPlaylistId(url);
    if (playlistId == null) {
      throw Exception('Invalid YouTube playlist URL.');
    }

    try {
      final playlist = await _yt.playlists.get(playlistId);
      final videoList = <Map<String, dynamic>>[];

      await for (final video in _yt.playlists.getVideos(playlistId)) {
        final durationSec = video.duration?.inSeconds ?? 0;
        String? thumbUrl;
        if (video.thumbnails.mediumResUrl.isNotEmpty) {
          thumbUrl = video.thumbnails.mediumResUrl;
        } else if (video.thumbnails.highResUrl.isNotEmpty) {
          thumbUrl = video.thumbnails.highResUrl;
        } else if (video.thumbnails.standardResUrl.isNotEmpty) {
          thumbUrl = video.thumbnails.standardResUrl;
        } else if (video.thumbnails.lowResUrl.isNotEmpty) {
          thumbUrl = video.thumbnails.lowResUrl;
        }

        videoList.add({
          'id': video.id.value,
          'title': video.title,
          'duration': durationSec,
          'author': video.author,
          'thumbnailUrl': thumbUrl,
          'selected': true,
        });
      }

      return {
        'info': {
          'title': playlist.title,
          'author': playlist.author,
          'videoCount': playlist.videoCount ?? videoList.length,
        },
        'videos': videoList,
      };
    } catch (e) {
      debugPrint('YoutubeService.getPlaylistDetails error for $url: $e');
      throw Exception(_parseErrorMessage(e));
    }
  }

  /// Fetches summary info for a playlist URL.
  static Future<Map<String, dynamic>?> getPlaylistInfo(String url) async {
    final details = await getPlaylistDetails(url);
    return details?['info'] as Map<String, dynamic>?;
  }

  /// Fetches video items for a playlist ID.
  static Future<List<Map<String, dynamic>>?> getPlaylistVideos(
    String playlistId,
  ) async {
    final details = await getPlaylistDetails('https://www.youtube.com/playlist?list=$playlistId');
    return (details?['videos'] as List?)?.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Refreshes expired stream URLs for a given YouTube download page URL.
  static Future<Map<String, dynamic>?> refreshStreamUrl(
    String downloadPageUrl,
    String oldStreamUrl,
  ) async {
    final fresh = await getFreshStreams(downloadPageUrl);
    if (fresh == null || fresh['url'] == null) return null;
    return {
      'url': fresh['url'],
      'audioUrl': fresh['audioUrl'],
    };
  }

  /// Fetches fresh stream URLs (video and optional audio) for a YouTube page URL.
  static Future<Map<String, String?>?> getFreshStreams(
    String downloadPageUrl,
  ) async {
    final videoId = extractVideoId(downloadPageUrl);
    if (videoId == null) return null;

    try {
      final manifest = await _yt.videos.streamsClient.getManifest(videoId);
      String? freshVideoUrl;
      String? freshAudioUrl;

      final videoOnlyStreams = manifest.videoOnly.toList();
      final audioOnlyStreams = manifest.audioOnly.toList();

      if (videoOnlyStreams.isNotEmpty && audioOnlyStreams.isNotEmpty) {
        final bestVideo = videoOnlyStreams.where((v) => v.container.name == 'mp4').isNotEmpty
            ? videoOnlyStreams.where((v) => v.container.name == 'mp4').first
            : videoOnlyStreams.first;
        final bestAudio = audioOnlyStreams.where((a) => a.container.name == 'mp4').isNotEmpty
            ? audioOnlyStreams.where((a) => a.container.name == 'mp4').withHighestBitrate()
            : audioOnlyStreams.withHighestBitrate();

        freshVideoUrl = bestVideo.url.toString();
        freshAudioUrl = bestAudio.url.toString();
      } else if (manifest.muxed.isNotEmpty) {
        freshVideoUrl = manifest.muxed.first.url.toString();
      } else if (audioOnlyStreams.isNotEmpty) {
        freshAudioUrl = audioOnlyStreams.withHighestBitrate().url.toString();
        freshVideoUrl = freshAudioUrl;
      }

      if (freshVideoUrl == null) return null;

      return {
        'url': freshVideoUrl,
        'audioUrl': freshAudioUrl,
      };
    } catch (e) {
      debugPrint('YoutubeService.getFreshStreams error for $downloadPageUrl: $e');
      return null;
    }
  }

  static String _parseErrorMessage(Object error) {
    final msg = error.toString();
    if (msg.contains('VideoUnplayableException') ||
        msg.contains('VideoRequiresPurchaseException') ||
        msg.contains('VideoUnavailableException') ||
        msg.contains('age-restricted') ||
        msg.contains('private') ||
        msg.contains('members-only')) {
      return 'This video is unavailable, private, or age-restricted. Sign-in may be required.';
    }
    if (msg.contains('PlaylistException')) {
      return 'Playlist is private or unavailable.';
    }
    return 'Failed to load YouTube content: $msg';
  }

  static int parseQualityHeight(String quality) {
    final match = RegExp(r'(\d+)').firstMatch(quality);
    if (match != null) {
      return int.tryParse(match.group(1)!) ?? 0;
    }
    return 0;
  }

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

