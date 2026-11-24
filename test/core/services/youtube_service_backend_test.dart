// ignore_for_file: avoid_dynamic_calls
import 'dart:convert';
import 'dart:io';

import 'package:dmx/core/services/backend_health_service.dart';
import 'package:dmx/core/services/xdm_backend_client.dart';
import 'package:dmx/core/services/youtube_service.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/scriptable_http_server.dart';

const _secureStorageChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

String _id(int seed) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final buffer = StringBuffer();
  var value = seed;
  for (var i = 0; i < 11; i++) {
    buffer.write(alphabet[value % alphabet.length]);
    value = value * 7 + 13;
  }
  return buffer.toString();
}

Map<String, dynamic> _stream({
  required String type,
  required String quality,
  required String url,
  String ext = 'mp4',
  int? size,
  String? audioUrl,
  int? videoSize,
  int? audioSize,
  int? itag,
  String? format,
  String? title,
}) =>
    {
      'type': type,
      'quality': quality,
      'url': url,
      if (audioUrl != null) 'audio_url': audioUrl,
      if (size != null) 'size': size,
      if (videoSize != null) 'video_size': videoSize,
      if (audioSize != null) 'audio_size': audioSize,
      'ext': ext,
      if (itag != null) 'itag': itag,
      if (format != null) 'format': format,
      if (title != null) 'title': title,
    };

Map<String, dynamic> _response(List<Map<String, dynamic>> streams) => {
      'title': 'Backend Test Video',
      'thumbnail': 'https://img.example/thumb.jpg',
      'streams': streams,
    };

