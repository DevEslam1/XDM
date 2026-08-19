import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:synchronized/synchronized.dart';

import '../../features/settings/provider/settings_provider.dart';
import 'xdm_backend_client.dart';
import 'xdm_backend_exceptions.dart';

class StreamRefreshResult {
  final Map<String, dynamic> stream;
  final bool qualityChanged;
  final String? originalQuality;
  final String? newQuality;
  const StreamRefreshResult({
    required this.stream,
    this.qualityChanged = false,
    this.originalQuality,
    this.newQuality,
  });
}

class YoutubeService {
  static final Lock _refreshLock = Lock();
  static String? _cookies;
  static String? _oauthToken;
  static const _secureStorage = FlutterSecureStorage();
  static const _cookiesStorageKey = 'youtube_cookies_persisted';

  // FIX-H4: Circuit breaker state
  static int _consecutiveTimeouts = 0;
  static DateTime? _circuitBreakerUntil;

  // FIX Y-01: Client rotation & cooldown state
  static final Map<String, DateTime> _clientCooldowns = {};
  static const Duration defaultClientCooldown = Duration(minutes: 5);

  static void markClientCoolingDown(String clientName, [Duration? duration]) {
    _clientCooldowns[clientName] =
        DateTime.now().add(duration ?? defaultClientCooldown);
    debugPrint(
        '[YouTubeService] Client $clientName cooled down until ${_clientCooldowns[clientName]}');
  }

  static bool isClientCoolingDown(String clientName) {
    final expiry = _clientCooldowns[clientName];
    if (expiry == null) return false;
    if (DateTime.now().isAfter(expiry)) {
      _clientCooldowns.remove(clientName);
      return false;
    }
    return true;
  }

  static List<String> getAvailableClients(
      [List<String> preferenceOrder = const ['android', 'ios', 'web', 'tv']]) {
    return preferenceOrder
        .where((client) => !isClientCoolingDown(client))
        .toList();
  }

  static void resetClientCooldowns() {
    _clientCooldowns.clear();
  }

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
  static StreamController<bool> _authStateController =
      StreamController<bool>.broadcast();

  static Stream<bool> get onAuthStateChanged {
    if (_authStateController.isClosed) {
      _authStateController = StreamController<bool>.broadcast();
    }
    return _authStateController.stream;
  }

