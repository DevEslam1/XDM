/// Pure-HTTP InnerTube API client for fetching YouTube stream URLs.
///
/// This is the PRIMARY stream engine (Layer 1), replacing youtube_explode_dart
/// as the first attempt. Uses YouTube's own mobile API endpoints with
/// ANDROID→IOS→TV→WEB client fallback chain.
///
/// Zero binary dependencies. Works on Android, iOS, and Desktop.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'innertube_constants.dart';
import 'innertube_models.dart';
import 'stream_url_cache.dart';
import 'youtube_exceptions.dart';

class InnerTubeStreamClient {
  final StreamUrlCache _cache = StreamUrlCache();
  HttpClient? _client;
  String? _cookies;
  String? _oauthToken;

  /// Optional API key override (hot-patch without app release).
  static String? apiKeyOverride;

  HttpClient get _httpClient {
    _client ??= HttpClient()..connectionTimeout = innerTubeTimeout;
    return _client!;
  }

  /// Sets cookies for authenticated requests (age-restricted content).
  void setCookies(String? cookies) => _cookies = cookies;

  /// Sets an OAuth access token for authenticated InnerTube requests.
  /// This is obtained from Google Sign-In and sent as
  /// `Authorization: Bearer <token>` header.
  void setOAuthToken(String? token) => _oauthToken = token;

  // ──────────────────── Stream Fetching ────────────────────

  /// Main entry: fetch all available streams for a video.
  ///
  /// Tries ALL client contexts and merges unique formats by itag.
  /// This ensures high-quality formats (4K/2160p) are included even when
  /// the ANDROID client caps at 1080p — later clients (TV, WEB) fill in
  /// the higher resolutions.
  ///
  /// Returns null if all clients fail. Throws [YouTubeException] subtypes
  /// for definitive errors (age-restricted, private, geo-blocked).
  Future<List<InnerTubeStream>?> getStreams(
    String videoId, {
    String? cookies,
  }) async {
    // Check cache first
    final cached = _cache.get(videoId);
    if (cached != null) return cached;

    final effectiveCookies = cookies ?? _cookies;

    // Collect unique streams from ALL clients, keyed by itag.
    // First client wins for duplicate itags (ANDROID URLs are preferred
    // since they don't have n-param throttling).
    final mergedByItag = <int, InnerTubeStream>{};
    String title = 'YouTube Video';
    var anySuccess = false;
    YouTubeException? lastError;

    for (final client in innerTubeFallbackOrder) {
      try {
        final response = await _getPlayerResponse(
          videoId,
          client,
          cookies: effectiveCookies,
        );
        if (response == null) continue;

        _checkPlayability(response, videoId);

        final streams = _parseStreams(response);
        if (streams.isNotEmpty) {
          anySuccess = true;
          if (title == 'YouTube Video' && streams.first.title.isNotEmpty) {
            title = streams.first.title;
          }
          for (final s in streams) {
            // Use itag as dedup key; combined streams share the video itag
            final key = s.itag ?? -(mergedByItag.length + 1);
            if (!mergedByItag.containsKey(key)) {
              mergedByItag[key] = s;
            }
          }
        }
      } on YouTubeException catch (e) {
        // Don't rethrow immediately — another client might succeed.
        // Only throw after ALL clients have been tried.
        lastError = e;
        debugPrint(
          '[InnerTube] Client $client error for $videoId: ${e.message}',
        );
        continue;
      } catch (e) {
        debugPrint('[InnerTube] Client $client failed for $videoId: $e');
        continue;
      }
    }

    // If any client succeeded with streams, use them regardless of other errors
    if (anySuccess && mergedByItag.isNotEmpty) {
      // Rebuild combined streams from merged video_only + audio lists
      final allStreams = mergedByItag.values.toList();
      final videoOnly = allStreams
          .where((s) => s.type == 'video_only')
          .toList();
      final audioOnly = allStreams.where((s) => s.type == 'audio').toList();

      // Remove old combined entries (they were per-client, now rebuild)
      allStreams.removeWhere((s) => s.type == 'combined');

      if (videoOnly.isNotEmpty && audioOnly.isNotEmpty) {
        audioOnly.sort((a, b) => b.size.compareTo(a.size));
        final bestAudio = audioOnly.first;

        for (final video in videoOnly) {
          allStreams.add(
            InnerTubeStream(
              url: video.url,
              audioUrl: bestAudio.url,
              label: '${video.quality} + Best Audio',
              size: video.size + bestAudio.size,
              audioSize: bestAudio.size,
              ext: 'mp4',
              title: title,
              quality: video.quality,
              type: 'combined',
              itag: video.itag,
              height: video.height,
              mimeType: video.mimeType,
              expireTimestamp: video.expireTimestamp,
            ),
          );
        }
      }

      _cache.put(videoId, allStreams);
      return allStreams;
    }

    // ALL clients failed — throw the last definitive error if we have one
    if (lastError != null) throw lastError;

    // If we got here with no streams and no error, it means every client
    // returned a soft-fail (bot check / sign-in prompt). Surface this.
    if (!anySuccess) {
      throw const LoginRequiredException(
        'YouTube requires sign-in to access this video. '
        'Please sign in to YouTube in the Browser tab first.',
      );
    }

    return null;
  }

