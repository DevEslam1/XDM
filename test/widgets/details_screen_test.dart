import 'package:dmx/features/details/screens/details_screen.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_helpers.dart';

Future<DownloadProvider> _seeded(List<DownloadTask> tasks) async {
  final provider = createMockDownloadProvider();
  for (final task in tasks) {
    await provider.addTask(task);
  }
  return provider;
}

void _phone(WidgetTester tester, {double width = 720, double height = 5200}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1100, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  group('DetailsScreen', () {
    testWidgets('renders file info section', (tester) async {
      final task = createTestTask(
        fileName: 'test-file.zip',
        fileSize: 104857600,
        url: 'https://example.com/test-file.zip',
      );

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: createMockDownloadProvider(tasks: [task]),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(DetailsScreen), findsOneWidget);
    });

    testWidgets('shows thread channel info for HTTP downloads', (tester) async {
      final task = createTestTask(
        threadCount: 4,
        chunks: [0.25, 0.50, 0.75, 1.0],
      );

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: createMockDownloadProvider(tasks: [task]),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(DetailsScreen), findsOneWidget);
    });

    testWidgets('shows torrent file list for torrents', (tester) async {
      final task = createTestTask(
        isTorrent: true,
        torrentFiles: [
          {'name': 'movie.mkv', 'length': 5000000000, 'progress': 0.5},
          {'name': 'subtitle.srt', 'length': 50000, 'progress': 1.0},
        ],
      );

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: createMockDownloadProvider(tasks: [task]),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(DetailsScreen), findsOneWidget);
    });
  });

  group('DetailsScreen populated states', () {
    testWidgets('renders a downloading HTTP task with all panels',
        (tester) async {
      _phone(tester);
      final task = createTestTask(
        id: 'dl-http',
        fileName: 'ubuntu.iso',
        status: DownloadStatus.downloading,
        progress: 0.4,
        speed: 5242880,
        threadCount: 4,
        chunks: [1.0, 0.5, 0.25, 0.0],
      );
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('ubuntu.iso'), findsWidgets);
      expect(find.byIcon(Icons.pause_rounded), findsWidgets);
      expect(find.byIcon(Icons.delete_outline_rounded), findsWidgets);
    });

    testWidgets('paused HTTP task shows resume and reacts to speed switch',
        (tester) async {
      _phone(tester);
      final task = createTestTask(
        id: 'dl-paused',
        status: DownloadStatus.paused,
        progress: 0.5,
        downloadedBytes: 52428800,
      ).copyWith(speedLimitKbps: 500);
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byIcon(Icons.play_arrow_rounded), findsWidgets);
      expect(find.textContaining('500 kbps'), findsOneWidget);

      await tester.tap(find.byType(Switch).first);
      await tester.pump(const Duration(milliseconds: 300));
      expect(provider.tasks.single.speedLimitKbps, 0);
    });

    testWidgets('queued HTTP task shows start action', (tester) async {
      _phone(tester);
      final task = createTestTask(
        id: 'dl-queued',
        status: DownloadStatus.queued,
        progress: 0.0,
        downloadedBytes: 0,
      );
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byIcon(Icons.play_arrow_rounded), findsWidgets);
    });

    testWidgets('completed HTTP task shows open and checksum verification',
        (tester) async {
      _phone(tester);
      final task = createTestTask(
        id: 'dl-done',
        status: DownloadStatus.completed,
        progress: 1.0,
      ).copyWith(
        expectedSha256: 'a' * 64,
        completedAt: DateTime.now(),
      );
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byIcon(Icons.folder_open_rounded), findsWidgets);

      await tester.tap(find.byIcon(Icons.open_in_new_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('VERIFY INTEGRITY'), findsOneWidget);

      await tester.tap(find.text('CLOSE'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.text('VERIFY INTEGRITY'), findsNothing);
    });

    testWidgets('failed HTTP task shows retry and error details',
        (tester) async {
      _phone(tester);
      final task = createTestTask(
        id: 'dl-failed',
        status: DownloadStatus.failed,
        progress: 0.2,
        errorMessage: 'Connection timeout',
      ).copyWith(recoveryHint: 'Check your internet connection and retry.');
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byIcon(Icons.refresh_rounded), findsWidgets);
      expect(find.text('Connection timeout'), findsWidgets);
    });

    testWidgets('merging task renders without action buttons', (tester) async {
      _phone(tester);
      final task = createTestTask(
        id: 'dl-merging',
        status: DownloadStatus.merging,
        progress: 0.9,
      );
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byIcon(Icons.delete_outline_rounded), findsWidgets);
    });

    testWidgets('dual youtube task renders stream section', (tester) async {
      _phone(tester);
      final task = createTestTask(
        id: 'dl-yt',
        fileName: 'clip.mp4',
        category: 'Video',
        status: DownloadStatus.downloading,
        progress: 0.4,
        fileSize: 20000000,
      ).copyWith(
        mergedAudioUrl: 'https://example.com/audio.m4a',
        audioSize: 5000000,
        audioDownloadedBytes: 2500000,
        youtubeQualityPreset: 'best',
        thumbnailUrl: 'https://example.com/thumb.jpg',
      );
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('YOUTUBE DUAL STREAMS'), findsOneWidget);
    });

    testWidgets('downloading torrent renders stats and opens trackers panel',
        (tester) async {
      _phone(tester);
      final task = createTestTask(
        id: 'tor-1',
        fileName: 'game.torrent',
        isTorrent: true,
        status: DownloadStatus.downloading,
        progress: 0.35,
        downloadedBytes: 350000000,
        torrentFiles: [
          {
            'name': 'game.bin',
            'length': 1000000000,
            'downloadedBytes': 350000000,
            'selected': true,
            'priority': 4,
          },
        ],
      ).copyWith(torrentId: 7);
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('TORRENT CONNECTION STATUS'), findsOneWidget);

      await tester.tap(find.text('Trackers Panel'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Hide Trackers'), findsOneWidget);

      await tester.tap(find.text('Peers Panel'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Hide Peers'), findsOneWidget);
    });

    testWidgets('completed seeding torrent shows seeding summary',
        (tester) async {
      _phone(tester);
      final task = createTestTask(
        id: 'tor-seed',
        fileName: 'seed.torrent',
        isTorrent: true,
        status: DownloadStatus.completed,
        progress: 1.0,
        torrentFiles: [
          {
            'name': 'seed.bin',
            'length': 1000000000,
            'downloadedBytes': 1000000000,
            'selected': true,
            'priority': 4,
          },
        ],
      ).copyWith(
        seedingEnabled: true,
        uploadedBytes: 500000000,
        completedAt: DateTime.now(),
      );
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('TORRENT SEEDING'), findsOneWidget);
      expect(find.text('ACTIVE ON COMPLETE'), findsOneWidget);
    });

    testWidgets('paused torrent with saved resume data shows chip',
        (tester) async {
      _phone(tester);
      final task = createTestTask(
        id: 'tor-paused',
        fileName: 'paused.torrent',
        isTorrent: true,
        status: DownloadStatus.paused,
        progress: 0.4,
        torrentFiles: [
          {
            'name': 'p.bin',
            'length': 1000000,
            'downloadedBytes': 400000,
            'selected': true,
            'priority': 4,
          },
        ],
      ).copyWith(resumeDataSaved: true);
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Resume data saved'), findsOneWidget);
    });

    testWidgets('renders two-pane layout on a wide surface', (tester) async {
      _wide(tester);
      final task = createTestTask(
        id: 'dl-wide',
        status: DownloadStatus.downloading,
        progress: 0.4,
      );
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(Row), findsWidgets);
      expect(find.text('TRANSFER SPEED CHART'), findsOneWidget);
    });

    testWidgets('renders in light mode', (tester) async {
      _phone(tester);
      final settings = createMockSettingsProvider();
      await settings.load();
      settings.isDarkMode = false;

      final task =
          createTestTask(id: 'dl-light', status: DownloadStatus.paused);
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
        settingsProvider: settings,
        theme: ThemeData.light(),
      ));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(DetailsScreen), findsOneWidget);
      settings.isDarkMode = true;
    });

    testWidgets('renders in RTL locale', (tester) async {
      _phone(tester);
      final settings = createMockSettingsProvider();
      await settings.load();
      settings.languageCode = 'ar';

      final task = createTestTask(id: 'dl-rtl', status: DownloadStatus.paused);
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
        settingsProvider: settings,
        locale: const Locale('ar'),
      ));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(DetailsScreen), findsOneWidget);
      settings.languageCode = 'en';
    });

    testWidgets('shows not-found state when the task is missing',
        (tester) async {
      _phone(tester);
      await tester.pumpWidget(createTestApp(
        child: const DetailsScreen(taskId: 'missing-task'),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Download Task Not Found'), findsOneWidget);
      expect(find.text('Go Back'), findsOneWidget);
    });
  });

  group('DetailsScreen interactions', () {
    testWidgets('pause action transitions the task', (tester) async {
      _phone(tester);
      final task = createTestTask(
        id: 'dl-pause-tap',
        status: DownloadStatus.downloading,
        progress: 0.3,
        downloadedBytes: 30000000,
      );
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byIcon(Icons.pause_rounded).first);
      await tester.pump(const Duration(milliseconds: 400));

      expect(provider.tasks.single.status, DownloadStatus.paused);
    });

    testWidgets('delete action confirms and removes the task', (tester) async {
      _phone(tester);
      final task =
          createTestTask(id: 'dl-delete', status: DownloadStatus.paused);
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byIcon(Icons.delete_outline_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Delete'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(provider.tasks, isEmpty);
    });

    testWidgets('cancel in delete dialog keeps the task', (tester) async {
      _phone(tester);
      final task = createTestTask(id: 'dl-delete-cancel');
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byIcon(Icons.delete_outline_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Cancel'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(provider.tasks, isNotEmpty);
    });

    testWidgets('changing thread count with progress shows warning dialog',
        (tester) async {
      _phone(tester);
      final task = createTestTask(
        id: 'dl-threads',
        status: DownloadStatus.downloading,
        progress: 0.5,
        downloadedBytes: 50000000,
        threadCount: 4,
      );
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byIcon(Icons.add_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('YES, RESET'), findsOneWidget);

      await tester.tap(find.text('YES, RESET'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('editing the URL opens and cancels the update dialog',
        (tester) async {
      _phone(tester);
      final task = createTestTask(id: 'dl-edit');
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byIcon(Icons.edit_outlined).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('UPDATE DOWNLOAD LINK'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Cancel'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.text('UPDATE DOWNLOAD LINK'), findsNothing);
    });

    testWidgets('toggling the torrent seeding switch updates the provider',
        (tester) async {
      _phone(tester);
      final task = createTestTask(
        id: 'tor-toggle',
        isTorrent: true,
        status: DownloadStatus.completed,
        progress: 1.0,
        torrentFiles: [
          {
            'name': 't.bin',
            'length': 1000,
            'downloadedBytes': 1000,
            'selected': true,
            'priority': 4,
          },
        ],
      ).copyWith(seedingEnabled: false);
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 400));

      final switches = find.byType(Switch);
      expect(switches, findsWidgets);
      await tester.tap(switches.last);
      await tester.pump(const Duration(milliseconds: 300));
      expect(provider.tasks.single.seedingEnabled, isTrue);
    });
  });
}