  static void _notifyAuthState() {
    if (_authStateController.isClosed) {
      _authStateController = StreamController<bool>.broadcast();
    }
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
      await CookieManager.instance().deleteAllCookies();
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
      final cookieManager = CookieManager.instance();
      final urls = [
        'https://www.youtube.com',
        'https://youtube.com',
        'https://accounts.google.com',
        'https://google.com',
      ];
      final Map<String, String> allCookies = {};

      for (final u in urls) {
        try {
          final cookies = await cookieManager.getCookies(url: WebUri(u));
          for (final c in cookies) {
            if (c.name.isNotEmpty &&
                c.value != null &&
                c.value.toString().isNotEmpty) {
              allCookies[c.name] = c.value.toString();
            }
          }
        } catch (e) {
          debugPrint('[YouTubeService] Failed to get cookies for URL $u: $e');
        }
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

    final host = uri.host.toLowerCase();
    final isKnownMediaHost = _isYouTubeHost(host) ||
        _isYouTubeShortHost(host) ||
        host.contains('vimeo.com') ||
        host.contains('dailymotion.com') ||
        host.contains('tiktok.com') ||
        host.contains('facebook.com') ||
        host.contains('instagram.com') ||
        host.contains('twitter.com') ||
        host.contains('x.com');

    if (!isKnownMediaHost && extractVideoId(url) == null) {
      return false;
    }

    return true;
  }

  /// FIX(20): strict, suffix-bounded host check for the hosts the extractor
  /// backend actually supports. Used to pre-validate shared URLs before
  /// routing them to [MediaQualitySheet]. Unlike the loose `contains()` checks
  /// above, this rejects typo-squatted hosts like `evil-instagram.com`.
  static bool isSupportedMediaHost(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return false;

    bool matches(String domain) => host == domain || host.endsWith('.$domain');

    return matches('youtube.com') ||
        matches('youtu.be') ||
        matches('vimeo.com') ||
        matches('dailymotion.com') ||
        matches('tiktok.com') ||
        matches('facebook.com') ||
        matches('instagram.com') ||
        matches('twitter.com') ||
        matches('x.com');
  }

  static bool isPlaylistUrl(String url) {
    final clean = url.trim();
    if (clean.isEmpty) return false;

    // If it's a raw playlist ID, it's considered a valid target for playlist sheets
    final idRegex = RegExp(r'^(PL|UU|FL|LL|RD|OLAK5uy_)[a-zA-Z0-9_-]{9,80}$');
    if (idRegex.hasMatch(clean)) return true;

    final normalized =
        clean.startsWith('http://') || clean.startsWith('https://')
            ? clean
            : 'https://$clean';

    try {
      final uri = Uri.parse(normalized);
      final host = uri.host.toLowerCase();
      if (!_isYouTubeHost(host) && !_isYouTubeShortHost(host)) {
        return false;
      }
      return extractPlaylistId(normalized) != null;
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
      final clean = url.trim();
      final normalized =
          clean.startsWith('http://') || clean.startsWith('https://')
              ? clean
              : 'https://$clean';
      final uri = Uri.parse(normalized);
      final host = uri.host.toLowerCase();
      final isYoutubeHost = _isYouTubeHost(host) || _isYouTubeShortHost(host);
      // Without this check, ANY url with a `v=` query parameter or a
      // `/watch` path segment (e.g. https://example.com/watch?v=xyz) was
      // treated as a YouTube video id, since the checks below never looked
      // at the host. That falsely routed unrelated links through the
      // YouTube-specific download path (special headers/OAuth/etc).
      if (!isYoutubeHost) return null;
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
    final clean = url.trim();
    if (clean.isEmpty) return null;

    final listMatch = RegExp(r'[&?]list=([a-zA-Z0-9_-]+)', caseSensitive: false)
        .firstMatch(clean);
    if (listMatch != null) {
      return listMatch.group(1);
    }

    final idRegex = RegExp(r'^(PL|UU|FL|LL|RD|OLAK5uy_)[a-zA-Z0-9_-]{9,80}$');
    if (idRegex.hasMatch(clean)) {
      return clean;
    }

    try {
      final normalized =
          clean.startsWith('http://') || clean.startsWith('https://')
              ? clean
              : 'https://$clean';
      final uri = Uri.parse(normalized);
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

  /// Exact host matching for youtube.com and its subdomains.
  static bool _isYouTubeHost(String host) =>
      host == 'youtube.com' ||
      host == 'm.youtube.com' ||
      host == 'www.youtube.com' ||
      host.endsWith('.youtube.com');

  /// Exact host matching for youtu.be and its subdomains.
  static bool _isYouTubeShortHost(String host) =>
      host == 'youtu.be' || host.endsWith('.youtu.be');

  static String videoUrl(String videoId) =>
      'https://www.youtube.com/watch?v=$videoId';

  static bool _isPlaceholderYouTubeUrl(String? value) {
    if (value == null || value.trim().isEmpty) return true;

    final uri = Uri.tryParse(value.trim());
    if (uri == null) return false;

    final host = uri.host.toLowerCase();
    final isYouTubeHost = host == 'youtube.com' ||
        host == 'www.youtube.com' ||
        host == 'm.youtube.com' ||
        host.endsWith('.youtube.com') ||
        host == 'youtu.be' ||
        host.endsWith('.youtu.be');
    if (!isYouTubeHost) return false;

    final path = uri.path.toLowerCase();
    return path == '/watch' ||
        path == '/shorts' ||
        path == '/playlist' ||
        path == '/embed' ||
        path.isEmpty ||
        uri.queryParameters.containsKey('v') ||
        uri.queryParameters.containsKey('list');
  }

  static String? _sanitizeStreamUrl(String? value) {
    final trimmed = value?.toString().trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return _isPlaceholderYouTubeUrl(trimmed) ? null : trimmed;
  }

  static void close() {
    if (!_authStateController.isClosed) {
      _authStateController.close();
    }
    resetClient();
  }

  static Map<String, dynamic> normalizeStreamEntry(
    Map<String, dynamic> map, {
    String? title,
    String? thumbnailUrl,
  }) {
    final rawType = (map['type'] as String?)?.toLowerCase().trim() ?? '';
    final directUrl = _sanitizeStreamUrl(
      map['direct_url']?.toString() ??
          map['url']?.toString() ??
          map['src']?.toString(),
    );
    final audioUrl = _sanitizeStreamUrl(
      map['audioSrc']?.toString() ??
          map['audio_url']?.toString() ??
          map['audioUrl']?.toString() ??
          map['audio_source']?.toString(),
    );

    String appType;
    if (rawType == 'video_audio' || rawType == 'videoaudio') {
      appType = 'muxed';
    } else if (rawType == 'video_only' || rawType == 'video') {
      appType = 'video_only';
    } else if (rawType == 'audio_only' || rawType == 'audio') {
      appType = 'audio';
    } else if (rawType == 'combined') {
      appType = 'combined';
    } else {
      appType = rawType;
    }

    final ext = (map['ext'] as String?) ?? 'mp4';
    final quality = (map['quality'] as String?) ?? 'Unknown';
    final qualityLabel = quality.isEmpty ? 'Unknown' : quality;
    final filesizeValue =
        map['filesize'] ?? map['size'] ?? map['filesize_approx'] ?? 0;
    final filesize = filesizeValue is num
        ? filesizeValue.toInt()
        : int.tryParse(filesizeValue.toString()) ?? 0;

    final videoSizeValue =
        map['videoSize'] ?? map['video_size'] ?? map['video_size_bytes'] ?? 0;
    final audioSizeValue =
        map['audioSize'] ?? map['audio_size'] ?? map['audio_size_bytes'] ?? 0;

    final normalized = <String, dynamic>{
      'type': appType,
      'quality': qualityLabel,
      'label': appType == 'audio'
          ? 'Audio Only ${ext.toUpperCase()}'
          : '$qualityLabel ${ext.toUpperCase()}',
      'src': directUrl,
      'audioSrc': audioUrl,
      'videoSize': videoSizeValue is num
          ? videoSizeValue.toInt()
          : int.tryParse(videoSizeValue.toString()) ?? 0,
      'audioSize': audioSizeValue is num
          ? audioSizeValue.toInt()
          : int.tryParse(audioSizeValue.toString()) ?? 0,
      'size': filesize,
      'ext': ext,
      'title': title ?? 'Untitled',
      'thumbnailUrl': thumbnailUrl,
      if (map.containsKey('itag')) 'itag': map['itag'],
      if (map.containsKey('format_id')) 'format_id': map['format_id'],
      if (map.containsKey('format')) 'format': map['format'],
    };

    if (map.containsKey('audioSrc') && map['audioSrc'] != null) {
      normalized['audioSrc'] = map['audioSrc'].toString();
    }

    return normalized;
  }

  static List<Map<String, dynamic>> _parseStreams(
    Map<String, dynamic> backendRes,
  ) {
    final title = (backendRes['title'] as String?) ?? 'Untitled';
    final thumbnailUrl = (backendRes['thumbnail'] as String?) ??
        (backendRes['thumbnailUrl'] as String?);
    final rawStreams =
        (backendRes['streams'] as List?) ?? (backendRes['formats'] as List?);

    if (rawStreams == null || rawStreams.isEmpty) return [];

    final results = <Map<String, dynamic>>[];
    final seenUrls = <String>{};

    for (final s in rawStreams) {
      final map = Map<String, dynamic>.from(s as Map);
      final normalized = normalizeStreamEntry(
        map,
        title: title,
        thumbnailUrl: thumbnailUrl,
      );

      final url = normalized['src']?.toString();
      if (url == null || url.isEmpty) continue;
      if (!seenUrls.add(url)) continue;

      final resultEntry = Map<String, dynamic>.from(normalized);
      if (map.containsKey('audioSrc') && map['audioSrc'] != null) {
        resultEntry['audioSrc'] = map['audioSrc'].toString();
      }
      results.add(resultEntry);
    }

    results.sort((a, b) {
      final aExt = (a['ext'] as String? ?? '').toLowerCase();
      final bExt = (b['ext'] as String? ?? '').toLowerCase();
      if (aExt == 'mp4' && bExt != 'mp4') return -1;
      if (bExt == 'mp4' && aExt != 'mp4') return 1;
      return 0;
    });

    return results;
  }

  static Future<List<Map<String, dynamic>>> getStreams(String url) async {
    final videoId = extractVideoId(url) ?? (url.length == 11 ? url : null);
    final targetUrl =
        videoId != null ? 'https://www.youtube.com/watch?v=$videoId' : url;

    final settings = SettingsProvider.instance;
    if (!settings.useRemoteBackend) {
      throw Exception('Remote backend is disabled in settings.');
    }

    try {
      // FIX-H4 / Y-03: Wrap backend call with 45s total budget timeout
      final results = await _resolveWithRetry(
        targetUrl,
        cookies: settings.sendBrowserCookiesToBackend ? currentCookies : null,
      ).timeout(const Duration(seconds: 45), onTimeout: () {
        throw const BackendTimeoutException('Total retry budget exceeded');
      });

      if (results != null && results.isNotEmpty) {
        if (kDebugMode) {
          final combinedCount =
              results.where((s) => s['type'] == 'combined').length;
          final muxedCount = results.where((s) => s['type'] == 'muxed').length;
          final audioCount = results.where((s) => s['type'] == 'audio').length;
          final videoOnlyCount =
              results.where((s) => s['type'] == 'video_only').length;
          debugPrint(
            '[YoutubeService] Parsed ${results.length} streams (combined: $combinedCount, muxed: $muxedCount, audio: $audioCount, video_only: $videoOnlyCount)',
          );
        }
        return results;
      }
    } on TimeoutException catch (e) {
      throw Exception(
          e.message ?? 'Stream resolution timed out after 35 seconds');
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
    final isYouTubeHost = _isYouTubeHost(host) || _isYouTubeShortHost(host);

    final videoId = extractVideoId(url);
    final targetUrl =
        videoId != null ? 'https://www.youtube.com/watch?v=$videoId' : url;

    try {
      final settings = SettingsProvider.instance;
      if (!settings.useRemoteBackend) {
        throw Exception(
            'Remote backend is disabled in settings. Please enable it in Settings.');
      }
      final results = await _resolveWithRetry(
        targetUrl,
        cookies: isYouTubeHost && settings.sendBrowserCookiesToBackend
            ? currentCookies
            : null,
      );

      if (results != null && results.isNotEmpty) return results;
    } on BackendException catch (e) {
      final msg = e.message.toLowerCase();
      final isYouTube = isYouTubeHost || isSupportedMediaHost(url);
      final hasSpecificKeywords = msg.contains('sign in') ||
          msg.contains('bot') ||
          msg.contains('confirm') ||
          msg.contains('age') ||
          msg.contains('geo') ||
          msg.contains('rate limit');

      if (e is BackendBadRequestException || e is BackendNotFoundException) {
        if (isYouTube || hasSpecificKeywords) {
          throw Exception(e.toUserMessage());
        }
        return null;
      }
      throw Exception(e.toUserMessage());
    } catch (e) {
      throw Exception(_parseErrorMessage(e));
    }

    return null;
  }

  /// Resolves streams for [url] using the remote backend only.
  static Future<List<Map<String, dynamic>>?> _resolveStreamsWithFallback(
    String url, {
    String? cookies,
  }) async {
    // Circuit breaker check: if 3 consecutive timeouts occurred, skip backend for 30s
    if (_circuitBreakerUntil != null &&
        DateTime.now().isBefore(_circuitBreakerUntil!)) {
      throw Exception(
          'YouTube backend circuit breaker active (30s cooldown due to consecutive timeouts).');
    }

    try {
      final backendRes = await XdmBackendClient()
          .getStreams(
            url,
            cookies: cookies,
            oauthToken: YoutubeService.oauthToken,
          )
          .timeout(const Duration(seconds: 35));
      _consecutiveTimeouts = 0;
      _circuitBreakerUntil = null;
      final results = _parseStreams(backendRes);
      return results.isNotEmpty ? results : null;
    } catch (e) {
      final isTimeout = e is TimeoutException ||
          e is XdmBackendTimeoutException ||
          e.toString().contains('timed out');
      if (isTimeout) {
        _consecutiveTimeouts++;
        if (_consecutiveTimeouts >= 3) {
          _circuitBreakerUntil =
              DateTime.now().add(const Duration(seconds: 30));
          debugPrint(
              '[YoutubeService] Circuit breaker tripped (3 timeouts): skipping backend for 30s');
        }
      }
      if (e is TimeoutException) {
        throw Exception('Stream resolution timed out after 35 seconds');
      }
      rethrow;
    }
  }

  // Retry stream resolution for transient errors and cold starts
  static Future<List<Map<String, dynamic>>?> _resolveWithRetry(
    String url, {
    String? cookies,
    int maxRetries = 3,
  }) async {
    final stopwatch = Stopwatch()..start();
    int effectiveRetries = maxRetries;
    for (int attempt = 0; attempt <= effectiveRetries; attempt++) {
      if (stopwatch.elapsed > const Duration(seconds: 45)) {
        throw const BackendTimeoutException('Total retry budget exceeded');
      }
      try {
        final result = await _resolveStreamsWithFallback(url, cookies: cookies);
        if (result != null && result.isNotEmpty) return result;

        // result is null or empty — apply backoff before next attempt
        if (attempt < effectiveRetries) {
          final delay = Duration(seconds: 2 * (attempt + 1));
          await Future.delayed(delay);
        }
        continue;
      } catch (e) {
        if (stopwatch.elapsed > const Duration(seconds: 45)) {
          throw const BackendTimeoutException('Total retry budget exceeded');
        }
        final isTimeout = e is TimeoutException ||
            e is XdmBackendTimeoutException ||
            e.toString().contains('timed out');
        // FIX-H4: In _resolveWithRetry, reduce max retries from 3 to 2 when timeout occurs
        if (isTimeout && effectiveRetries > 2) {
          effectiveRetries = 2;
        }
        final isPermanent = e is BackendUnauthorizedException;
        if (attempt >= effectiveRetries || isPermanent) rethrow;
        // Backoff: 2s, 4s (Cloud Run cold start needs time to spin up)
        final delay = Duration(seconds: 2 * (attempt + 1));
        debugPrint(
          '[YoutubeService] Backend attempt ${attempt + 1} failed, '
          'retrying in ${delay.inSeconds}s: $e',
        );
        await Future.delayed(delay);
      }
    }
    return null;
  }

  static Future<Map<String, dynamic>?> getStreamForVideo(
    String videoId, [
    String? qualityPreset,
  ]) async {
    try {
      List<Map<String, dynamic>> streams;
      try {
        streams = await getStreams(videoId);
      } on TimeoutException {
        debugPrint(
            '[YoutubeService] getStreamForVideo timed out (35s), retrying once...');
        streams = await getStreams(videoId);
      }
      if (streams.isEmpty) return null;

      final preset = (qualityPreset ?? 'best_combined').toLowerCase().trim();

      if (preset == 'audio_only') {
        final audioStreams =
            streams.where((s) => s['type'] == 'audio').toList();
        if (audioStreams.isNotEmpty) return audioStreams.first;
        return streams.isNotEmpty ? streams.first : null;
      }

      if (preset == 'best_muxed') {
        final muxedStreams =
            streams.where((s) => s['type'] == 'muxed').toList();
        if (muxedStreams.isNotEmpty) return muxedStreams.first;
        final combinedStreams =
            streams.where((s) => s['type'] == 'combined').toList();
        if (combinedStreams.isNotEmpty) return combinedStreams.first;
        return streams.isNotEmpty ? streams.first : null;
      }

      bool isMp4(Map<String, dynamic> s) {
        final ext = (s['ext'] as String? ?? '').toLowerCase();
        final format = (s['format'] as String? ?? '').toLowerCase();
        return ext == 'mp4' || format.contains('mp4') || format.contains('avc');
      }

      Map<String, dynamic>? pickBest(Iterable<Map<String, dynamic>> list) {
        if (list.isEmpty) return null;
        final mp4s = list.where(isMp4);
        return mp4s.isNotEmpty ? mp4s.first : list.first;
      }

      if (preset == 'best_combined' || preset == 'best') {
        final combinedStreams =
            streams.where((s) => s['type'] == 'combined').toList();
        final bestCombined = pickBest(combinedStreams);
        if (bestCombined != null) return bestCombined;

        final muxedStreams =
            streams.where((s) => s['type'] == 'muxed').toList();
        final bestMuxed = pickBest(muxedStreams);
        if (bestMuxed != null) return bestMuxed;

        return pickBest(streams);
      }

      final reqHeight = parseQualityHeight(preset);
      if (reqHeight > 0) {
        final combinedStreams =
            streams.where((s) => s['type'] == 'combined').toList();
        final exactCombined = combinedStreams.where(
          (s) => parseQualityHeight(s['quality'] as String? ?? '') == reqHeight,
        );
        final bestExactCombined = pickBest(exactCombined);
        if (bestExactCombined != null) return bestExactCombined;

        final muxedStreams =
            streams.where((s) => s['type'] == 'muxed').toList();
        final exactMuxed = muxedStreams.where(
          (s) => parseQualityHeight(s['quality'] as String? ?? '') == reqHeight,
        );
        final bestExactMuxed = pickBest(exactMuxed);
        if (bestExactMuxed != null) return bestExactMuxed;

        final lowerCombined = combinedStreams
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
        final bestLowerCombined = pickBest(lowerCombined);
        if (bestLowerCombined != null) return bestLowerCombined;

        final lowerMuxed = muxedStreams
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
        final bestLowerMuxed = pickBest(lowerMuxed);
        if (bestLowerMuxed != null) return bestLowerMuxed;

        if (combinedStreams.isNotEmpty) {
          return pickBest(combinedStreams) ?? combinedStreams.last;
        }
        if (muxedStreams.isNotEmpty) {
          return pickBest(muxedStreams) ?? muxedStreams.last;
        }
      }

      return pickBest(streams) ?? (streams.isNotEmpty ? streams.first : null);
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

    final targetUrl = url.startsWith('http://') || url.startsWith('https://')
        ? url
        : 'https://www.youtube.com/playlist?list=$playlistId';

    try {
      final settings = SettingsProvider.instance;
      final backendRes = await XdmBackendClient().getPlaylist(
        targetUrl,
        cookies: settings.sendBrowserCookiesToBackend ? currentCookies : null,
        pageToken: pageToken,
        pageSize: pageSize,
      );

      final info = backendRes['info'] as Map<String, dynamic>?;
      final rawVideos = backendRes['videos'] as List?;
      if (info != null && rawVideos != null) {
        final videoList = rawVideos.map((e) {
          final map = Map<String, dynamic>.from(e as Map);
          final videoId = map['id'] as String?;
          final thumb =
              map['thumbnailUrl'] ?? map['thumbnail'] ?? map['thumbnail_url'];
          if ((thumb == null || thumb.toString().isEmpty) &&
              videoId != null &&
              videoId.isNotEmpty) {
            map['thumbnailUrl'] =
                'https://img.youtube.com/vi/$videoId/hqdefault.jpg';
          } else if (thumb != null) {
            map['thumbnailUrl'] = thumb.toString();
          }
          if ((map['url'] == null || map['url'].toString().isEmpty) &&
              videoId != null &&
              videoId.isNotEmpty) {
            map['url'] = 'https://www.youtube.com/watch?v=$videoId';
          }
          return map;
        }).toList();
        return {
          'info': info,
          'videos': videoList,
          if (backendRes['note'] != null) 'note': backendRes['note'],
          if (backendRes['nextPageToken'] != null)
            'nextPageToken': backendRes['nextPageToken'],
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
      debugPrint('[YouTubeService] Search error: $e');
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

  static int qualityLadderDistance(String? q1, String? q2) {
    const ladder = [2160, 1440, 1080, 720, 480, 360, 240, 144];
    final h1 = parseQualityHeight(q1 ?? '');
    final h2 = parseQualityHeight(q2 ?? '');
    if (h1 <= 0 || h2 <= 0) return 0;
    final idx1 = ladder.indexWhere((h) => h <= h1);
    final idx2 = ladder.indexWhere((h) => h <= h2);
    if (idx1 == -1 || idx2 == -1) return 0;
    return (idx1 - idx2).abs();
  }

  static StreamRefreshResult evaluateQualityDowngrade({
    required Map<String, dynamic> stream,
    String? originalQuality,
    String? newQuality,
  }) {
    final steps = qualityLadderDistance(originalQuality, newQuality);
    return StreamRefreshResult(
      stream: stream,
      qualityChanged: steps > 1,
      originalQuality: originalQuality,
      newQuality: newQuality,
    );
  }

  static Future<Map<String, dynamic>?> refreshStreamUrl(
    String downloadPageUrl,
    String oldStreamUrl,
  ) async {
    return _refreshLock.synchronized(() async {
      // Mirror getStreams' own fallback: a bare 11-character YouTube video id
      // is a valid input here too (getStreamForVideo passes ids around, not
      // just full URLs), so don't bail out just because extractVideoId — which
      // only understands full URLs — returns null for it.
      final videoId = extractVideoId(downloadPageUrl) ??
          (downloadPageUrl.length == 11 ? downloadPageUrl : null);
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
            debugPrint(
              '[YouTubeService] FIX(10): refreshStreamUrl: itag "$oldItag" not found in refreshed streams. Attempting quality/type fallback.',
            );
          }

          final oldQuality = oldUri?.queryParameters['quality'] ??
              oldUri?.queryParameters['height'];

          Map<String, dynamic>? bestMatch;
          for (final s in streams) {
            final sUrl = s['src']?.toString() ?? '';
            final sUri = Uri.tryParse(sUrl);
            final sQuality = s['quality']?.toString() ??
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

          if (streams.isNotEmpty) {
            String oldType = 'combined';
            if (oldStreamUrl.contains('mime=audio') ||
                oldStreamUrl.contains('audio')) {
              oldType = 'audio';
            } else if (oldStreamUrl.contains('video')) {
              oldType = 'video_only';
            }

            // FIX-17: Prefer same-type fallback, then closest quality.
            // Avoids grabbing a completely different quality/type stream.
            final sameType = streams
                .where((s) => s['type'] == oldType && s['src'] != null)
                .toList();
            if (sameType.isNotEmpty) {
              sameType.sort((a, b) =>
                  (parseQualityHeight(b['quality']?.toString() ?? '') -
                          parseQualityHeight(oldQuality ?? ''))
                      .abs() -
                  (parseQualityHeight(a['quality']?.toString() ?? '') -
                          parseQualityHeight(oldQuality ?? ''))
                      .abs());
              return {
                'url': sameType.first['src'] as String?,
                'audioUrl': sameType.first['audioSrc'] as String?,
              };
            }

            debugPrint(
              '[YouTube] refreshStreamUrl: No itag/quality/same-type match found. '
              'Falling back to any stream (quality may differ).',
            );
            final first = streams.firstWhere(
              (s) => s['src'] != null,
              orElse: () => <String, dynamic>{},
            );
            if (first.isNotEmpty) {
              debugPrint(
                '[YouTubeService] refreshStreamUrl warning: Stream type changed from "$oldType" to "${first['type']}".',
              );
              return {
                'url': first['src'] as String?,
                'audioUrl': first['audioSrc'] as String?,
              };
            }
          }
        }
      } catch (e) {
        debugPrint('[YouTubeService] refreshStreamUrl error ($e).');
      }
      return null;
    });
  }

  static Future<Map<String, String?>?> Function(String,
      {String? preferredType})? mockGetFreshStreams;

  static Future<Map<String, String?>?> getFreshStreams(
    String downloadPageUrl, {
    String? preferredType,
  }) async {
    return _refreshLock.synchronized(() async {
      if (kDebugMode && mockGetFreshStreams != null) {
        return mockGetFreshStreams!(downloadPageUrl,
            preferredType: preferredType);
      }

      final videoId = extractVideoId(downloadPageUrl) ??
          (downloadPageUrl.length == 11 ? downloadPageUrl : null);
      if (videoId == null) return null;

      try {
        final streams = await getStreams(downloadPageUrl);
        if (streams.isNotEmpty) {
          if (preferredType != null) {
            final matched =
                streams.where((s) => s['type'] == preferredType).toList();
            if (matched.isNotEmpty) {
              final best = matched.firstWhere(
                (s) => s['src'] != null,
                orElse: () => <String, dynamic>{},
              );
              if (best.isNotEmpty) {
                return {
                  'url': best['src'] as String?,
                  'audioUrl': best['audioSrc'] as String?,
                };
              }
            }
          }

          final combined = streams.where((s) => s['type'] == 'combined').toList();
          if (combined.isNotEmpty) {
            final best = combined.firstWhere(
              (s) => s['src'] != null,
              orElse: () => <String, dynamic>{},
            );
            if (best.isNotEmpty) {
              return {
                'url': best['src'] as String?,
                'audioUrl': best['audioSrc'] as String?,
              };
            }
          }
          final muxed = streams.where((s) => s['type'] == 'muxed').toList();
          if (muxed.isNotEmpty) {
            final best = muxed.firstWhere(
              (s) => s['src'] != null,
              orElse: () => <String, dynamic>{},
            );
            if (best.isNotEmpty) {
              return {'url': best['src'] as String?, 'audioUrl': null};
            }
          }
          final first = streams.firstWhere(
            (s) => s['src'] != null,
            orElse: () => <String, dynamic>{},
          );
          if (first.isNotEmpty) {
            return {
              'url': first['src'] as String?,
              'audioUrl': first['audioSrc'] as String?,
            };
          }
        }
      } catch (e) {
        debugPrint('[YouTubeService] Backend getFreshStreams error ($e).');
      }

      return null;
    });
  }

  static String _parseErrorMessage(Object error) {
    final msg = error.toString();
    if (msg.contains('Sign in to confirm') ||
        msg.contains('not a bot') ||
        msg.contains('Sign in') ||
        msg.contains('bot') ||
        msg.contains('Connection closed before full header') ||
        msg.contains('full header')) {
      return 'YouTube requires sign-in or bot verification. Please sign in to YouTube via the browser and try again.';
    }
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

  static void dispose() => close();
}