  /// Fetches a fresh URL for a specific stream by matching itag.
  /// Used for transparent URL refresh on 403/410 mid-download.
  Future<InnerTubeStream?> refreshStream(
    String videoId, {
    required String oldUrl,
    String? cookies,
  }) async {
    _cache.invalidate(videoId); // Force fresh fetch
    final streams = await getStreams(videoId, cookies: cookies);
    if (streams == null) return null;

    final oldUri = Uri.tryParse(oldUrl);
    final oldItag = oldUri?.queryParameters['itag'];

    // Match by itag first (most precise)
    if (oldItag != null) {
      for (final s in streams) {
        if (s.itag?.toString() == oldItag) return s;
      }
      // Also try matching itag in URL query params
      for (final s in streams) {
        final sUri = Uri.tryParse(s.url);
        if (sUri?.queryParameters['itag'] == oldItag) return s;
      }
    }

    // Fallback: match by stream type
    final oldIsAudio =
        oldUrl.contains('mime%3Daudio') || oldUrl.contains('mime=audio');
    if (oldIsAudio) {
      return streams.where((s) => s.type == 'audio').firstOrNull;
    }
    return streams
        .where((s) => s.type == 'video_only' || s.type == 'muxed')
        .firstOrNull;
  }

  // ──────────────────── Playlist Fetching ────────────────────

  /// Fetches playlist details using the InnerTube browse endpoint.
  ///
  /// Uses WEB client context (browse returns web-format responses).
  /// Returns null on failure. Handles pagination for large playlists.
  Future<InnerTubePlaylist?> getPlaylist(
    String playlistId, {
    String? cookies,
  }) async {
    final effectiveCookies = cookies ?? _cookies;

    // First request
    Map<String, dynamic> data;
    try {
      data = await _browse('VL$playlistId', cookies: effectiveCookies);
    } catch (e) {
      debugPrint('[InnerTube] Playlist browse failed: $e');
      return null;
    }

    // Check for error alerts
    final alerts = data['alerts'] as List?;
    if (alerts != null && alerts.isNotEmpty) {
      final alertType =
          (alerts[0] as Map?)?['alertRenderer']?['type'] as String?;
      if (alertType == 'ERROR') return null;
    }

    // Extract metadata
    final title =
        _extractString(data, 'metadata/playlistMetadataRenderer/title') ?? '';
    String author = '';
    final header = data['header'] as Map?;
    if (header != null && header.containsKey('playlistHeaderRenderer')) {
      final ownerRuns = _extractList(
        header['playlistHeaderRenderer'] as Map,
        'ownerText/runs',
      );
      if (ownerRuns != null && ownerRuns.isNotEmpty) {
        author = (ownerRuns[0] as Map?)?['text'] as String? ?? '';
      }
    }
    if (author.isEmpty) {
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

    // Video count
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

    // Thumbnail from first video
    final videoItems = _extractVideoItems(data);
    String thumbnailUrl = '';
    if (videoItems.isNotEmpty) {
      thumbnailUrl = _extractThumbnailUrl(videoItems.first);
    }

    // Paginate through all videos
    final allVideos = <InnerTubePlaylistVideo>[];
    final seenVideoIds = <String>{};
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
        if (video == null) continue;
        if (video.id.isNotEmpty && !seenVideoIds.add(video.id)) continue;
        allVideos.add(video);
      }

      if (continuationToken == null || continuationToken.isEmpty) break;

      pageNum++;
      try {
        await Future.delayed(const Duration(milliseconds: 250));
        data = await _browse(
          'VL$playlistId',
          continuationToken: continuationToken,
          cookies: effectiveCookies,
        );
      } catch (e) {
        debugPrint(
          '[InnerTube] Playlist continuation failed at page $pageNum: $e',
        );
        break;
      }
    }

