import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:webview_cookie_manager/webview_cookie_manager.dart';
import 'xdm_backend_client.dart';
import 'xdm_backend_exceptions.dart';


class YoutubeService {

  static String? _cookies;
  static String? _oauthToken;

  /// The OAuth access token if set via [signInWithOAuth], or null.
  static String? get oauthToken => _oauthToken;
  static final _authStateController = StreamController<bool>.broadcast();

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

  /// Returns true if [url] is a known extractable media site (YouTube, Facebook, X/Twitter,
  /// Instagram, TikTok, Reddit, Vimeo, etc.) or a web URL without a direct static file extension.
  static bool isExtractableMediaUrl(String url) {
    if (!url.startsWith('http://') && !url.startsWith('https://')) return false;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();

    // Direct social media video hosts
    if (host.contains('youtube.com') ||
        host.contains('youtu.be') ||
        host.contains('facebook.com') ||
        host.contains('fb.watch') ||
        host.contains('twitter.com') ||
        host.contains('x.com') ||
        host.contains('instagram.com') ||
        host.contains('tiktok.com') ||
        host.contains('reddit.com') ||
        host.contains('vimeo.com') ||
        host.contains('twitch.tv') ||
        host.contains('dailymotion.com')) {
      return true;
    }

    // Direct file extensions skip backend probing
    final staticExtensions = [
      '.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm',
      '.mp3', '.m4a', '.flac', '.wav', '.ogg',
      '.zip', '.rar', '.7z', '.tar', '.gz', '.bz2',
      '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
      '.apk', '.dmg', '.iso', '.exe', '.msi',
      '.png', '.jpg', '.jpeg', '.gif', '.webp'
    ];
    for (final ext in staticExtensions) {
      if (path.endsWith(ext)) return false;
    }

    return true;
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

  /// Formats all available streams for a given URL or Video ID into structured maps.
  static Future<List<Map<String, dynamic>>> getStreams(String url) async {
    final videoId = extractVideoId(url) ?? (url.length == 11 ? url : null);
    final targetUrl = videoId != null ? 'https://www.youtube.com/watch?v=$videoId' : url;
    final cacheKey = videoId ?? url;

    final cached = _streamsCache[cacheKey];
    if (cached != null) {
      if (DateTime.now().difference(cached.$1) < _cacheDuration) {
        return cached.$2;
      } else {
        _streamsCache.remove(cacheKey);
      }
    }

    try {
      final backendRes = await XdmBackendClient().getStreams(
        targetUrl,
        oauthToken: oauthToken,
        cookies: currentCookies,
      );

      final title = (backendRes['title'] as String?) ?? 'Untitled';
      final rawStreams = (backendRes['streams'] as List?) ?? (backendRes['formats'] as List?);

      if (rawStreams != null && rawStreams.isNotEmpty) {
        final results = <Map<String, dynamic>>[];

        for (final s in rawStreams) {
          final map = Map<String, dynamic>.from(s as Map);

          // Handle new POST /extract format output
          if (map.containsKey('direct_url')) {
            final rawType = map['type'] as String? ?? '';
            final ext = map['ext'] as String? ?? 'mp4';
            final quality = map['quality'] as String? ?? 'Unknown';
            final filesize = (map['filesize'] as num?)?.toInt() ?? 0;
            final directUrl = map['direct_url'] as String?;

            String appType;
            if (rawType == 'video_audio') {
              appType = 'muxed';
            } else if (rawType == 'video_only') {
              appType = 'video_only';
            } else if (rawType == 'audio_only') {
              appType = 'audio';
            } else {
              appType = rawType;
            }

            results.add({
              'type': appType,
              'quality': quality,
              'label': appType == 'audio'
                  ? 'Audio Only ${ext.toUpperCase()}'
                  : '$quality ${ext.toUpperCase()}',
              'src': directUrl,
              'audioSrc': null,
              'size': filesize,
              'ext': ext,
              'title': title,
            });
          } else {
            // Handle original GET /api/streams format output
            if (map.containsKey('audioSrc') && map['audioSrc'] != null) {
              map['audioSrc'] = map['audioSrc'].toString();
            } else {
              map['audioSrc'] = null;
            }
            results.add(map);
          }
        }

        if (kDebugMode) {
          final combinedCount = results.where((s) => s['type'] == 'combined').length;
          final muxedCount = results.where((s) => s['type'] == 'muxed').length;
          final audioCount = results.where((s) => s['type'] == 'audio').length;
          final videoOnlyCount = results.where((s) => s['type'] == 'video_only').length;
          debugPrint(
            '[YoutubeService] Parsed ${results.length} streams (combined: $combinedCount, muxed: $muxedCount, audio: $audioCount, video_only: $videoOnlyCount)',
          );
        }

        // Evict expired entries first to prevent memory leak
        final now = DateTime.now();
        _streamsCache.removeWhere((key, val) => now.difference(val.$1) >= _cacheDuration);
        // If still too large, remove the oldest entry
        if (_streamsCache.length >= 50) {
          final oldestKey = _streamsCache.entries
              .reduce((a, b) => a.value.$1.isBefore(b.value.$1) ? a : b)
              .key;
          _streamsCache.remove(oldestKey);
        }
        _streamsCache[cacheKey] = (now, results);
        return results;
      }
    } on BackendException catch (e) {
      throw Exception(e.toUserMessage());
    } catch (e) {
      throw Exception(_parseErrorMessage(e));
    }

    throw Exception('No available streams found for this video.');
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

      // Exact quality matching (e.g. 2160p, 1440p, 1080p, 720p, 480p, 360p, 240p, 144p)
      final reqHeight = parseQualityHeight(preset);
      if (reqHeight > 0) {
        final combinedStreams = streams.where((s) => s['type'] == 'combined').toList();
        final exactCombined = combinedStreams.where((s) => parseQualityHeight(s['quality'] as String? ?? '') == reqHeight);
        if (exactCombined.isNotEmpty) return exactCombined.first;

        final muxedStreams = streams.where((s) => s['type'] == 'muxed').toList();
        final exactMuxed = muxedStreams.where((s) => parseQualityHeight(s['quality'] as String? ?? '') == reqHeight);
        if (exactMuxed.isNotEmpty) return exactMuxed.first;

        // Nearest lower quality match among combined (sorted descending by height)
        final lowerCombined = combinedStreams.where((s) => parseQualityHeight(s['quality'] as String? ?? '') <= reqHeight).toList()
          ..sort((a, b) => parseQualityHeight(b['quality'] as String? ?? '').compareTo(parseQualityHeight(a['quality'] as String? ?? '')));
        if (lowerCombined.isNotEmpty) return lowerCombined.first;

        // Nearest lower quality match among muxed (sorted descending by height)
        final lowerMuxed = muxedStreams.where((s) => parseQualityHeight(s['quality'] as String? ?? '') <= reqHeight).toList()
          ..sort((a, b) => parseQualityHeight(b['quality'] as String? ?? '').compareTo(parseQualityHeight(a['quality'] as String? ?? '')));
        if (lowerMuxed.isNotEmpty) return lowerMuxed.first;

        // If no lower quality exists, fallback to lowest available above requested
        if (combinedStreams.isNotEmpty) return combinedStreams.last;
        if (muxedStreams.isNotEmpty) return muxedStreams.last;
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
      final backendRes = await XdmBackendClient().getPlaylist(
        url,
        oauthToken: oauthToken,
        cookies: currentCookies,
      );

      final info = backendRes['info'] as Map<String, dynamic>?;
      final rawVideos = backendRes['videos'] as List?;
      if (info != null && rawVideos != null) {
        final videoList = rawVideos
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        return {
          'info': info,
          'videos': videoList,
        };
      }
    } on BackendRateLimitException catch (e) {
      throw Exception(e.toUserMessage());
    } on BackendBadRequestException catch (e) {
      throw Exception(e.toUserMessage());
    } on BackendNotFoundException catch (e) {
      throw Exception(e.toUserMessage());
    } on BackendUnauthorizedException catch (e) {
      throw Exception(e.toUserMessage());
    } catch (e) {
      debugPrint('[YoutubeService] Backend error during getPlaylistDetails ($e).');
      throw Exception(_parseErrorMessage(e));
    }

    return null;
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
    final videoId = extractVideoId(downloadPageUrl);
    if (videoId == null) return null;

    try {
      final streams = await getStreams(downloadPageUrl);
      if (streams.isNotEmpty) {
        // Try to match by itag parameter in old stream url vs new streams
        Uri? oldUri;
        try {
          oldUri = Uri.parse(oldStreamUrl);
        } catch (_) {}

        final oldItag = oldUri?.queryParameters['itag'];
        
        if (oldItag != null) {
          final matched = streams.firstWhere(
            (s) => s['itag']?.toString() == oldItag || 
                   (s['src'] != null && Uri.tryParse(s['src'].toString())?.queryParameters['itag'] == oldItag),
            orElse: () => <String, dynamic>{},
          );
          if (matched.isNotEmpty) {
            return {
              'url': matched['src'] as String?,
              'audioUrl': matched['audioSrc'] as String?,
            };
          }
        }

        // If itag match failed, match by quality/type/ext/height
        final oldQuality = oldUri?.queryParameters['quality'] ?? oldUri?.queryParameters['height'];
        
        // Find best fallback match
        Map<String, dynamic>? bestMatch;
        for (final s in streams) {
          final sUrl = s['src']?.toString() ?? '';
          final sUri = Uri.tryParse(sUrl);
          final sQuality = s['quality']?.toString() ?? sUri?.queryParameters['quality'] ?? sUri?.queryParameters['height'];
          
          if (oldQuality != null && sQuality == oldQuality) {
            bestMatch = s;
            break;
          }
        }
        
        if (bestMatch != null) {
          return {
            'url': bestMatch['src'] as String?,
            'audioUrl': bestMatch['audioSrc'] as String?,
          };
        }

        // Default fallback to first stream
        final first = streams.first;
        return {
          'url': first['src'] as String?,
          'audioUrl': first['audioSrc'] as String?,
        };
      }
    } catch (e) {
      debugPrint('[YoutubeService] refreshStreamUrl error ($e).');
    }
    return null;
  }

  /// Fetches fresh stream URLs (video and optional audio) for a YouTube page URL.
  static Future<Map<String, String?>?> getFreshStreams(
    String downloadPageUrl,
  ) async {
    final videoId = extractVideoId(downloadPageUrl);
    if (videoId == null) return null;

    try {
      final streams = await getStreams(downloadPageUrl);
      if (streams.isNotEmpty) {
        final combined = streams.where((s) => s['type'] == 'combined').toList();
        if (combined.isNotEmpty) {
          final best = combined.first;
          return {
            'url': best['src'] as String?,
            'audioUrl': best['audioSrc'] as String?,
          };
        }
        final muxed = streams.where((s) => s['type'] == 'muxed').toList();
        if (muxed.isNotEmpty) {
          final best = muxed.first;
          return {
            'url': best['src'] as String?,
            'audioUrl': null,
          };
        }
        final first = streams.first;
        return {
          'url': first['src'] as String?,
          'audioUrl': first['audioSrc'] as String?,
        };
      }
    } catch (e) {
      debugPrint('[YoutubeService] Backend getFreshStreams error ($e).');
    }

    return null;
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

