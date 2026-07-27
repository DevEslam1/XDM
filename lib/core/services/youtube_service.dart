import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:webview_cookie_manager/webview_cookie_manager.dart';
import 'xdm_backend_client.dart';
import 'xdm_backend_exceptions.dart';
import '../../features/settings/provider/settings_provider.dart';

class YoutubeService {
  static String? _cookies;
  static String? _oauthToken;
  static const _secureStorage = FlutterSecureStorage();
  static const _cookiesStorageKey = 'youtube_cookies_persisted';

  static Future<void> init() async {
    try {
      final savedCookies = await _secureStorage.read(key: _cookiesStorageKey);
      if (savedCookies != null && savedCookies.isNotEmpty) {
        _cookies = savedCookies;
        debugPrint('[YouTubeService] Loaded persisted cookies');
      }
    } catch (e) {
      debugPrint('[YouTubeService] Failed to load persisted cookies: $e');
    }
  }

  static String? get oauthToken => _oauthToken;
  static final _authStateController = StreamController<bool>.broadcast();

  static Stream<bool> get onAuthStateChanged => _authStateController.stream;

  static void _notifyAuthState() {
    _authStateController.add(isSignedIn);
  }

  static Future<void> signIn(String cookieString) async {
    _cookies = cookieString;
    _notifyAuthState();
    try {
      await _secureStorage.write(key: _cookiesStorageKey, value: cookieString);
    } catch (e) {
      debugPrint('[YouTubeService] Failed to persist cookies: $e');
    }
  }

  static Future<void> signInWithOAuth(String accessToken) async {
    _oauthToken = accessToken;
    await resetClient();
    _notifyAuthState();
  }

  static Future<void> clearOAuth() async {
    _oauthToken = null;
    _notifyAuthState();
  }

  static bool get hasOAuth => _oauthToken != null && _oauthToken!.isNotEmpty;

  static Future<void> signOut() async {
    _cookies = null;
    _oauthToken = null;
    await resetClient();
    try {
      await WebviewCookieManager().clearCookies();
      await _secureStorage.delete(key: _cookiesStorageKey);
    } catch (e) {
      debugPrint(
        '[YouTubeService] Failed to clear WebView cookies on signout: $e',
      );
    }
    _notifyAuthState();
  }

  static Future<void> refreshOAuthToken(String newToken) async {
    _oauthToken = newToken;
    _notifyAuthState();
  }

  static Future<void> resetClient() async {
    // No local cache to clear anymore, relying on XdmBackendClient cache
  }