    return InnerTubePlaylist(
      id: playlistId,
      title: title,
      author: author,
      videoCount: videoCount > 0 ? videoCount : allVideos.length,
      thumbnailUrl: thumbnailUrl,
      videos: allVideos,
    );
  }

  // ──────────────────── HTTP Layer ────────────────────

  /// Returns the effective API key for a given client.
  String _getApiKey(InnerTubeClient client) {
    if (apiKeyOverride != null && apiKeyOverride!.isNotEmpty) {
      return apiKeyOverride!;
    }
    return innerTubeApiKeys[client]!;
  }

  /// Builds the client context JSON for the request body.
  Map<String, dynamic> _buildClientContext(InnerTubeClient client) {
    final ctx = innerTubeClientContexts[client]!;
    return {
      'clientName': ctx['clientName'],
      'clientVersion': ctx['clientVersion'],
      'hl': 'en',
      'gl': ctx['gl'] ?? 'US',
      if (ctx['androidSdkVersion'] != null)
        'androidSdkVersion': ctx['androidSdkVersion'],
      if (ctx['deviceMake'] != null) 'deviceMake': ctx['deviceMake'],
      if (ctx['deviceModel'] != null) 'deviceModel': ctx['deviceModel'],
      if (ctx['osName'] != null) 'osName': ctx['osName'],
      if (ctx['osVersion'] != null) 'osVersion': ctx['osVersion'],
    };
  }

  /// Sets headers on the HTTP request, matching what yt-dlp sends.
  void _setHeaders(
    HttpClientRequest request,
    InnerTubeClient client, {
    String? cookies,
  }) {
    final ctx = innerTubeClientContexts[client]!;
    request.headers.set('Content-Type', 'application/json');
    request.headers.set(
      'User-Agent',
      ctx['userAgent'] as String? ??
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/131.0.0.0',
    );
    request.headers.set(
      'X-YouTube-Client-Name',
      '${ctx['clientNameNumeric'] ?? 1}',
    );
    request.headers.set(
      'X-YouTube-Client-Version',
      ctx['clientVersion'] as String,
    );

    // Origin must match the client type
    if (client == InnerTubeClient.android || client == InnerTubeClient.ios) {
      request.headers.set('Origin', 'https://www.youtube.com');
    } else {
      request.headers.set('Origin', 'https://www.youtube.com');
      request.headers.set('Referer', 'https://www.youtube.com/');
    }

    // Accept header prevents some bot-detection heuristics
    request.headers.set('Accept', '*/*');
    request.headers.set('Accept-Language', 'en-US,en;q=0.9');

    // ── OAuth token authentication (from Google Sign-In) ──
    // This takes priority over cookie-based auth.
    if (_oauthToken != null && _oauthToken!.isNotEmpty) {
      request.headers.set('Authorization', 'Bearer $_oauthToken');
      // When using OAuth, also set the auth-user header
      request.headers.set('X-Goog-AuthUser', '0');
    }

    // Cookie-based auth (from WebView browser sign-in)
    if (cookies != null && cookies.isNotEmpty) {
      request.headers.set('Cookie', cookies);
      // When authenticated, add the auth-user header
      request.headers.set('X-Goog-AuthUser', '0');
    }
  }

  /// Makes the HTTP POST to YouTube's player endpoint.
  Future<Map<String, dynamic>?> _getPlayerResponse(
    String videoId,
    InnerTubeClient client, {
    String? cookies,
  }) async {
    try {
      return await Future(() async {
        final key = _getApiKey(client);
        final url = Uri.parse('${InnerTubeEndpoints.player}?key=$key');

        final request = await _httpClient.postUrl(url);
        _setHeaders(request, client, cookies: cookies);

        // Build the context map; TV client needs thirdParty embed context
        // to return 4K adaptive streams without authentication (mirrors yt-dlp).
        final ctx = innerTubeClientContexts[client]!;
        final contextMap = <String, dynamic>{
          'client': _buildClientContext(client),
        };
        final thirdParty = ctx['thirdParty'] as Map<String, dynamic>?;
        if (thirdParty != null) {
          contextMap['thirdParty'] = thirdParty;
        }

        final body = <String, dynamic>{
          'context': contextMap,
          'videoId': videoId,
          'playbackContext': {
            'contentPlaybackContext': {'html5Preference': 'HTML5_PREF_WANTS'},
          },
          'contentCheckOk': true,
          'racyCheckOk': true,
        };

        request.write(jsonEncode(body));

        final response = await request.close();

        if (response.statusCode != 200) {
          debugPrint(
            '[InnerTube] HTTP ${response.statusCode} for $videoId ($client)',
          );
          await response.drain<void>();
          return null;
        }

        final raw = await response.transform(utf8.decoder).join();
        if (raw.isEmpty) return null;
        return jsonDecode(raw) as Map<String, dynamic>;
      }).timeout(innerTubeTimeout);
    } catch (e) {
      debugPrint(
        '[InnerTube] Request failed or timed out for $videoId ($client): $e',
      );
      return null;
    }
  }

  /// Sends a POST to the InnerTube browse endpoint (for playlists).
  /// Uses WEB client context since browse returns web-format responses.
  Future<Map<String, dynamic>> _browse(
    String browseId, {
    String? continuationToken,
    String? cookies,
  }) async {
    return await Future(() async {
      const client = InnerTubeClient.web;
      final key = _getApiKey(client);
      final url = Uri.parse('${InnerTubeEndpoints.browse}?key=$key');

      final request = await _httpClient.postUrl(url);
      _setHeaders(request, client, cookies: cookies);

      final body = <String, dynamic>{
        'context': {'client': _buildClientContext(client)},
      };
      if (continuationToken != null) {
        body['continuation'] = continuationToken;
      } else {
        body['browseId'] = browseId;
      }

      request.write(jsonEncode(body));
      final response = await request.close();

      if (response.statusCode != 200) {
        throw Exception(
          '[InnerTube] Browse returned HTTP ${response.statusCode}',
        );
      }

      final raw = await response.transform(utf8.decoder).join();
      if (raw.isEmpty) throw Exception('[InnerTube] Browse response was empty');
      return jsonDecode(raw) as Map<String, dynamic>;
    }).timeout(const Duration(seconds: 30));
  }

  // ──────────────────── Response Validation ────────────────────

  /// Checks playabilityStatus and throws typed exceptions for definitive errors.
  void _checkPlayability(Map<String, dynamic> response, String videoId) {
    final playability = response['playabilityStatus'] as Map?;
    final status = playability?['status'] as String?;
    if (status == 'OK') return;

    final reason = playability?['reason'] as String? ?? '';
    final lower = reason.toLowerCase();

    // Client version rejected — don't throw, let caller try next client
    if (lower.contains('no longer supported') ||
        lower.contains('not supported on this') ||
        lower.contains('update')) {
      debugPrint('[InnerTube] Client rejected for $videoId: $reason');
      return; // Falls through to try next client in getStreams()
    }

    // Bot detection / generic sign-in prompt — NOT age restriction.
    // YouTube often returns this for datacenter IPs or unauthenticated
    // clients. Try next client instead of throwing.
    if (lower.contains('sign in') ||
        lower.contains('signin') ||
        lower.contains('confirm you') ||
        lower.contains('not a bot') ||
        lower.contains('captcha') ||
        status == 'LOGIN_REQUIRED') {
      debugPrint(
        '[InnerTube] Sign-in/bot-check for $videoId ($status): $reason',
      );
      return; // Let caller try next client
    }

    // Check for live stream
    final isLive = (response['videoDetails'] as Map?)?['isLiveContent'] == true;
    if (isLive && status != 'OK') {
      throw LiveStreamException(
        reason.isNotEmpty
            ? reason
            : 'This is a live stream and cannot be downloaded.',
        videoId: videoId,
      );
    }

    // True age restriction — very specific match only
    if (lower.contains('age-restrict') ||
        lower.contains('confirm your age') ||
        lower.contains('age check') ||
        lower.contains('inappropriate for some users') ||
        lower.contains('age gate')) {
      throw AgeRestrictedException(reason, videoId: videoId);
    } else if (lower.contains('private')) {
      throw PrivateVideoException(reason, videoId: videoId);
    } else if (lower.contains('country') ||
        lower.contains('geo') ||
        lower.contains('region')) {
      throw GeoBlockedException(reason, videoId: videoId);
    } else if (status == 'ERROR' || status == 'UNPLAYABLE') {
      throw NoStreamsException(
        reason.isNotEmpty ? reason : 'Video is unplayable',
        videoId: videoId,
      );
    }
    // For other statuses, don't throw — let the caller try next client
  }

  // ──────────────────── Stream Parsing ────────────────────

  /// Parses streamingData from the player response into typed streams.
  List<InnerTubeStream> _parseStreams(Map<String, dynamic> response) {
    final streams = <InnerTubeStream>[];
    final streamingData = response['streamingData'] as Map?;
    if (streamingData == null) return streams;

    final videoDetails = response['videoDetails'] as Map?;
    final title = videoDetails?['title'] as String? ?? 'YouTube Video';

    // Parse adaptive formats (video-only + audio-only)
    final adaptiveFormats = (streamingData['adaptiveFormats'] as List?) ?? [];
    // Parse muxed formats (video+audio combined, lower quality)
    final formats = (streamingData['formats'] as List?) ?? [];

    final videoOnly = <InnerTubeStream>[];
    final audioOnly = <InnerTubeStream>[];

    for (final f in [...formats, ...adaptiveFormats]) {
      final format = f as Map<String, dynamic>;
      final url = format['url'] as String?;
      if (url == null || url.isEmpty) continue; // Skip cipher-protected

      final mimeType = format['mimeType'] as String? ?? '';
      final qualityLabel = format['qualityLabel'] as String? ?? '';
      final contentLength =
          int.tryParse(format['contentLength']?.toString() ?? '0') ?? 0;
      final itag = format['itag'] as int?;
      final bitrate = format['bitrate'] as int? ?? 0;
      final height = format['height'] as int?;

      final isVideo = mimeType.startsWith('video/');
      final isAudio = mimeType.startsWith('audio/');
      // Muxed: video mime that also contains audio codec
      final hasBoth =
          isVideo && (mimeType.contains('mp4a') || mimeType.contains('opus'));

      // Extract expire timestamp from URL
      int? expireTs;
      final uri = Uri.tryParse(url);
      if (uri != null) {
        expireTs = int.tryParse(uri.queryParameters['expire'] ?? '');
      }

      String type;
      String label;
      String quality;
      if (hasBoth) {
        type = 'muxed';
        label = '$qualityLabel (Muxed)';
        quality = qualityLabel;
      } else if (isVideo) {
        type = 'video_only';
        label = '$qualityLabel (Video Only)';
        quality = qualityLabel;
      } else if (isAudio) {
        type = 'audio';
        label = '${(bitrate / 1000).round()}kbps Audio';
        quality = '${(bitrate / 1000).round()}kbps';
      } else {
        continue; // Unknown type, skip
      }

      final stream = InnerTubeStream(
        url: url,
        label: label,
        size: contentLength,
        ext: mimeType.contains('mp4') ? 'mp4' : 'webm',
        title: title,
        quality: quality,
        type: type,
        itag: itag,
        height: height,
        mimeType: mimeType,
        expireTimestamp: expireTs,
      );

      if (type == 'video_only') videoOnly.add(stream);
      if (type == 'audio') audioOnly.add(stream);
      streams.add(stream);
    }

    // Generate combined streams (video-only + best audio)
    if (videoOnly.isNotEmpty && audioOnly.isNotEmpty) {
      // Sort audio by size descending (best quality first)
      audioOnly.sort((a, b) => b.size.compareTo(a.size));
      final bestAudio = audioOnly.first;

      for (final video in videoOnly) {
        streams.add(
          InnerTubeStream(
            url: video.url,
            audioUrl: bestAudio.url,
            label: '${video.quality} + Best Audio',
            size: video.size + bestAudio.size,
            audioSize: bestAudio.size,
            ext: 'mp4',
            title: title,
            quality: video.quality,
            type: 'combined',
            itag: video.itag,
            height: video.height,
            mimeType: video.mimeType,
            expireTimestamp: video.expireTimestamp,
          ),
        );
      }
    }

    return streams;
  }

  // ──────────────────── Playlist Parsing Helpers ────────────────────

  /// Extracts the flat list of video items from a browse response,
  /// handling both initial and continuation formats.
  List<Map<String, dynamic>> _extractVideoItems(Map<String, dynamic> data) {
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

        // New format: lockupViewModels directly in itemSectionRenderer/contents
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
  InnerTubePlaylistVideo? _parseVideoItem(
    Map<String, dynamic> item,
    String fallbackAuthor,
  ) {
    // Old format: playlistVideoRenderer
    final pvr = item['playlistVideoRenderer'] as Map?;
    if (pvr != null) {
      final id = pvr['videoId'] as String? ?? '';
      if (id.isEmpty) return null;
      final title = _parseRuns(pvr['title']?['runs'] as List?) ?? 'Video';
      final videoAuthor =
          _parseRuns(pvr['ownerText']?['runs'] as List?) ??
          _parseRuns(pvr['shortBylineText']?['runs'] as List?) ??
          fallbackAuthor;
      final durationText = pvr['lengthText']?['simpleText'] as String?;
      final duration = _parseDuration(durationText);
      final thumb = _extractThumbnailUrl(item);
      return InnerTubePlaylistVideo(
        id: id,
        title: title,
        author: videoAuthor,
        duration: duration,
        thumbnailUrl: thumb,
      );
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

      final thumb = _extractThumbnailUrl(item);
      return InnerTubePlaylistVideo(
        id: id,
        title: title,
        author: fallbackAuthor,
        duration: duration,
        thumbnailUrl: thumb,
      );
    }

    return null;
  }

  /// Extracts the continuation token from the video items list.
  String? _extractContinuationToken(
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
      items = _extractVideoItems(data);
    }

    if (items == null) return null;

    for (final item in items) {
      final cont = (item as Map?)?['continuationItemRenderer'] as Map?;
      if (cont != null) {
        final endpoint = cont['continuationEndpoint'] as Map?;
        if (endpoint != null) {
          final token = endpoint['continuationCommand']?['token'] as String?;
          if (token != null) return token;
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

  // ──────────────────── Utility Helpers ────────────────────

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

  /// Closes the HTTP client and clears cache. Call on dispose.
  void close() {
    _client?.close(force: true);
    _client = null;
    _cache.clear();
  }
}
