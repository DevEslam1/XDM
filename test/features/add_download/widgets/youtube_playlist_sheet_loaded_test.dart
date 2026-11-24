import 'dart:convert';
import 'dart:io';

import 'package:dmx/core/services/backend_health_service.dart';
import 'package:dmx/core/services/xdm_backend_client.dart';
import 'package:dmx/core/services/youtube_service.dart';
import 'package:dmx/features/add_download/widgets/youtube_playlist_sheet.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/fake_http_overrides.dart';
import '../../../helpers/test_helpers.dart';

Map<String, dynamic> _playlistBody({bool hasMore = false}) => {
      'info': {
        'title': 'My Playlist',
        'author': 'Tester',
        'videoCount': 3,
      },
      'videos': [
        {
          'id': 'vid00000001',
          'title': 'First Video',
          'duration': 65,
          'author': 'Chan A',
          'thumbnailUrl': '',
        },
        {
          'id': 'vid00000002',
          'title': 'Second Video',
          'duration': 130,
          'author': 'Chan B',
          'thumbnailUrl': '',
        },
        {
          'id': 'vid00000003',
          'title': 'Third Video',
          'duration': 5,
          'author': 'Chan C',
          'thumbnailUrl': '',
        },
      ],
      'note': 'Playlist note',
      if (hasMore) 'nextPageToken': 'TOKEN2',
    };

void _big(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void _drain(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

Future<DownloadProvider> _pumpLoadedSheet(
  WidgetTester tester, {
  bool hasMore = false,
}) async {
  HttpOverrides.global = FakeHttpOverrides(
    utf8.encode(jsonEncode(_playlistBody(hasMore: hasMore))),
  );
  final provider = createMockDownloadProvider();

  await tester.pumpWidget(createTestApp(
    downloadProvider: provider,
    child: Builder(builder: (context) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          showModalBottomSheet<dynamic>(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => const YoutubePlaylistSheet(
              playlistUrl: 'https://www.youtube.com/playlist?list=PLTEST123',
            ),
          );
        }
      });
      return const SizedBox.shrink();
    }),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
  return provider;
}

Future<void> _pumpSheetWithBody(
  WidgetTester tester,
  Map<String, dynamic> body,
) async {
  HttpOverrides.global = FakeHttpOverrides(utf8.encode(jsonEncode(body)));
  await tester.pumpWidget(createTestApp(
    child: Builder(builder: (context) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          showModalBottomSheet<dynamic>(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => const YoutubePlaylistSheet(
              playlistUrl: 'https://www.youtube.com/playlist?list=PLTEST123',
            ),
          );
        }
      });
      return const SizedBox.shrink();
    }),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsProvider settings;

  setUpAll(() {
    setupTestPluginMocks();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsProvider.instance;
    await settings.load();
    await settings.setUseRemoteBackend(true);
    await settings.setSendBrowserCookiesToBackend(false);
    await XdmBackendClient.setApiKey('test-key');
    BackendHealthService.instance.resetCooldowns();
    YoutubeService.resetClientCooldowns();
    await settings.setBackendUrl('http://127.0.0.1:9000');
    settings.customDownloadPath = '/tmp/dmx-playlist';
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  group('YoutubePlaylistSheet loaded', () {
    testWidgets('renders playlist videos, note and author', (tester) async {
      _big(tester);
      await _pumpLoadedSheet(tester);
      _drain(tester);

      expect(find.text('My Playlist'), findsOneWidget);
      expect(find.text('First Video'), findsOneWidget);
      expect(find.text('Second Video'), findsOneWidget);
      expect(find.text('Third Video'), findsOneWidget);
      expect(find.text('Playlist note'), findsOneWidget);
      expect(find.text('Tester'), findsOneWidget);
      expect(find.textContaining('3 videos'), findsOneWidget);
    });

    testWidgets('select all then deselect all toggles the CTA', (tester) async {
      _big(tester);
      await _pumpLoadedSheet(tester);
      _drain(tester);

      expect(find.text('DOWNLOAD 0 VIDEOS'), findsOneWidget);
      expect(
        find.text('Select at least 1 video to start download'),
        findsOneWidget,
      );

      await tester.tap(find.text('SELECT ALL'));
      await tester.pump(const Duration(milliseconds: 250));
      _drain(tester);

      expect(find.text('DOWNLOAD 3 VIDEOS'), findsOneWidget);
      expect(find.text('DESELECT ALL'), findsOneWidget);

      await tester.tap(find.text('DESELECT ALL'));
      await tester.pump(const Duration(milliseconds: 250));
      _drain(tester);

      expect(find.text('DOWNLOAD 0 VIDEOS'), findsOneWidget);
    });

    testWidgets('search field shows a clear control and filters via refresh',
        (tester) async {
      _big(tester);
      await _pumpLoadedSheet(tester);
      _drain(tester);

      expect(find.byIcon(Icons.clear), findsNothing);

      await tester.enterText(find.byType(TextField), 'Second');
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.byIcon(Icons.clear), findsOneWidget);

      // Toggling selection marks the filter cache dirty, re-running the
      // search-aware filter branch.
      await tester.tap(find.text('SELECT ALL'));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.text('Second Video'), findsOneWidget);
      expect(find.text('First Video'), findsNothing);
      expect(find.textContaining('1 / 3 videos'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.clear));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.byIcon(Icons.clear), findsNothing);
    });

    testWidgets('changing the quality preset updates the helper note',
        (tester) async {
      _big(tester);
      await _pumpLoadedSheet(tester);
      _drain(tester);

      expect(
        find.text('Note: Best video and audio will be auto-merged.'),
        findsOneWidget,
      );

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('1080p (Full HD)').last);
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      expect(
        find.text('Note: Best video and audio will be auto-merged.'),
        findsNothing,
      );
      expect(find.text('1080p (Full HD)'), findsOneWidget);
    });

    testWidgets('selecting videos enables the download CTA', (tester) async {
      _big(tester);
      await _pumpLoadedSheet(tester);
      _drain(tester);

      expect(find.text('DOWNLOAD 0 VIDEOS'), findsOneWidget);

      await tester.tap(find.text('SELECT ALL'));
      await tester.pump(const Duration(milliseconds: 250));
      _drain(tester);

      expect(find.text('DOWNLOAD 3 VIDEOS'), findsOneWidget);
    });

    testWidgets('loads more videos when scrolled to the end', (tester) async {
      _big(tester);
      await _pumpLoadedSheet(tester, hasMore: true);
      _drain(tester);

      expect(find.text('Third Video'), findsOneWidget);

      await tester.drag(find.byType(ListView), const Offset(0, -1200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      _drain(tester);

      expect(find.text('First Video'), findsWidgets);
    });

    testWidgets('reports a partial failure when metadata loads but no videos',
        (tester) async {
      _big(tester);
      await _pumpSheetWithBody(tester, {
        'info': {'title': 'Ghost Playlist', 'videoCount': 2},
        'videos': <dynamic>[],
      });
      _drain(tester);

      expect(
        find.textContaining(
            'Could not load video list for this playlist (2 videos)'),
        findsOneWidget,
      );
      expect(find.text('RETRY'), findsOneWidget);
    });

    testWidgets('reports an empty playlist when no videos are found',
        (tester) async {
      _big(tester);
      await _pumpSheetWithBody(tester, {'videos': <dynamic>[]});
      _drain(tester);

      expect(find.text('No videos found in this playlist.'), findsOneWidget);
      expect(find.text('RETRY'), findsOneWidget);
    });
  });
}
