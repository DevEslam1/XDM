import 'dart:io';

import 'package:dmx/core/services/backend_health_service.dart';
import 'package:dmx/core/services/xdm_backend_client.dart';
import 'package:dmx/core/services/xdm_backend_exceptions.dart';
import 'package:dmx/core/services/youtube_service.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const extractorChannel = MethodChannel('com.example.dmx/youtube_extractor');
  const storageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const testUrl = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';

  late HttpServer server;
  late int requestCount;

  void mockExtractorChannel(List<Map<String, dynamic>>? result) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(extractorChannel, (call) async {
      expect(call.method, 'getStreams');
      return result;
    });
  }

  setUp(() async {
    // TestWidgetsFlutterBinding installs a mock HttpOverrides that answers
    // every request with 400. Restore real networking so the local test
    // server actually receives the backend calls.
    HttpOverrides.global = null;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, (methodCall) async => null);
    SharedPreferences.setMockInitialValues({});

    final settings = SettingsProvider.instance;
    await settings.load();
    await settings.setUseLocalYtFallback(true);
    await XdmBackendClient.setApiKey('test-key');
    // Clear unhealthy marks from earlier tests so a reused ephemeral port is
    // not skipped as a backend.
    BackendHealthService.instance.resetCooldowns();

    requestCount = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      requestCount++;
      // 500 → BackendNetworkException → triggers the local fallback path.
      request.response.statusCode = 500;
      request.response.close();
    });
    await settings.setBackendUrl('http://127.0.0.1:${server.port}');
  });

  tearDown(() async {
    await XdmBackendClient.setApiKey('');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(extractorChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, null);
    await server.close(force: true);
  });

  test('backend network error triggers local fallback path', () async {
    mockExtractorChannel([
      {
        'src': 'https://example.com/video.mp4',
        'type': 'muxed',
        'quality': '1080p',
        'ext': 'mp4',
        'title': 'Test Video',
        'size': 1000,
        'videoSize': 1000,
      },
    ]);

    final streams = await YoutubeService.getStreams(testUrl);
    expect(streams, isNotEmpty);
    expect(streams.first['type'], 'muxed');
    expect(streams.first['title'], 'Test Video');
  });

  test('connection error triggers fallback path', () async {
    // Bind and immediately close a server so its port refuses connections.
    final deadServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = deadServer.port;
    await deadServer.close(force: true);
    await SettingsProvider.instance
        .setBackendUrl('http://127.0.0.1:$deadPort');

    mockExtractorChannel([
      {
        'src': 'https://example.com/video.mp4',
        'type': 'audio',
        'quality': '128kbps',
        'ext': 'mp4',
        'title': 'Audio Only',
        'size': 500,
      },
    ]);

    final streams = await YoutubeService.getStreams(testUrl);
    expect(streams, isNotEmpty);
    expect(streams.first['type'], 'audio');
  });

  test('all methods failing shows error to user', () async {
    // Local extractor returns nothing → total failure must surface an error.
    mockExtractorChannel(null);

    await expectLater(
      YoutubeService.getStreams(testUrl),
      throwsA(isA<Exception>()),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('local fallback is skipped when disabled in settings', () async {
    await SettingsProvider.instance.setUseLocalYtFallback(false);
    var channelCalled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(extractorChannel, (call) async {
      channelCalled = true;
      return <Map<String, dynamic>>[];
    });

    await expectLater(
      YoutubeService.getStreams(testUrl),
      throwsA(isA<Exception>()),
    );
    expect(channelCalled, isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('retry with exponential backoff retries before final failure', () async {
    mockExtractorChannel(null);

    await expectLater(
      YoutubeService.getStreams(testUrl),
      throwsA(isA<Exception>()),
    );
    // Initial attempt + 2 retries = at least 3 backend requests.
    expect(requestCount, greaterThanOrEqualTo(3));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('XdmBackendTimeoutException is typed as a BackendException', () {
    const e = XdmBackendTimeoutException('Request timed out after 30s');
    expect(e, isA<BackendException>());
    expect(e.toUserMessage(), contains('30s'));
  });
}
