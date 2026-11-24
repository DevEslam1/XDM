import 'dart:convert';
import 'dart:io';

import 'package:dmx/core/services/backend_health_service.dart';
import 'package:dmx/core/services/xdm_backend_client.dart';
import 'package:dmx/core/services/youtube_service.dart';
import 'package:dmx/features/add_download/widgets/media_quality_sheet.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/fake_http_overrides.dart';
import '../../../helpers/test_helpers.dart';

Map<String, dynamic> _streamsBody() => {
      'title': 'Backend Video',
      'thumbnail': 'https://img.example/thumb.jpg',
      'streams': [
        {
          'type': 'combined',
          'quality': '1080p',
          'url': 'https://googlevideo.com/c1080',
          'size': 1000,
          'itag': 137,
          'format': 'mp4',
        },
        {
          'type': 'video_audio',
          'quality': '720p',
          'url': 'https://googlevideo.com/m720',
          'audio_url': 'https://googlevideo.com/a720',
          'video_size': 500,
          'audio_size': 100,
          'itag': 22,
          'format': 'mp4',
        },
        {
          'type': 'audio_only',
          'quality': '160kbps',
          'url': 'https://googlevideo.com/a160f',
          'size': 50,
          'ext': 'm4a',
        },
        {
          'type': 'video_only',
          'quality': '480p',
          'url': 'https://googlevideo.com/v480',
          'size': 70,
          'ext': 'webm',
          'format': 'webm',
        },
      ],
    };

void _big(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void _drain(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

Future<void> _openSheet(WidgetTester tester,
    {String videoUrl = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'}) async {
  await tester.pumpWidget(createTestApp(
    child: Builder(builder: (context) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          showModalBottomSheet<dynamic>(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => MediaQualitySheet(videoUrl: videoUrl),
          );
        }
      });
      return const SizedBox.shrink();
    }),
  ));
  await tester.pump();
}

Future<void> _pumpUntil(WidgetTester tester, Finder target,
    {int maxSeconds = 40}) async {
  for (var i = 0; i < maxSeconds; i++) {
    if (target.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(seconds: 1));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(setupTestPluginMocks);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsProvider.instance;
    await settings.load();
    await settings.setUseRemoteBackend(true);
    await settings.setSendBrowserCookiesToBackend(false);
    await XdmBackendClient.setApiKey('test-key');
    BackendHealthService.instance.resetCooldowns();
    YoutubeService.resetClientCooldowns();
    await settings.setBackendUrl('http://127.0.0.1:9000');
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  group('MediaQualitySheet fetched', () {
    testWidgets('shows loading then renders fetched streams', (tester) async {
      _big(tester);
      HttpOverrides.global = FakeHttpOverrides(
        utf8.encode(jsonEncode(_streamsBody())),
        delay: const Duration(milliseconds: 800),
      );

      await _openSheet(tester);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Fetching available streams...'), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 200));
      _drain(tester);

      expect(find.text('Backend Video'), findsOneWidget);
      expect(find.text('YOUTUBE VIDEO QUALITY'), findsOneWidget);
      expect(find.text('RECOMMENDED'), findsOneWidget);
    });

    testWidgets('switching tabs and refreshing keeps the sheet stable',
        (tester) async {
      _big(tester);
      HttpOverrides.global = FakeHttpOverrides(
        utf8.encode(jsonEncode(_streamsBody())),
      );

      await _openSheet(tester);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 200));
      _drain(tester);

      expect(find.text('Backend Video'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.audiotrack_rounded));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.text('AUDIO'), findsWidgets);

      await tester.tap(find.byIcon(Icons.refresh_rounded));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 200));
      _drain(tester);

      expect(find.byType(MediaQualitySheet), findsOneWidget);
    });

    testWidgets('surfaces an error state when no streams are returned',
        (tester) async {
      _big(tester);
      HttpOverrides.global = FakeHttpOverrides(
        utf8.encode(jsonEncode({'title': 'Empty'})),
      );

      await _openSheet(tester,
          videoUrl: 'https://www.youtube.com/watch?v=ERRdQw4w9Wg');
      await _pumpUntil(tester, find.text('RETRY'));
      _drain(tester);

      expect(
        find.textContaining('Cannot reach the extraction backend'),
        findsOneWidget,
      );
      expect(find.text('RETRY'), findsOneWidget);

      await tester.tap(find.text('RETRY'));
      await tester.pump();
      await _pumpUntil(tester, find.text('RETRY'));
      _drain(tester);

      expect(
        find.textContaining('Cannot reach the extraction backend'),
        findsOneWidget,
      );
    });
  });
}