List<Map<String, dynamic>> _fullCatalog() => [
      _stream(
        type: 'combined',
        quality: '1080p',
        url: 'https://googlevideo.com/c1080',
        size: 1000,
        itag: 137,
        format: 'mp4',
      ),
      _stream(
        type: 'video_audio',
        quality: '720p',
        url: 'https://googlevideo.com/m720',
        audioUrl: 'https://googlevideo.com/a720',
        videoSize: 500,
        audioSize: 100,
        itag: 22,
        format: 'mp4',
      ),
      _stream(
        type: 'audio_only',
        quality: '160kbps',
        url: 'https://googlevideo.com/a160f',
        size: 50,
        ext: 'm4a',
      ),
      _stream(
        type: 'video_only',
        quality: '480p',
        url: 'https://googlevideo.com/v480',
        size: 70,
        ext: 'webm',
        format: 'webm',
      ),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScriptableHttpServer server;
  late SettingsProvider settings;

  void enqueueJson(Object body, {int status = 200}) {
    server.enqueue((request) async {
      final response = request.response;
      response.statusCode = status;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(body));
      await response.close();
    });
  }

  setUpAll(() {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      _secureStorageChannel,
      (call) async => null,
    );
  });

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    settings = SettingsProvider.instance;
    await settings.load();
    await settings.setUseRemoteBackend(true);
    await settings.setSendBrowserCookiesToBackend(false);
    await XdmBackendClient.setApiKey('test-key');
    BackendHealthService.instance.resetCooldowns();
    YoutubeService.resetClientCooldowns();
    server = ScriptableHttpServer();
    await server.start();
    await settings.setBackendUrl(server.baseUrl);
  });

  tearDown(() async {
    await settings.setBackendUrl('');
    await server.stop();
  });

  group('getStreams', () {
    test('parses a successful backend response and caches it', () async {
      final id = _id(1);
      enqueueJson(_response(_fullCatalog()));

      final streams =
          await YoutubeService.getStreams('https://www.youtube.com/watch?v=$id');

      expect(streams, hasLength(4));
      expect(
        streams.map((s) => s['type']),
        containsAll(<String>['combined', 'muxed', 'audio', 'video_only']),
      );
      expect(streams.first['title'], 'Backend Test Video');

      // Second call is served from the XdmBackendClient / YoutubeService cache.
      final cached =
          await YoutubeService.getStreams('https://www.youtube.com/watch?v=$id');
      expect(cached, hasLength(4));
    });

    test('forwards cookies when enabled', () async {
      final id = _id(2);
      await settings.setSendBrowserCookiesToBackend(true);
      await YoutubeService.signIn('SID=abc; HSID=def');
      enqueueJson(_response([
        _stream(
          type: 'combined',
          quality: '720p',
          url: 'https://googlevideo.com/cookie720',
          format: 'mp4',
        ),
      ]));

      final streams =
          await YoutubeService.getStreams('https://www.youtube.com/watch?v=$id');

      expect(streams, hasLength(1));
      await YoutubeService.signOut();
      await settings.setSendBrowserCookiesToBackend(false);
    });

    test('throws when remote backend is disabled and nothing is cached',
        () async {
      await settings.setUseRemoteBackend(false);
      await expectLater(
        YoutubeService.getStreams(
            'https://www.youtube.com/watch?v=${_id(3)}'),
        throwsA(isA<Exception>()),
      );
      await settings.setUseRemoteBackend(true);
    });
  });

  group('getStreamForVideo', () {
    test('resolves every quality preset', () async {
      final id = _id(10);
      enqueueJson(_response(_fullCatalog()));
      await YoutubeService.getStreams('https://www.youtube.com/watch?v=$id');

      expect((await YoutubeService.getStreamForVideo(id))!['type'], 'combined');
      expect(
        (await YoutubeService.getStreamForVideo(id, 'best'))!['type'],
        'combined',
      );
      expect(
        (await YoutubeService.getStreamForVideo(id, 'best_combined'))!['type'],
        'combined',
      );
      expect(
        (await YoutubeService.getStreamForVideo(id, 'best_muxed'))!['type'],
        'muxed',
      );
      expect(
        (await YoutubeService.getStreamForVideo(id, 'audio_only'))!['type'],
        'audio',
      );
      expect(
        (await YoutubeService.getStreamForVideo(id, '1080p'))!['quality'],
        '1080p',
      );
      expect(
        (await YoutubeService.getStreamForVideo(id, '720p'))!['type'],
        'muxed',
      );
      expect(
        (await YoutubeService.getStreamForVideo(id, '2160p'))!['quality'],
        '1080p',
      );
      expect(
        (await YoutubeService.getStreamForVideo(id, '100p'))!['type'],
        'combined',
      );
      expect(
        (await YoutubeService.getStreamForVideo(id, 'weird-preset'))!['type'],
        isNotNull,
      );
    });

    test('handles a muxed-only catalog', () async {
      final id = _id(11);
      enqueueJson(_response([
        _stream(
          type: 'video_audio',
          quality: '360p',
          url: 'https://googlevideo.com/m360',
          audioUrl: 'https://googlevideo.com/a360',
          format: 'mp4',
        ),
      ]));
      await YoutubeService.getStreams('https://www.youtube.com/watch?v=$id');

      // No audio stream -> falls back to the first stream.
      expect(
        (await YoutubeService.getStreamForVideo(id, 'audio_only'))!['type'],
        'muxed',
      );
      // No exact/lower match for a higher request -> lower-muxed fallback.
      expect(
        (await YoutubeService.getStreamForVideo(id, '1080p'))!['type'],
        'muxed',
      );
      // Nothing lower -> generic muxed fallback.
      expect(
        (await YoutubeService.getStreamForVideo(id, '100p'))!['type'],
        'muxed',
      );
    });

    test('best_muxed falls back to combined when no muxed exists', () async {
      final id = _id(12);
      enqueueJson(_response([
        _stream(
          type: 'combined',
          quality: '720p',
          url: 'https://googlevideo.com/onlycombined',
          format: 'mp4',
        ),
      ]));
      await YoutubeService.getStreams('https://www.youtube.com/watch?v=$id');

      expect(
        (await YoutubeService.getStreamForVideo(id, 'best_muxed'))!['type'],
        'combined',
      );
    });

    test('wraps errors coming from getStreams', () async {
      await settings.setUseRemoteBackend(false);
      await expectLater(
        YoutubeService.getStreamForVideo(_id(13)),
        throwsA(isA<Exception>()),
      );
      await settings.setUseRemoteBackend(true);
    });

    test('maps backend sign-in detail to guidance', () async {
      final id = _id(14);
      enqueueJson(
        {'detail': "Sign in to confirm you're not a bot"},
        status: 401,
      );
      enqueueJson(
        {'detail': "Sign in to confirm you're not a bot"},
        status: 401,
      );
      await expectLater(
        YoutubeService.getStreamForVideo(
            'https://www.youtube.com/watch?v=$id'),
        throwsA(predicate((e) =>
            e.toString().contains('sign-in') ||
            e.toString().contains('bot'))),
      );
    });

    test('maps unplayable-video detail to guidance', () async {
      final id = _id(15);
      enqueueJson({'detail': 'VideoUnavailableException'}, status: 401);
      enqueueJson({'detail': 'VideoUnavailableException'}, status: 401);
      await expectLater(
        YoutubeService.getStreamForVideo(
            'https://www.youtube.com/watch?v=$id'),
        throwsA(predicate(
            (e) => e.toString().contains('unavailable, private'))),
      );
    });
  });

  group('getStreamsForAnyUrl', () {
    test('returns streams for a YouTube URL', () async {
      final id = _id(20);
      enqueueJson(_response([
        _stream(
          type: 'combined',
          quality: '720p',
          url: 'https://googlevideo.com/any720',
          format: 'mp4',
        ),
      ]));

      final result = await YoutubeService.getStreamsForAnyUrl(
          'https://www.youtube.com/watch?v=$id');

      expect(result, isNotNull);
      expect(result!, hasLength(1));
    });

    test('throws for a YouTube URL rejected by the backend', () async {
      final id = _id(21);
      enqueueJson({'detail': 'nope'}, status: 401);
      enqueueJson({'detail': 'nope'}, status: 401);
      await expectLater(
        YoutubeService.getStreamsForAnyUrl(
            'https://www.youtube.com/watch?v=$id'),
        throwsA(isA<Exception>()),
      );
    });

    test('wraps unexpected errors when the backend is disabled', () async {
      await settings.setUseRemoteBackend(false);
      await expectLater(
        YoutubeService.getStreamsForAnyUrl('https://example.org/page'),
        throwsA(isA<Exception>()),
      );
      await settings.setUseRemoteBackend(true);
    });
  });

  group('playlist', () {
    test('maps playlist metadata, thumbnails and URLs', () async {
      enqueueJson({
        'info': {'title': 'My Playlist', 'author': 'Author', 'videoCount': 2},
        'videos': [
          {'id': 'vid1', 'title': 'Video 1', 'thumbnailUrl': null},
          {
            'id': 'vid2',
            'title': 'Video 2',
            'thumbnail': 'https://img/2.jpg',
            'url': '',
          },
        ],
        'note': 'served from pool',
        'nextPageToken': 'next-token',
      });

      final details = await YoutubeService.getPlaylistDetails(
          'https://www.youtube.com/playlist?list=PL1234567890');

      expect(details, isNotNull);
      expect(details!['info']['title'], 'My Playlist');
      final videos = details['videos'] as List;
      expect(videos, hasLength(2));
      expect(videos[0]['thumbnailUrl'], contains('vid1'));
      expect(videos[0]['url'], contains('vid1'));
      expect(videos[1]['thumbnailUrl'], 'https://img/2.jpg');
      expect(videos[1]['url'], contains('vid2'));
      expect(details['note'], 'served from pool');
      expect(details['nextPageToken'], 'next-token');
    });

    test('getPlaylistInfo and getPlaylistVideos reuse getPlaylistDetails',
        () async {
      enqueueJson({
        'info': {'title': 'Info Playlist', 'videoCount': 1},
        'videos': [
          {'id': 'one', 'title': 'One'},
        ],
      });
      final info = await YoutubeService.getPlaylistInfo(
          'https://www.youtube.com/playlist?list=PL1234567890');
      expect(info!['title'], 'Info Playlist');

      enqueueJson({
        'info': {'title': 'Info Playlist 2', 'videoCount': 1},
        'videos': [
          {'id': 'two', 'title': 'Two'},
        ],
      });
      final videos = await YoutubeService.getPlaylistVideos('PL1234567890');
      expect(videos, hasLength(1));
      expect(videos!.first['title'], 'Two');
    });

    test('throws for an invalid playlist url', () async {
      await expectLater(
        YoutubeService.getPlaylistDetails('this is not a playlist'),
        throwsA(isA<Exception>()),
      );
    });

    test('maps backend bad-request errors to a user exception', () async {
      for (var i = 0; i < 8; i++) {
        enqueueJson({'detail': 'bad playlist'}, status: 400);
      }
      await expectLater(
        YoutubeService.getPlaylistDetails(
            'https://www.youtube.com/playlist?list=PL1234567890'),
        throwsA(isA<Exception>()),
      );
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('search', () {
    test('returns backend results', () async {
      enqueueJson({
        'results': [
          {'title': 'Result A', 'url': 'https://example.com/a'},
          {'title': 'Result B', 'url': 'https://example.com/b'},
        ],
      });
      final results = await YoutubeService.search('flutter');
      expect(results, hasLength(2));
      expect(results.first['title'], 'Result A');
    });

    test('returns an empty list when results are missing', () async {
      enqueueJson({'other': true});
      final results = await YoutubeService.search('nothing');
      expect(results, isEmpty);
    });

    test('wraps backend errors', () async {
      // Both endpoint variations must fail so the client surfaces the error.
      enqueueJson({'detail': 'unauthorized'}, status: 401);
      enqueueJson({'detail': 'unauthorized'}, status: 401);
      await expectLater(
        YoutubeService.search('blocked'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('refreshStreamUrl', () {
    test('matches the previous itag', () async {
      final id = _id(30);
      enqueueJson(_response(_fullCatalog()));

      final result = await YoutubeService.refreshStreamUrl(
        'https://www.youtube.com/watch?v=$id',
        'https://googlevideo.com/videoplayback?itag=22&x=1',
      );

      expect(result, isNotNull);
      expect(result!['url'], 'https://googlevideo.com/m720');
      expect(result['audioUrl'], 'https://googlevideo.com/a720');
    });

    test('falls back to a quality match when the itag is gone', () async {
      final id = _id(31);
      enqueueJson(_response(_fullCatalog()));

      final result = await YoutubeService.refreshStreamUrl(
        id,
        'https://googlevideo.com/videoplayback?quality=1080p',
      );

      expect(result, isNotNull);
      expect(result!['url'], 'https://googlevideo.com/c1080');
    });

    test('falls back to the same stream type when nothing else matches',
        () async {
      final id = _id(32);
      enqueueJson(_response(_fullCatalog()));

      final result = await YoutubeService.refreshStreamUrl(
        id,
        'https://googlevideo.com/videoplayback?mime=audio&x=1',
      );

      expect(result, isNotNull);
      expect(result!['url'], 'https://googlevideo.com/a160f');
    });
  });

  group('getFreshStreams', () {
    test('prefers the requested stream type', () async {
      final id = _id(40);
      enqueueJson(_response(_fullCatalog()));

      final result =
          await YoutubeService.getFreshStreams(id, preferredType: 'audio');
      expect(result, isNotNull);
      expect(result!['url'], 'https://googlevideo.com/a160f');
    });

    test('prefers combined when no type is requested', () async {
      final id = _id(41);
      enqueueJson(_response(_fullCatalog()));

      final result = await YoutubeService.getFreshStreams(id);
      expect(result, isNotNull);
      expect(result!['url'], 'https://googlevideo.com/c1080');
    });

    test('falls back to muxed when combined is unavailable', () async {
      final id = _id(42);
      enqueueJson(_response([
        _stream(
          type: 'video_audio',
          quality: '720p',
          url: 'https://googlevideo.com/freshmux',
          audioUrl: 'https://googlevideo.com/freshaudio',
          format: 'mp4',
        ),
      ]));

      final result = await YoutubeService.getFreshStreams(id);
      expect(result, isNotNull);
      expect(result!['url'], 'https://googlevideo.com/freshmux');
      expect(result['audioUrl'], isNull);
    });

    test('falls back to the first stream of any type', () async {
      final id = _id(43);
      enqueueJson(_response([
        _stream(
          type: 'video_only',
          quality: '480p',
          url: 'https://googlevideo.com/freshvideo',
          format: 'webm',
        ),
      ]));

      final result = await YoutubeService.getFreshStreams(id);
      expect(result, isNotNull);
      expect(result!['url'], 'https://googlevideo.com/freshvideo');
    });
  });

  group('cached fallback', () {
    test('serves the offline cache when the remote backend is disabled',
        () async {
      final id = _id(50);
      enqueueJson(_response(_fullCatalog()));
      await YoutubeService.getStreams('https://www.youtube.com/watch?v=$id');

      await settings.setUseRemoteBackend(false);
      final streams = await YoutubeService.getStreams(
          'https://www.youtube.com/watch?v=$id');
      await settings.setUseRemoteBackend(true);

      expect(streams, hasLength(4));
    });

    test('falls back to the cache when the backend errors', () async {
      final id = _id(51);
      enqueueJson(_response(_fullCatalog()));
      await YoutubeService.getStreams('https://www.youtube.com/watch?v=$id');

      enqueueJson({'detail': 'nope'}, status: 401);
      enqueueJson({'detail': 'nope'}, status: 401);
      final streams = await YoutubeService.getStreams(
        'https://www.youtube.com/watch?v=$id',
        forceRefresh: true,
      );

      expect(streams, hasLength(4));
    });
  });

  group('request headers', () {
    test('forwards the OAuth token to the backend', () async {
      final id = _id(52);
      await YoutubeService.signInWithOAuth('oauth-token-xyz');
      enqueueJson(_response([
        _stream(
          type: 'combined',
          quality: '720p',
          url: 'https://googlevideo.com/oauth720',
          format: 'mp4',
        ),
      ]));

      await YoutubeService.getStreams('https://www.youtube.com/watch?v=$id');

      expect(
        server.capturedRequests.last.headers['x-youtube-oauth'],
        'oauth-token-xyz',
      );
      await YoutubeService.clearOAuth();
    });

    test('forwards cookies for YouTube URLs via getStreamsForAnyUrl',
        () async {
      final id = _id(53);
      await settings.setSendBrowserCookiesToBackend(true);
      await YoutubeService.signIn('SID=abc');
      enqueueJson(_response([
        _stream(
          type: 'combined',
          quality: '720p',
          url: 'https://googlevideo.com/cookieany',
          format: 'mp4',
        ),
      ]));

      final result = await YoutubeService.getStreamsForAnyUrl(
          'https://www.youtube.com/watch?v=$id');

      expect(result, isNotNull);
      await YoutubeService.signOut();
      await settings.setSendBrowserCookiesToBackend(false);
    });
  });

  group('playlist extras', () {
    test('accepts a bare playlist id and forwards paging parameters',
        () async {
      enqueueJson({
        'info': {'title': 'Bare Playlist', 'videoCount': 1},
        'videos': [
          {'id': 'p1', 'title': 'P1'},
        ],
      });

      final details = await YoutubeService.getPlaylistDetails(
        'PL1234567890',
        pageToken: 'token-1',
        pageSize: 25,
      );

      expect(details!['info']['title'], 'Bare Playlist');
      expect(
        server.capturedRequests.last.uri.queryParameters['pageToken'],
        'token-1',
      );
      expect(
        server.capturedRequests.last.uri.queryParameters['pageSize'],
        '25',
      );
    });

    test('maps unauthorized playlist errors', () async {
      enqueueJson({'detail': 'nope'}, status: 401);
      await expectLater(
        YoutubeService.getPlaylistDetails(
            'https://www.youtube.com/playlist?list=PL1234567890'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('stream parsing extras', () {
    test('parses alternate thumbnail and audioSrc keys', () async {
      final id = _id(58);
      enqueueJson({
        'title': 'Alt',
        'thumbnailUrl': 'https://img.alt/t.jpg',
        'streams': [
          {
            'type': 'combined',
            'quality': '720p',
            'src': 'https://googlevideo.com/altsrc',
            'audioSrc': 'https://googlevideo.com/altaudio',
            'size': 10,
            'ext': 'mp4',
          },
        ],
      });

      final streams = await YoutubeService.getStreams(
          'https://www.youtube.com/watch?v=$id');

      expect(streams.single['thumbnailUrl'], 'https://img.alt/t.jpg');
      expect(streams.single['audioSrc'], 'https://googlevideo.com/altaudio');
    });

    test('best_muxed falls back to the first available stream', () async {
      final id = _id(57);
      enqueueJson(_response([
        _stream(
          type: 'audio_only',
          quality: '160kbps',
          url: 'https://googlevideo.com/aonly',
          ext: 'm4a',
        ),
      ]));
      await YoutubeService.getStreams('https://www.youtube.com/watch?v=$id');

      final best = await YoutubeService.getStreamForVideo(id, 'best_muxed');
      expect(best!['type'], 'audio');
    });

    test('sorts combined streams when selecting a lower quality', () async {
      final id = _id(55);
      enqueueJson(_response([
        _stream(
          type: 'combined',
          quality: '1080p',
          url: 'https://googlevideo.com/c1080b',
          format: 'mp4',
        ),
        _stream(
          type: 'combined',
          quality: '720p',
          url: 'https://googlevideo.com/c720b',
          format: 'mp4',
        ),
      ]));
      await YoutubeService.getStreams('https://www.youtube.com/watch?v=$id');

      final best = await YoutubeService.getStreamForVideo(id, '2160p');
      expect(best!['quality'], '1080p');
    });

    test('sorts muxed streams when selecting a lower quality', () async {
      final id = _id(56);
      enqueueJson(_response([
        _stream(
          type: 'video_audio',
          quality: '720p',
          url: 'https://googlevideo.com/m720b',
          audioUrl: 'https://googlevideo.com/a720b',
          format: 'mp4',
        ),
        _stream(
          type: 'video_audio',
          quality: '360p',
          url: 'https://googlevideo.com/m360b',
          audioUrl: 'https://googlevideo.com/a360b',
          format: 'mp4',
        ),
      ]));
      await YoutubeService.getStreams('https://www.youtube.com/watch?v=$id');

      final best = await YoutubeService.getStreamForVideo(id, '1080p');
      expect(best!['quality'], '720p');
    });
  });

  group('refreshStreamUrl extras', () {
    test('falls back to same-type streams when itag and quality are gone',
        () async {
      final id = _id(54);
      enqueueJson(_response([
        _stream(
          type: 'audio_only',
          quality: '128kbps',
          url: 'https://googlevideo.com/a128',
          ext: 'm4a',
        ),
        _stream(
          type: 'audio_only',
          quality: '160kbps',
          url: 'https://googlevideo.com/a160b',
          ext: 'm4a',
        ),
      ]));

      final result = await YoutubeService.refreshStreamUrl(
        id,
        'https://googlevideo.com/videoplayback?itag=999&mime=audio',
      );

      expect(result, isNotNull);
      expect(result!['url'], isNotNull);
    });
  });
}
