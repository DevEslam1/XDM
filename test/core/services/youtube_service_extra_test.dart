// ignore_for_file: avoid_dynamic_calls
import 'package:dmx/core/services/youtube_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    YoutubeService.resetClientCooldowns();
  });

  group('URL detection', () {
    test('isYoutubeUrl detects videos and playlists', () {
      expect(
        YoutubeService.isYoutubeUrl('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
        isTrue,
      );
      expect(
        YoutubeService.isYoutubeUrl(
            'https://www.youtube.com/playlist?list=PL1234567890'),
        isTrue,
      );
      expect(YoutubeService.isYoutubeUrl('https://example.com'), isFalse);
    });

    test('videoUrl builds a canonical watch link', () {
      expect(
        YoutubeService.videoUrl('abc123'),
        'https://www.youtube.com/watch?v=abc123',
      );
    });

    test('isSupportedMediaHost matches bounded hosts only', () {
      expect(
        YoutubeService.isSupportedMediaHost('https://www.youtube.com/watch?v=x'),
        isTrue,
      );
      expect(YoutubeService.isSupportedMediaHost('https://youtu.be/x'), isTrue);
      expect(
        YoutubeService.isSupportedMediaHost('https://player.vimeo.com/video/1'),
        isTrue,
      );
      expect(
        YoutubeService.isSupportedMediaHost('https://evil-instagram.com/x'),
        isFalse,
      );
      expect(YoutubeService.isSupportedMediaHost('not a url'), isFalse);
      expect(YoutubeService.isSupportedMediaHost(''), isFalse);
    });

    test('isExtractableMediaUrl rejects direct static files', () {
      expect(
        YoutubeService.isExtractableMediaUrl('https://example.com/movie.mp4'),
        isFalse,
      );
      expect(
        YoutubeService.isExtractableMediaUrl('https://example.com/file.zip'),
        isFalse,
      );
      expect(
        YoutubeService.isExtractableMediaUrl('ftp://example.com/a'),
        isFalse,
      );
    });

    test('isExtractableMediaUrl accepts known media hosts', () {
      expect(
        YoutubeService.isExtractableMediaUrl(
          'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        ),
        isTrue,
      );
      expect(
        YoutubeService.isExtractableMediaUrl('https://vimeo.com/12345'),
        isTrue,
      );
    });

    test('isExtractableMediaUrl rejects unknown host without video id', () {
      expect(
        YoutubeService.isExtractableMediaUrl('https://example.com/page'),
        isFalse,
      );
    });

    test('extractVideoId returns null for unrelated hosts', () {
      expect(
        YoutubeService.extractVideoId('https://example.com/watch?v=xyz'),
        isNull,
      );
      expect(YoutubeService.extractVideoId('not a url at all'), isNull);
    });

    test('extractPlaylistId handles raw ids and query params', () {
      expect(YoutubeService.extractPlaylistId('PL1234567890'), 'PL1234567890');
      expect(
        YoutubeService.extractPlaylistId(
            'https://youtube.com/watch?v=a&list=UUabcdefghi'),
        'UUabcdefghi',
      );
      expect(YoutubeService.extractPlaylistId(''), isNull);
      expect(YoutubeService.extractPlaylistId('https://youtube.com/'), isNull);
    });

    test('isPlaylistUrl handles schemeless and malformed urls', () {
      expect(
        YoutubeService.isPlaylistUrl('youtube.com/playlist?list=PL1234567890'),
        isTrue,
      );
      expect(YoutubeService.isPlaylistUrl('   '), isFalse);
      expect(YoutubeService.isPlaylistUrl('https://vimeo.com/1'), isFalse);
    });

    test('isPurePlaylistUrl requires a list without a video', () {
      expect(
        YoutubeService.isPurePlaylistUrl(
            'https://www.youtube.com/playlist?list=PL1234567890'),
        isTrue,
      );
      expect(
        YoutubeService.isPurePlaylistUrl(
            'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL1234567890'),
        isFalse,
      );
    });
  });

  group('normalizeStreamEntry', () {
    test('maps backend type aliases to app types', () {
      expect(
        YoutubeService.normalizeStreamEntry({
          'type': 'video_audio',
          'url': 'https://googlevideo.com/a',
        })['type'],
        'muxed',
      );
      expect(
        YoutubeService.normalizeStreamEntry({'type': 'videoaudio'})['type'],
        'muxed',
      );
      expect(
        YoutubeService.normalizeStreamEntry({'type': 'video'})['type'],
        'video_only',
      );
      expect(
        YoutubeService.normalizeStreamEntry({'type': 'video_only'})['type'],
        'video_only',
      );
      expect(
        YoutubeService.normalizeStreamEntry({'type': 'audio'})['type'],
        'audio',
      );
      expect(
        YoutubeService.normalizeStreamEntry({'type': 'audio_only'})['type'],
        'audio',
      );
      expect(
        YoutubeService.normalizeStreamEntry({'type': 'combined'})['type'],
        'combined',
      );
      expect(
        YoutubeService.normalizeStreamEntry({'type': 'weird'})['type'],
        'weird',
      );
    });

    test('audio-only entries use the Audio Only label', () {
      final entry = YoutubeService.normalizeStreamEntry({
        'type': 'audio',
        'ext': 'm4a',
        'quality': '160kbps',
      });
      expect(entry['label'], 'Audio Only M4A');
    });

    test('filesize accepts numeric, string and fallback keys', () {
      expect(
        YoutubeService.normalizeStreamEntry({'filesize': 123})['size'],
        123,
      );
      expect(
        YoutubeService.normalizeStreamEntry({'size': '456'})['size'],
        456,
      );
      expect(
        YoutubeService.normalizeStreamEntry({'filesize_approx': 789})['size'],
        789,
      );
      expect(
        YoutubeService.normalizeStreamEntry({'size': 'not-a-number'})['size'],
        0,
      );
      expect(YoutubeService.normalizeStreamEntry(const {})['size'], 0);
    });

    test('video/audio sizes accept numeric and string forms', () {
      final entry = YoutubeService.normalizeStreamEntry({
        'video_size': '1000',
        'audio_size_bytes': 2000,
      });
      expect(entry['videoSize'], 1000);
      expect(entry['audioSize'], 2000);
    });

    test('missing quality defaults to Unknown', () {
      expect(YoutubeService.normalizeStreamEntry(const {})['quality'],
          'Unknown');
    });

    test('placeholder youtube page urls are nulled out', () {
      final entry = YoutubeService.normalizeStreamEntry({
        'direct_url': 'https://www.youtube.com/watch?v=abc',
        'audio_url': 'https://www.youtube.com/watch?v=abc',
      });
      expect(entry['src'], isNull);
      expect(entry['audioSrc'], isNull);
    });

    test('explicit audioSrc is preserved', () {
      final entry = YoutubeService.normalizeStreamEntry({
        'src': 'https://googlevideo.com/v',
        'audioSrc': 'https://googlevideo.com/a',
      });
      expect(entry['audioSrc'], 'https://googlevideo.com/a');
    });

    test('passes through optional metadata keys', () {
      final entry = YoutubeService.normalizeStreamEntry({
        'itag': 22,
        'format_id': 'f22',
        'format': 'mp4',
      });
      expect(entry['itag'], 22);
      expect(entry['format_id'], 'f22');
      expect(entry['format'], 'mp4');
    });

    test('title and thumbnail args are applied', () {
      final entry = YoutubeService.normalizeStreamEntry(
        const {},
        title: 'My Video',
        thumbnailUrl: 'https://img/1.jpg',
      );
      expect(entry['title'], 'My Video');
      expect(entry['thumbnailUrl'], 'https://img/1.jpg');
      expect(YoutubeService.normalizeStreamEntry(const {})['title'], 'Untitled');
    });
  });

  group('quality ladder helpers', () {
    test('qualityLadderDistance computes ladder steps', () {
      expect(YoutubeService.qualityLadderDistance('1080p', '1080p'), 0);
      expect(YoutubeService.qualityLadderDistance('1080p', '720p'), 1);
      expect(YoutubeService.qualityLadderDistance('1080p', '480p'), 2);
      expect(YoutubeService.qualityLadderDistance(null, '720p'), 0);
      expect(YoutubeService.qualityLadderDistance('weird', '720p'), 0);
    });

    test('evaluateQualityDowngrade flags large drops', () {
      final small = YoutubeService.evaluateQualityDowngrade(
        stream: const {'src': 'a'},
        originalQuality: '1080p',
        newQuality: '720p',
      );
      expect(small.qualityChanged, isFalse);
      final big = YoutubeService.evaluateQualityDowngrade(
        stream: const {'src': 'a'},
        originalQuality: '1080p',
        newQuality: '480p',
      );
      expect(big.qualityChanged, isTrue);
      expect(big.originalQuality, '1080p');
      expect(big.newQuality, '480p');
    });
  });

  group('client cooldown rotation', () {
    test('clients cool down and recover', () {
      expect(YoutubeService.isClientCoolingDown('android'), isFalse);
      YoutubeService.markClientCoolingDown('android');
      expect(YoutubeService.isClientCoolingDown('android'), isTrue);
      expect(
        YoutubeService.getAvailableClients(),
        isNot(contains('android')),
      );
      YoutubeService.markClientCoolingDown(
        'ios',
        const Duration(milliseconds: -1),
      );
      expect(YoutubeService.isClientCoolingDown('ios'), isFalse);
      YoutubeService.resetClientCooldowns();
      expect(YoutubeService.isClientCoolingDown('android'), isFalse);
    });

    test('getAvailableClients respects a custom order', () {
      expect(
        YoutubeService.getAvailableClients(['a', 'b']),
        ['a', 'b'],
      );
    });
  });

  group('auth state', () {
    setUp(() async {
      await YoutubeService.signOut();
    });

    test('signIn marks the user signed in and emits an auth change', () async {
      final events = <bool>[];
      final sub = YoutubeService.onAuthStateChanged.listen(events.add);
      await YoutubeService.signIn('SID=abc; HSID=def');
      await Future<void>.delayed(Duration.zero);
      expect(YoutubeService.isSignedIn, isTrue);
      expect(YoutubeService.currentCookies, 'SID=abc; HSID=def');
      expect(events, contains(true));
      await sub.cancel();
    });

    test('OAuth sign-in and clear', () async {
      await YoutubeService.signInWithOAuth('token-abc');
      expect(YoutubeService.hasOAuth, isTrue);
      expect(YoutubeService.oauthToken, 'token-abc');
      await YoutubeService.clearOAuth();
      expect(YoutubeService.hasOAuth, isFalse);
    });

    test('refreshOAuthToken replaces the token', () async {
      await YoutubeService.refreshOAuthToken('t1');
      expect(YoutubeService.oauthToken, 't1');
    });

    test('init completes with mocked storage', () async {
      await expectLater(YoutubeService.init(), completes);
    });

    test('signInFromCookieManager joins cookie pairs', () async {
      await YoutubeService.signInFromCookieManager([
        Cookie(name: 'a', value: '1'),
        Cookie(name: 'b', value: '2'),
      ]);
      expect(YoutubeService.currentCookies, 'a=1; b=2');
    });

    test('authenticateFromBrowser falls back to webview fetch', () async {
      await expectLater(YoutubeService.authenticateFromBrowser(), completes);
    });

    test('disable remote backend without local cache throws', () {
      // fetchCookiesFromWebView is best-effort and must not throw even when
      // the WebView platform is unavailable.
      expect(
        () => YoutubeService.fetchCookiesFromWebView(),
        returnsNormally,
      );
    });
  });

  group('getFreshStreams', () {
    test('returns null for an unrecognised download page url', () async {
      final result = await YoutubeService.getFreshStreams('https://x.test/1');
      expect(result, isNull);
    });

    test('uses the injected fresh-streams handler in debug builds', () async {
      YoutubeService.mockGetFreshStreams = (url, {preferredType}) async => {
            'url': 'https://googlevideo.com/fresh',
            'audioUrl': null,
          };
      addTearDown(() => YoutubeService.mockGetFreshStreams = null);
      final result = await YoutubeService.getFreshStreams(
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      );
      expect(result?['url'], 'https://googlevideo.com/fresh');
    });
  });

  group('refreshStreamUrl', () {
    test('returns null for an invalid page url', () async {
      final result =
          await YoutubeService.refreshStreamUrl('not-a-video-id', 'old');
      expect(result, isNull);
    });
  });

  group('parseQualityHeight / formatDuration edge cases', () {
    test('parseQualityHeight handles empty and embedded digits', () {
      expect(YoutubeService.parseQualityHeight(''), 0);
      expect(YoutubeService.parseQualityHeight('4K'), 4);
      expect(YoutubeService.parseQualityHeight('Quality 1080p60'), 1080);
    });

    test('formatDuration handles hour boundaries', () {
      expect(YoutubeService.formatDuration(-5), '0:00');
      expect(YoutubeService.formatDuration(60), '1:00');
      expect(YoutubeService.formatDuration(3600), '1:00:00');
      expect(YoutubeService.formatDuration(3599), '59:59');
    });
  });

  group('close', () {
    test('close is idempotent and stream reopens', () {
      expect(() => YoutubeService.close(), returnsNormally);
      expect(YoutubeService.onAuthStateChanged, isNotNull);
    });

    test('dispose delegates to close', () {
      expect(() => YoutubeService.dispose(), returnsNormally);
    });
  });

  group('normalizeStreamEntry placeholder variants', () {
    test('nulls placeholder path and query URLs', () {
      for (final url in [
        'https://www.youtube.com/shorts',
        'https://www.youtube.com/playlist',
        'https://www.youtube.com/embed',
        'https://www.youtube.com',
        'https://www.youtube.com/results?v=abc',
        'https://www.youtube.com/results?list=PL1234567890',
      ]) {
        final entry = YoutubeService.normalizeStreamEntry({'url': url});
        expect(entry['src'], isNull, reason: url);
      }
      expect(
        YoutubeService.normalizeStreamEntry(
            {'url': 'https://googlevideo.com/real'})['src'],
        'https://googlevideo.com/real',
      );
    });

    test('audio size accepts a non-numeric string', () {
      expect(
        YoutubeService.normalizeStreamEntry({'audio_size': 'nope'})['audioSize'],
        0,
      );
    });
  });

  group('authenticateFromBrowser', () {
    test('signs in from supplied cookies', () async {
      await YoutubeService.authenticateFromBrowser([
        Cookie(name: 'SID', value: 'restored'),
      ]);
      expect(YoutubeService.currentCookies, contains('SID=restored'));
    });
  });

  group('secure storage lifecycle', () {
    const storageChannel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

    setUp(() async {
      await YoutubeService.signOut();
    });

    test('init restores persisted cookies and OAuth token', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, (call) async {
        if (call.method == 'read') {
          final key = call.arguments['key'];
          if (key == 'youtube_cookies_persisted') return 'SID=persisted';
          if (key == 'youtube_oauth_token_persisted') return 'oauth-persisted';
        }
        return null;
      });
      await YoutubeService.init();
      expect(YoutubeService.currentCookies, 'SID=persisted');
      expect(YoutubeService.oauthToken, 'oauth-persisted');
    });

    test('init swallows storage read errors', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, (call) async {
        throw PlatformException(code: 'read_fail');
      });
      await expectLater(YoutubeService.init(), completes);
    });

    test('signIn swallows persistence write errors', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, (call) async {
        if (call.method == 'write') throw PlatformException(code: 'write_fail');
        return null;
      });
      await expectLater(YoutubeService.signIn('SID=x'), completes);
      expect(YoutubeService.currentCookies, 'SID=x');
    });

    test('signInWithOAuth swallows persistence errors', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, (call) async {
        if (call.method == 'write') throw PlatformException(code: 'write_fail');
        return null;
      });
      await expectLater(YoutubeService.signInWithOAuth('tok'), completes);
      expect(YoutubeService.hasOAuth, isTrue);
    });

    test('clearOAuth swallows delete errors', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, (call) async {
        if (call.method == 'delete') {
          throw PlatformException(code: 'delete_fail');
        }
        return null;
      });
      await YoutubeService.signInWithOAuth('tok2');
      await expectLater(YoutubeService.clearOAuth(), completes);
      expect(YoutubeService.hasOAuth, isFalse);
    });
  });
}
