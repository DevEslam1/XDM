import 'package:dmx/core/services/newpipe_service.dart';
import 'package:dmx/core/services/youtube_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.dmx.app/newpipe');
  const testUrl = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';

  const streamPayload = <String, dynamic>{
    'url': testUrl,
    'title': 'Rick Astley - Never Gonna Give You Up',
    'thumbnail': 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg',
    'thumbnailUrl': 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg',
    'source': 'newpipe',
    'streams': [
      {
        'type': 'muxed',
        'quality': '720p',
        'label': 'Video: 720p (Muxed)',
        'src': 'https://googlevideo.example/muxed.mp4',
        'ext': 'mp4',
        'format': 'mp4',
        'format_id': '22',
        'itag': '22',
        'manifestType': '',
        'videoSize': 1000,
        'audioSize': 0,
        'size': 1000,
      },
      {
        'type': 'video_only',
        'quality': '1080p',
        'label': 'Video Only: 1080p',
        'src': 'https://googlevideo.example/video.m4v',
        'ext': 'mp4',
        'format': 'mp4',
        'format_id': '137',
        'itag': '137',
        'manifestType': 'dash',
        'videoSize': 2000,
        'audioSize': 500,
        'size': 2500,
        'audioSrc': 'https://googlevideo.example/audio.m4a',
        'audioExt': 'm4a',
      },
      {
        'type': 'audio',
        'quality': '128kbps',
        'label': 'Audio Only: (128 Kbps)',
        'src': 'https://googlevideo.example/audio.m4a',
        'ext': 'm4a',
        'format': 'm4a',
        'format_id': '140',
        'itag': '140',
        'manifestType': '',
        'videoSize': 0,
        'audioSize': 500,
        'size': 500,
      },
    ],
  };

  void mockChannel(
    Future<Object?>? Function(MethodCall call) handler,
  ) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  setUp(() {
    mockChannel((call) async => null);
    NewPipeService.instance.clearCache();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('NewPipeService decodes native stream payload', () async {
    mockChannel((call) async {
      expect(call.method, 'getStreams');
      return streamPayload;
    });

    final raw = await NewPipeService.instance
        .getVideoStreams(testUrl, cookies: 'SID=abc');

    expect(raw['source'], 'newpipe');
    expect(raw['title'], contains('Rick Astley'));
    final streams = raw['streams'] as List;
    expect(streams, hasLength(3));
    expect((streams[0] as Map)['type'], 'muxed');
    expect((streams[1] as Map)['type'], 'video_only');
    expect((streams[1] as Map)['audioSrc'], 'https://googlevideo.example/audio.m4a');
    expect((streams[2] as Map)['type'], 'audio');
  });

  test('YoutubeService.getStreams parses native payload into maps', () async {
    mockChannel((call) async {
      expect(call.method, 'getStreams');
      expect((call.arguments as Map)['url'], testUrl);
      return streamPayload;
    });

    final results = await YoutubeService.getStreams(testUrl);
    expect(results, hasLength(3));
    expect(results[0]['type'], 'muxed');
    expect(results[1]['type'], 'video_only');
    expect(results[1]['audioSrc'], 'https://googlevideo.example/audio.m4a');
    expect(results[2]['type'], 'audio');
    expect(results[2]['itag'], '140');
  });

  test('typed extraction errors surface a friendly message', () async {
    mockChannel((call) async {
      throw PlatformException(
        code: 'age_restricted',
        message: 'Sign in to confirm your age',
      );
    });

    await expectLater(
      YoutubeService.getStreams(testUrl),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('age-restricted'),
        ),
      ),
    );
  });

  test('sign_in_required maps to sign-in message', () async {
    mockChannel((call) async {
      throw PlatformException(
        code: 'sign_in_required',
        message: 'Sign in to confirm you are not a bot',
      );
    });

    await expectLater(
      YoutubeService.getStreams(testUrl),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('sign-in'),
        ),
      ),
    );
  });

  test('in-memory cache avoids a second native call for the same URL',
      () async {
    var calls = 0;
    mockChannel((call) async {
      calls++;
      return streamPayload;
    });

    await NewPipeService.instance.getVideoStreams(testUrl);
    await NewPipeService.instance.getVideoStreams(testUrl);
    expect(calls, 1);

    NewPipeService.instance.clearCache();
    await NewPipeService.instance.getVideoStreams(testUrl);
    expect(calls, 2);
  });

  test('search decodes results', () async {
    mockChannel((call) async {
      expect(call.method, 'search');
      return [
        {
          'id': 'aaaaaaaaaaa',
          'title': 'Result title',
          'author': 'Channel',
          'thumbnail': 'https://i.ytimg.com/vi/aaaaaaaaaaa/hqdefault.jpg',
          'thumbnailUrl': 'https://i.ytimg.com/vi/aaaaaaaaaaa/hqdefault.jpg',
          'url': 'https://www.youtube.com/watch?v=aaaaaaaaaaa',
          'duration': 240,
        },
      ];
    });

    final results = await YoutubeService.search('never gonna');
    expect(results, hasLength(1));
    expect(results.first['title'], 'Result title');
    expect(results.first['duration'], 240);
  });

  test('non-Android platforms throw UnsupportedError', () async {
    final previous = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await expectLater(
        NewPipeService.instance.getVideoStreams(testUrl),
        throwsA(isA<UnsupportedError>()),
      );
      expect(NewPipeService.instance.isSupported, isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = previous;
    }
  });
}
