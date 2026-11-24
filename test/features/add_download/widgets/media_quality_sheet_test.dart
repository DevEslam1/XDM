import 'package:dmx/features/add_download/widgets/media_quality_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/test_helpers.dart';

void _big(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void _drain(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

Future<void> _pumpSheet(
  WidgetTester tester,
  List<Map<String, dynamic>> streams,
) async {
  await tester.pumpWidget(createTestApp(
    child: Builder(builder: (context) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          showModalBottomSheet<Map<String, dynamic>>(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => MediaQualitySheet(
              videoUrl: 'https://www.youtube.com/watch?v=abc',
              preloadedStreams: streams,
            ),
          );
        }
      });
      return const SizedBox.shrink();
    }),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

List<Map<String, dynamic>> _richStreams() => [
      {
        'type': 'audio',
        'quality': '128kbps',
        'size': 3000000,
        'src': 'https://cdn.example.com/a.m4a',
        'ext': 'm4a',
        'label': 'Audio A',
        'title': 'My Video',
      },
      {
        'type': 'audio',
        'quality': '128kbps',
        'size': 5000000,
        'src': 'https://cdn.example.com/b.m4a',
        'ext': 'm4a',
        'label': 'Audio B',
      },
      {
        'type': 'audio',
        'quality': '128kbps',
        'size': 1000000,
        'src': 'https://cdn.example.com/c.m4a',
        'ext': 'm4a',
        'label': 'Audio C',
      },
      {
        'type': 'video_only',
        'quality': '1080p',
        'ext': 'webm',
        'size': 700,
        'videoSize': 700
      },
      {
        'type': 'video_only',
        'quality': '1080p',
        'ext': 'mkv',
        'size': 900,
        'videoSize': 900
      },
      {
        'type': 'muxed',
        'quality': '1080p',
        'ext': 'mp4',
        'size': 500,
        'videoSize': 500
      },
      {
        'type': 'video_only',
        'quality': '1080p',
        'ext': 'webm',
        'size': 5000,
        'videoSize': 5000
      },
      {
        'type': 'video_only',
        'quality': '480p',
        'ext': 'mp4',
        'size': 400,
        'videoSize': 400
      },
      {
        'type': 'muxed',
        'quality': '360p',
        'ext': 'mp4',
        'size': 300,
        'videoSize': 300,
        'audioSrc': 'https://cdn.example.com/muxed',
      },
      {
        'type': 'video_only',
        'quality': '720p',
        'ext': 'mp4',
        'size': 150,
        'videoSize': 150,
        'audioSrc': 'https://cdn.example.com/embedded',
      },
      {
        'type': 'video_only',
        'quality': '',
        'ext': 'webm',
        'size': 0,
        'videoSize': 0
      },
      {
        'type': 'muxed',
        'quality': '240p',
        'ext': 'mp4',
        'size': 0,
        'videoSize': 0
      },
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MediaQualitySheet video tab', () {
    testWidgets('processes and renders combined video streams', (tester) async {
      _big(tester);
      await _pumpSheet(tester, _richStreams());

      expect(find.byType(MediaQualitySheet), findsOneWidget);
      expect(find.text('My Video'), findsOneWidget);
      expect(find.text('RECOMMENDED'), findsOneWidget);
      expect(find.text('VIDEO'), findsWidgets);

      // 1080p is paired + labelled, and the mp4 duplicate won.
      expect(find.text('1080p MP4'), findsOneWidget);
      expect(find.text('RECOMMENDED'), findsOneWidget);
      _drain(tester);
    });

    testWidgets('switches to the audio tab and lists audio streams',
        (tester) async {
      _big(tester);
      await _pumpSheet(tester, _richStreams());

      await tester.tap(find.byIcon(Icons.audiotrack_rounded));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.text('Audio A'), findsOneWidget);
      expect(find.text('Audio B'), findsOneWidget);
      expect(find.text('Audio C'), findsOneWidget);
    });

    testWidgets('tapping a stream returns it from the modal', (tester) async {
      _big(tester);
      Map<String, dynamic>? result;

      await tester.pumpWidget(createTestApp(
        child: Builder(builder: (context) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) {
              showModalBottomSheet<Map<String, dynamic>>(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => MediaQualitySheet(
                  videoUrl: 'https://www.youtube.com/watch?v=abc',
                  preloadedStreams: _richStreams(),
                ),
              ).then((value) => result = value);
            }
          });
          return const SizedBox.shrink();
        }),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('720p MP4'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      expect(result, isNotNull);
      expect(result!['quality'], '720p');
    });
  });

  group('MediaQualitySheet empty lists', () {
    testWidgets('shows no-video notice when only audio exists', (tester) async {
      _big(tester);
      await _pumpSheet(tester, [
        {
          'type': 'audio',
          'quality': '128kbps',
          'size': 1000,
          'src': 'https://cdn.example.com/a.m4a',
          'ext': 'm4a',
          'label': 'Solo Audio',
        },
      ]);

      expect(find.text('No video streams found.'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.audiotrack_rounded));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Solo Audio'), findsOneWidget);
      _drain(tester);
    });

    testWidgets('shows no-audio notice when only video exists', (tester) async {
      _big(tester);
      await _pumpSheet(tester, [
        {
          'type': 'muxed',
          'quality': '720p',
          'size': 1000,
          'videoSize': 1000,
          'ext': 'mp4',
          'label': 'Only Video',
          'audioSrc': 'https://cdn.example.com/x',
        },
      ]);

      await tester.tap(find.byIcon(Icons.audiotrack_rounded));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('No audio streams found.'), findsOneWidget);
      _drain(tester);
    });
  });

  group('MediaQualitySheet silent video warning', () {
    testWidgets('cancel keeps the sheet open, proceed returns the stream',
        (tester) async {
      _big(tester);
      Map<String, dynamic>? result;

      await tester.pumpWidget(createTestApp(
        child: Builder(builder: (context) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) {
              showModalBottomSheet<Map<String, dynamic>>(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => const MediaQualitySheet(
                  videoUrl: 'https://www.youtube.com/watch?v=silent',
                  preloadedStreams: [
                    {
                      'type': 'video_only',
                      'quality': '1080p',
                      'size': 1000,
                      'videoSize': 1000,
                      'ext': 'mp4',
                    },
                  ],
                ),
              ).then((value) => result = value);
            }
          });
          return const SizedBox.shrink();
        }),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('Stream'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Silent Video Warning'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(result, isNull);
      expect(find.byType(MediaQualitySheet), findsOneWidget);

      await tester.tap(find.text('Stream'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('PROCEED'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      expect(result, isNotNull);
    });
  });
}