  static bool get isSignedIn =>
      (_cookies != null && _cookies!.isNotEmpty) ||
      (_oauthToken != null && _oauthToken!.isNotEmpty);

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
        } catch (e) {
          debugPrint('[YouTubeService] Failed to get cookies for URL $u: $e');
        }
      }

      if (allCookies.isNotEmpty) {
        final cookieStr = allCookies.entries
            .map((e) => '${e.key}=${e.value}')
            .join('; ');
        await signIn(cookieStr);
      }
    } catch (e) {
      debugPrint('Failed to authenticate YouTube from browser cookies: $e');
    }
  }

  static Future<void> authenticateFromBrowser([List<Cookie>? cookies]) async {
    if (cookies != null && cookies.isNotEmpty) {
      await signInFromCookieManager(cookies);
    } else {
      await fetchCookiesFromWebView();
    }
  }

  static Future<void> signInFromCookieManager(List<Cookie> cookies) async {
    final cookieStr = cookies.map((c) => '${c.name}=${c.value}').join('; ');
    if (cookieStr.isNotEmpty) await signIn(cookieStr);
  }

  static String? get currentCookies => _cookies;

  // ───────────────────────── URL Detection ──────────────────────────

  static bool isYoutubeUrl(String url) {
    return isYoutubeVideoUrl(url) || isPlaylistUrl(url);
  }

  static bool isYoutubeVideoUrl(String url) {
    return extractVideoId(url) != null;
  }

  static bool isExtractableMediaUrl(String url) {
    if (!url.startsWith('http://') && !url.startsWith('https://')) return false;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final path = uri.path.toLowerCase();

    final staticExtensions = [
      '.mp4',
      '.mkv',
      '.avi',
      '.mov',
      '.wmv',
      '.flv',
      '.webm',
      '.mp3',
      '.m4a',
      '.flac',
      '.wav',
      '.ogg',
      '.zip',
      '.rar',
      '.7z',
      '.tar',
      '.gz',
      '.bz2',
      '.pdf',
      '.doc',
      '.docx',
      '.xls',
      '.xlsx',
      '.ppt',
      '.pptx',
      '.apk',
      '.dmg',
      '.iso',
      '.exe',
      '.msi',
      '.png',
      '.jpg',
      '.jpeg',
      '.gif',
      '.webp',
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
    } catch (e) {
      debugPrint('[YouTubeService] isPlaylistUrl failed to parse URL: $e');
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
    } catch (e) {
      debugPrint('[YouTubeService] extractVideoId failed to parse URL: $e');
    }
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
    } catch (e) {
      debugPrint('[YouTubeService] extractPlaylistId failed to parse URL: $e');
    }
    return null;
  }

  static String videoUrl(String videoId) =>
      'https://www.youtube.com/watch?v=$videoId';

  static void close() {
    resetClient();
  }

  static List<Map<String, dynamic>> _parseStreams(
    Map<String, dynamic> backendRes,
  ) {
    final title = (backendRes['title'] as String?) ?? 'Untitled';
    final rawStreams =
        (backendRes['streams'] as List?) ?? (backendRes['formats'] as List?);

    if (rawStreams == null || rawStreams.isEmpty) return [];

    final results = <Map<String, dynamic>>[];
    final seenUrls = <String>{};

    for (final s in rawStreams) {
      final map = Map<String, dynamic>.from(s as Map);

      final url = (map['direct_url'] as String?) ?? (map['url'] as String?);
      if (url != null && !seenUrls.add(url)) continue;

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
          'audioSrc': map.containsKey('audioSrc')
              ? map['audioSrc']?.toString()
              : null,
          'videoSize': map['videoSize'] as int? ?? 0,
          'audioSize': map['audioSize'] as int? ?? 0,
          'size': filesize,
          'ext': ext,
          'title': title,
        });
      } else {
        if (map.containsKey('audioSrc') && map['audioSrc'] != null) {
          map['audioSrc'] = map['audioSrc'].toString();
        } else {
          map['audioSrc'] = null;
        }
        map['title'] = title;
        results.add(map);
      }
    }
    return results;
  }

  static Future<List<Map<String, dynamic>>> getStreams(String url) async {
    final videoId = extractVideoId(url) ?? (url.length == 11 ? url : null);
    final targetUrl = videoId != null
        ? 'https://www.youtube.com/watch?v=$videoId'
        : url;

    final settings = SettingsProvider.instance;
    if (!settings.useRemoteBackend) {
      throw Exception('Remote backend is disabled in settings.');
    }

    try {
      final backendRes = await XdmBackendClient().getStreams(
        targetUrl,
        cookies: settings.sendBrowserCookiesToBackend ? currentCookies : null,
      );

      final results = _parseStreams(backendRes);
      if (results.isNotEmpty) {
        if (kDebugMode) {
          final combinedCount = results
              .where((s) => s['type'] == 'combined')
              .length;
          final muxedCount = results.where((s) => s['type'] == 'muxed').length;
          final audioCount = results.where((s) => s['type'] == 'audio').length;
          final videoOnlyCount = results
              .where((s) => s['type'] == 'video_only')
              .length;
          debugPrint(
            '[YoutubeService] Parsed ${results.length} streams (combined: $combinedCount, muxed: $muxedCount, audio: $audioCount, video_only: $videoOnlyCount)',
          );
        }
        return results;
      }
    } on BackendException catch (e) {
      throw Exception(e.toUserMessage());
    } catch (e) {
      throw Exception(_parseErrorMessage(e));
    }

    throw Exception('No available streams found for this video.');
  }

  static Future<List<Map<String, dynamic>>?> getStreamsForAnyUrl(
    String url,
  ) async {
    final uri = Uri.tryParse(url);
    final host = uri?.host.toLowerCase() ?? '';
    final isYouTubeHost =
        host.contains('youtube.com') || host.contains('youtu.be');

    final videoId = extractVideoId(url);
    final targetUrl = videoId != null
        ? 'https://www.youtube.com/watch?v=$videoId'
        : url;

    try {
      final settings = SettingsProvider.instance;
      final backendRes = await XdmBackendClient().getStreams(
        targetUrl,
        cookies: isYouTubeHost && settings.sendBrowserCookiesToBackend
            ? currentCookies
            : null,
      );

      final results = _parseStreams(backendRes);
      if (results.isNotEmpty) return results;
    } on BackendBadRequestException {
      return null;
    } on BackendNotFoundException {
      return null;
    } on BackendException catch (e) {
      throw Exception(e.toUserMessage());
    } catch (e) {
      throw Exception(_parseErrorMessage(e));
    }

    return null;
  }

  static Future<Map<String, dynamic>?> getStreamForVideo(
    String videoId, [
    String? qualityPreset,
  ]) async {
    try {
      final streams = await getStreams(videoId);
      if (streams.isEmpty) return null;

      final preset = (qualityPreset ?? 'best_combined').toLowerCase().trim();

      if (preset == 'audio_only') {
        final audioStreams = streams
            .where((s) => s['type'] == 'audio')
            .toList();
        if (audioStreams.isNotEmpty) return audioStreams.first;
        return streams.first;
      }

      if (preset == 'best_muxed') {
        final muxedStreams = streams
            .where((s) => s['type'] == 'muxed')
            .toList();
        if (muxedStreams.isNotEmpty) return muxedStreams.first;
        final combinedStreams = streams
            .where((s) => s['type'] == 'combined')
            .toList();
        if (combinedStreams.isNotEmpty) return combinedStreams.first;
        return streams.first;
      }

      if (preset == 'best_combined' || preset == 'best') {
        final combinedStreams = streams
            .where((s) => s['type'] == 'combined')
            .toList();
        if (combinedStreams.isNotEmpty) return combinedStreams.first;
        final muxedStreams = streams
            .where((s) => s['type'] == 'muxed')
            .toList();
        if (muxedStreams.isNotEmpty) return muxedStreams.first;
        return streams.first;
      }

      final reqHeight = parseQualityHeight(preset);
      if (reqHeight > 0) {
        final combinedStreams = streams
            .where((s) => s['type'] == 'combined')
            .toList();
        final exactCombined = combinedStreams.where(
          (s) => parseQualityHeight(s['quality'] as String? ?? '') == reqHeight,
        );
        if (exactCombined.isNotEmpty) return exactCombined.first;

        final muxedStreams = streams
            .where((s) => s['type'] == 'muxed')
            .toList();
        final exactMuxed = muxedStreams.where(
          (s) => parseQualityHeight(s['quality'] as String? ?? '') == reqHeight,
        );
        if (exactMuxed.isNotEmpty) return exactMuxed.first;

        final lowerCombined =
            combinedStreams
                .where(
                  (s) =>
                      parseQualityHeight(s['quality'] as String? ?? '') <=
                      reqHeight,
                )
                .toList()
              ..sort(
                (a, b) => parseQualityHeight(
                  b['quality'] as String? ?? '',
                ).compareTo(parseQualityHeight(a['quality'] as String? ?? '')),
              );
        if (lowerCombined.isNotEmpty) return lowerCombined.first;

        final lowerMuxed =
            muxedStreams
                .where(
                  (s) =>
                      parseQualityHeight(s['quality'] as String? ?? '') <=
                      reqHeight,
                )
                .toList()
              ..sort(
                (a, b) => parseQualityHeight(
                  b['quality'] as String? ?? '',
                ).compareTo(parseQualityHeight(a['quality'] as String? ?? '')),
              );
        if (lowerMuxed.isNotEmpty) return lowerMuxed.first;

        if (combinedStreams.isNotEmpty) return combinedStreams.last;
        if (muxedStreams.isNotEmpty) return muxedStreams.last;
      }

      return streams.first;
    } catch (e) {
      debugPrint('YoutubeService.getStreamForVideo error for $videoId: $e');
      throw Exception(_parseErrorMessage(e));
    }
  }

  static Future<Map<String, dynamic>?> getPlaylistDetails(
    String url, {
    dynamic pageToken,
    int pageSize = 50,
  }) async {
    final playlistId = extractPlaylistId(url);
    if (playlistId == null) {
      throw Exception('Invalid YouTube playlist URL.');
    }

    try {
      final settings = SettingsProvider.instance;
      final backendRes = await XdmBackendClient().getPlaylist(
        url,
        cookies: settings.sendBrowserCookiesToBackend ? currentCookies : null,
        pageToken: pageToken,
        pageSize: pageSize,
      );

      final info = backendRes['info'] as Map<String, dynamic>?;
      final rawVideos = backendRes['videos'] as List?;
      if (info != null && rawVideos != null) {
        final videoList = rawVideos
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        return {'info': info, 'videos': videoList};
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
      debugPrint(
        '[YoutubeService] Backend error during getPlaylistDetails ($e).',
      );
      throw Exception(_parseErrorMessage(e));
    }

    return null;
  }

  static Future<List<Map<String, dynamic>>> search(String query) async {
    try {
      final results = await XdmBackendClient().search(query);
      return results;
    } on BackendException catch (e) {
      throw Exception(e.toUserMessage());
    } catch (e) {
      debugPrint('[YoutubeService] Search error: $e');
      throw Exception('Search failed: $e');
    }
  }

  static Future<Map<String, dynamic>?> getPlaylistInfo(String url) async {
    final details = await getPlaylistDetails(url);
    return details?['info'] as Map<String, dynamic>?;
  }

  static Future<List<Map<String, dynamic>>?> getPlaylistVideos(
    String playlistId, {
    dynamic pageToken,
    int pageSize = 50,
  }) async {
    final details = await getPlaylistDetails(
      'https://www.youtube.com/playlist?list=$playlistId',
      pageToken: pageToken,
      pageSize: pageSize,
    );
    return (details?['videos'] as List?)
        ?.map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  static Future<Map<String, dynamic>?> refreshStreamUrl(
    String downloadPageUrl,
    String oldStreamUrl,
  ) async {
    final videoId = extractVideoId(downloadPageUrl);
    if (videoId == null) return null;

    try {
      final streams = await getStreams(downloadPageUrl);
      if (streams.isNotEmpty) {
        Uri? oldUri;
        try {
          oldUri = Uri.parse(oldStreamUrl);
        } catch (e) {
          debugPrint(
            '[YouTubeService] Failed to parse oldStreamUrl in refreshStreamUrl: $e',
          );
        }

        final oldItag = oldUri?.queryParameters['itag'];

        if (oldItag != null) {
          final matched = streams.firstWhere(
            (s) =>
                s['itag']?.toString() == oldItag ||
                (s['src'] != null &&
                    Uri.tryParse(
                          s['src'].toString(),
                        )?.queryParameters['itag'] ==
                        oldItag),
            orElse: () => <String, dynamic>{},
          );
          if (matched.isNotEmpty) {
            return {
              'url': matched['src'] as String?,
              'audioUrl': matched['audioSrc'] as String?,
            };
          }
        }

        final oldQuality =
            oldUri?.queryParameters['quality'] ??
            oldUri?.queryParameters['height'];

        Map<String, dynamic>? bestMatch;
        for (final s in streams) {
          final sUrl = s['src']?.toString() ?? '';
          final sUri = Uri.tryParse(sUrl);
          final sQuality =
              s['quality']?.toString() ??
              sUri?.queryParameters['quality'] ??
              sUri?.queryParameters['height'];

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
          return {'url': best['src'] as String?, 'audioUrl': null};
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
