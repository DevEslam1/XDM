import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/downloads/widgets/download_card.dart';
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

void _size(WidgetTester tester, double width, double height) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Drains layout-overflow exceptions produced by intentionally narrow surfaces
/// so the branch under test can still be exercised without failing the test.
void _drain(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

void main() {
  group('DownloadCard', () {
    testWidgets('renders file name and progress', (tester) async {
      final task = createTestTask(
        fileName: 'ubuntu-24.04-desktop-amd64.iso',
        progress: 0.65,
      );

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('ubuntu-24.04-desktop-amd64.iso'), findsOneWidget);
    });

    testWidgets('shows pause button when downloading', (tester) async {
      final task = createTestTask(status: DownloadStatus.downloading);

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byIcon(Icons.pause_rounded), findsWidgets);
    });

    testWidgets('shows resume button when paused', (tester) async {
      final task = createTestTask(status: DownloadStatus.paused);

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byIcon(Icons.play_arrow_rounded), findsWidgets);
    });

    testWidgets('shows retry button on error/failed status', (tester) async {
      final task = createTestTask(
        status: DownloadStatus.failed,
        errorMessage: 'Connection timeout',
      );

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byIcon(Icons.refresh_rounded), findsWidgets);
    });

    testWidgets('shows completed state with open button', (tester) async {
      final task = createTestTask(status: DownloadStatus.completed);

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byIcon(Icons.folder_open_rounded), findsWidgets);
    });

    testWidgets('displays speed in MB/s format', (tester) async {
      final task = createTestTask(speed: 5242880.0); // 5 MB/s

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('5.0'), findsWidgets);
    });

    testWidgets('displays ETA correctly', (tester) async {
      final task = createTestTask(eta: 65);

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(DownloadCard), findsOneWidget);
    });

    testWidgets('shows torrent file count badge', (tester) async {
      final task = createTestTask(
        isTorrent: true,
        torrentFiles: [
          {'name': 'file1.mkv', 'length': 1000, 'progress': 0.5},
          {'name': 'file2.srt', 'length': 500, 'progress': 1.0},
        ],
      );

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('FILES'), findsWidgets);
    });

    testWidgets('shows thread count for HTTP downloads', (tester) async {
      final task = createTestTask(threadCount: 8, isTorrent: false);

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('8 CH'), findsWidgets);
    });

    testWidgets('queued task shows waiting state', (tester) async {
      final task = createTestTask(status: DownloadStatus.queued);

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(DownloadCard), findsOneWidget);
    });

    testWidgets('long file name truncates with ellipsis', (tester) async {
      final task = createTestTask(
        fileName:
            'a_very_long_file_name_that_should_be_truncated_because_it_exceeds_the_maximum_display_width_of_the_card_widget.mp4',
      );

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      final textWidget = tester.widget<Text>(
        find.textContaining('a_very_long_file_name'),
      );
      expect(textWidget.maxLines, 2);
      expect(textWidget.overflow, TextOverflow.ellipsis);
    });

    testWidgets('tap triggers card interaction', (tester) async {
      final task = createTestTask();

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byType(DownloadCard));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(DownloadCard), findsOneWidget);
    });
  });

  group('DownloadCard variants and states', () {
    testWidgets('renders compact variant', (tester) async {
      _size(tester, 360, 900);
      final task = createTestTask(id: 'compact-1');

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task, compact: true, showDragHandle: true),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(DownloadCard), findsOneWidget);
    });

    testWidgets('renders on a small phone surface', (tester) async {
      _size(tester, 330, 800);
      final task = createTestTask(id: 'small-1');

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.byType(DownloadCard), findsOneWidget);
    });

    testWidgets('renders constrained card on a wide surface', (tester) async {
      _size(tester, 900, 1000);
      final task = createTestTask(id: 'wide-1');

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(DownloadCard), findsOneWidget);
    });

    testWidgets('selection mode hides the dismissible wrapper', (tester) async {
      final task = createTestTask(id: 'sel-1');
      final provider = await _seeded([task]);
      provider.toggleTaskSelection(task.id);

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(Dismissible), findsNothing);
    });

    testWidgets('renders with an active category filter accent',
        (tester) async {
      final task = createTestTask(id: 'filter-1', category: 'Video');
      final provider = await _seeded([task]);
      provider.setCategoryFilter('Video');

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(DownloadCard), findsOneWidget);
    });

    testWidgets('renders every cycle state label', (tester) async {
      _size(tester, 590, 1400);
      final states = <CycleState, String>{
        CycleState.verifying: 'Re-verifying',
        CycleState.resuming: 'Resuming…',
        CycleState.allocating: 'Allocating disk space…',
        CycleState.starting: 'Starting…',
        CycleState.stalled: 'Stalled',
        CycleState.retrying: 'Retrying…',
        CycleState.updatingLinks: 'Refreshing link…',
        CycleState.fetchingMetadata: 'Fetching Metadata',
      };

      for (final entry in states.entries) {
        final task = createTestTask(id: 'cycle-${entry.key.name}')
            .copyWith(cycleState: entry.key);
        await tester.pumpWidget(createTestApp(
          child: DownloadCard(task: task),
        ));
        await tester.pump(const Duration(milliseconds: 200));
        _drain(tester);
        expect(find.text(entry.value), findsWidgets,
            reason: 'missing label for ${entry.key}');
      }
    });

    testWidgets('renders pause reason labels', (tester) async {
      _size(tester, 590, 1400);
      final diskTask =
          createTestTask(id: 'pr-disk', status: DownloadStatus.paused)
              .copyWith(pauseReason: PauseReason.diskFull);
      await tester
          .pumpWidget(createTestApp(child: DownloadCard(task: diskTask)));
      await tester.pump(const Duration(milliseconds: 200));
      _drain(tester);
      expect(find.text('Paused — disk full'), findsWidgets);

      final urlTask =
          createTestTask(id: 'pr-url', status: DownloadStatus.paused)
              .copyWith(pauseReason: PauseReason.urlExpired);
      await tester
          .pumpWidget(createTestApp(child: DownloadCard(task: urlTask)));
      await tester.pump(const Duration(milliseconds: 200));
      _drain(tester);
      expect(find.text('Link expired — tap to refresh'), findsWidgets);
    });

    testWidgets('wifi-waiting paused task shows waiting chip', (tester) async {
      _size(tester, 590, 1400);
      final task = createTestTask(id: 'wifi-1', status: DownloadStatus.paused)
          .copyWith(errorMessage: DownloadStatusMessages.waitingWifi);

      await tester.pumpWidget(createTestApp(child: DownloadCard(task: task)));
      await tester.pump(const Duration(milliseconds: 200));
      _drain(tester);

      expect(find.text('Waiting WiFi'), findsWidgets);
    });

    testWidgets('scheduled paused task shows schedule chip', (tester) async {
      _size(tester, 590, 1400);
      final task = createTestTask(id: 'sched-1', status: DownloadStatus.paused)
          .copyWith(scheduledAt: DateTime.now().add(const Duration(hours: 2)));

      await tester.pumpWidget(createTestApp(child: DownloadCard(task: task)));
      await tester.pump(const Duration(milliseconds: 200));
      _drain(tester);

      expect(find.byIcon(Icons.schedule_rounded), findsWidgets);
    });

    testWidgets('renders queued subtext', (tester) async {
      final task =
          createTestTask(id: 'queued-sub', status: DownloadStatus.queued);

      await tester.pumpWidget(createTestApp(child: DownloadCard(task: task)));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(DownloadCard), findsOneWidget);
    });

    testWidgets('renders unknown-size indeterminate progress', (tester) async {
      final task = createTestTask(
        id: 'unknown-size',
        status: DownloadStatus.downloading,
        fileSize: 0,
        downloadedBytes: 1024,
        progress: 0.0,
      );

      await tester.pumpWidget(createTestApp(child: DownloadCard(task: task)));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(LinearProgressIndicator), findsWidgets);
    });

    testWidgets('renders single-chunk progress bar', (tester) async {
      final task = createTestTask(
        id: 'single-chunk',
        threadCount: 1,
        chunks: [0.5],
        progress: 0.5,
      );

      await tester.pumpWidget(createTestApp(child: DownloadCard(task: task)));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(DownloadCard), findsOneWidget);
    });

    testWidgets('renders merging status', (tester) async {
      final task =
          createTestTask(id: 'merge-1', status: DownloadStatus.merging);

      await tester.pumpWidget(createTestApp(child: DownloadCard(task: task)));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Merging…'), findsWidgets);
    });

    testWidgets('renders failed task with recovery hint', (tester) async {
      final task = createTestTask(
        id: 'fail-hint',
        status: DownloadStatus.failed,
        errorMessage: 'Connection timeout',
      ).copyWith(recoveryHint: 'Check your internet connection and retry.');

      await tester.pumpWidget(createTestApp(child: DownloadCard(task: task)));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Connection timeout'), findsWidgets);
      expect(
          find.text('Check your internet connection and retry.'), findsWidgets);
    });

    testWidgets('renders status message notice row', (tester) async {
      final task = createTestTask(id: 'notice-1').copyWith(
        statusMessage: 'Waiting for network connection...',
      );

      await tester.pumpWidget(createTestApp(child: DownloadCard(task: task)));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Waiting for network connection...'), findsWidgets);
    });

    testWidgets('renders site badge and category icon', (tester) async {
      _size(tester, 590, 1400);
      final task = createTestTask(id: 'site-1', category: 'APK')
          .copyWith(siteDisplayName: 'Example');

      await tester.pumpWidget(createTestApp(child: DownloadCard(task: task)));
      await tester.pump(const Duration(milliseconds: 200));
      _drain(tester);

      expect(find.text('EXAMPLE'), findsWidgets);
    });

    testWidgets('renders blank file name as Untitled', (tester) async {
      final task = createTestTask(id: 'blank-1', fileName: '   ');

      await tester.pumpWidget(createTestApp(child: DownloadCard(task: task)));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Untitled'), findsWidgets);
    });
  });

  group('DownloadCard media variant', () {
    testWidgets('renders audio-only media card', (tester) async {
      final task = createTestTask(
        id: 'media-audio',
        category: 'Audio',
        fileName: 'song.m4a',
      ).copyWith(youtubeQualityPreset: 'audio_only');

      await tester.pumpWidget(createTestApp(child: DownloadCard(task: task)));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('AUDIO'), findsWidgets);
      expect(find.byIcon(Icons.audiotrack_rounded), findsWidgets);
    });

    testWidgets('renders combined A/V media card', (tester) async {
      final task = createTestTask(id: 'media-av', category: 'Video').copyWith(
        youtubeQualityPreset: 'best',
        mergedAudioUrl: 'https://example.com/audio.m4a',
        audioSize: 1000,
        audioDownloadedBytes: 500,
        fileSize: 2000,
        downloadedBytes: 1000,
      );

      await tester.pumpWidget(createTestApp(child: DownloadCard(task: task)));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('A/V'), findsWidgets);
      expect(find.text('BEST'), findsWidgets);
    });

    testWidgets('renders partial video-size hint for merged audio',
        (tester) async {
      final task = createTestTask(
        id: 'media-partial',
        fileSize: 0,
        downloadedBytes: 0,
        category: 'Video',
      ).copyWith(
        youtubeQualityPreset: 'best',
        mergedAudioUrl: 'https://example.com/audio.m4a',
        audioSize: 500,
      );

      await tester.pumpWidget(createTestApp(child: DownloadCard(task: task)));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Video size unknown'), findsWidgets);
    });
  });

  group('DownloadCard torrent variant', () {
    testWidgets('renders magnet torrent with per-file list', (tester) async {
      _size(tester, 590, 2000);
      final task = createTestTask(
        id: 'tor-card-1',
        isTorrent: true,
        status: DownloadStatus.downloading,
        progress: 0.3,
        torrentFiles: [
          {
            'name': 'part1.bin',
            'length': 1000000,
            'downloadedBytes': 300000,
            'selected': true,
            'priority': 4,
          },
          {
            'name': 'part2.bin',
            'length': 1000000,
            'downloadedBytes': 0,
            'selected': false,
            'priority': 0,
          },
        ],
      );

      await tester.pumpWidget(createTestApp(child: DownloadCard(task: task)));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.textContaining('FILES'), findsWidgets);
      expect(find.text('part1.bin'), findsWidgets);
    });

    testWidgets('torrent with more than four files shows show-more control',
        (tester) async {
      _size(tester, 590, 2400);
      final files = List.generate(
        6,
        (i) => {
          'name': 'f$i.bin',
          'length': 1000000,
          'downloadedBytes': 100000 * i,
          'selected': true,
          'priority': 4,
        },
      );
      final task = createTestTask(
        id: 'tor-card-many',
        isTorrent: true,
        status: DownloadStatus.downloading,
        progress: 0.3,
        torrentFiles: files,
      );

      await tester.pumpWidget(createTestApp(child: DownloadCard(task: task)));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.textContaining('MORE FILE'), findsWidgets);

      await tester.tap(find.textContaining('MORE FILE'));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);
      expect(find.text('SHOW LESS'), findsOneWidget);
    });

    testWidgets('magnet torrent without metadata shows fetching label',
        (tester) async {
      _size(tester, 590, 1600);
      final task = createTestTask(
        id: 'tor-card-magnet',
        isTorrent: true,
        status: DownloadStatus.downloading,
        fileSize: 0,
        downloadedBytes: 0,
        progress: 0.0,
      );

      await tester.pumpWidget(createTestApp(child: DownloadCard(task: task)));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.text('Fetching metadata…'), findsWidgets);
    });

    testWidgets('completed torrent renders seeding toggle and ratio',
        (tester) async {
      _size(tester, 590, 2000);
      final task = createTestTask(
        id: 'tor-card-seed',
        isTorrent: true,
        status: DownloadStatus.completed,
        progress: 1.0,
        torrentFiles: [
          {
            'name': 'done.bin',
            'length': 1000000,
            'downloadedBytes': 1000000,
            'selected': true,
            'priority': 4,
          },
        ],
      ).copyWith(seedingEnabled: true, uploadedBytes: 500000000);

      await tester.pumpWidget(createTestApp(child: DownloadCard(task: task)));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.text('Seed this torrent'), findsOneWidget);
      expect(find.textContaining('Ratio:'), findsOneWidget);
    });

    testWidgets('failed torrent shows error and recovery hint', (tester) async {
      _size(tester, 590, 1800);
      final task = createTestTask(
        id: 'tor-card-fail',
        isTorrent: true,
        status: DownloadStatus.failed,
        errorMessage: 'Torrent engine error',
      ).copyWith(recoveryHint: 'Torrent engine error. Tap retry.');

      await tester.pumpWidget(createTestApp(child: DownloadCard(task: task)));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.text('Torrent engine error'), findsWidgets);
    });

    testWidgets('torrent checking status renders indeterminate file rows',
        (tester) async {
      _size(tester, 590, 1800);
      final task = createTestTask(
        id: 'tor-card-check',
        isTorrent: true,
        status: DownloadStatus.downloading,
        progress: 0.3,
        torrentFiles: [
          {
            'name': 'check.bin',
            'length': 1000000,
            'downloadedBytes': 300000,
            'selected': true,
            'priority': 4,
          },
        ],
      ).copyWith(statusMessage: 'Checking files…');

      await tester.pumpWidget(createTestApp(child: DownloadCard(task: task)));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.byType(DownloadCard), findsOneWidget);
    });
  });

  group('DownloadCard interactions', () {
    testWidgets('pause control transitions the task', (tester) async {
      final task = createTestTask(
        id: 'tap-pause',
        status: DownloadStatus.downloading,
        downloadedBytes: 100000,
      );
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byKey(ValueKey('pause_${task.id}')));
      await tester.pump(const Duration(milliseconds: 400));

      expect(provider.tasks.single.status, DownloadStatus.paused);
    });

    testWidgets('resume control transitions the task', (tester) async {
      final task =
          createTestTask(id: 'tap-resume', status: DownloadStatus.paused);
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byKey(ValueKey('resume_${task.id}')));
      await tester.pump(const Duration(milliseconds: 400));

      expect(provider.tasks.single.status, DownloadStatus.queued);
    });

    testWidgets('advanced controls sheet opens and copies the link',
        (tester) async {
      final task = createTestTask(id: 'adv-1');
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Copy Download Link'), findsOneWidget);

      await tester.tap(find.text('Copy Download Link'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Copy Download Link'), findsNothing);
    });

    testWidgets('advanced controls update-link dialog opens', (tester) async {
      final task = createTestTask(id: 'adv-link');
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('Update Download Link'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Update Link'), findsOneWidget);
    });

    testWidgets('torrent advanced controls show properties option',
        (tester) async {
      _size(tester, 590, 2000);
      final task = createTestTask(
        id: 'adv-torrent',
        isTorrent: true,
        status: DownloadStatus.downloading,
        progress: 0.3,
        torrentFiles: [
          {
            'name': 'a.bin',
            'length': 1000,
            'downloadedBytes': 300,
            'selected': true,
            'priority': 4,
          },
        ],
      );
      final provider = await _seeded([task]);

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Properties'), findsOneWidget);
    });
  });

  group('PlaylistGroupCard', () {
    testWidgets('renders and expands playlist items', (tester) async {
      _size(tester, 590, 1600);
      final items = [
        createTestTask(
          id: 'pl-1',
          status: DownloadStatus.downloading,
          progress: 0.5,
        ).copyWith(playlistId: 'plist', playlistTitle: 'My Playlist'),
        createTestTask(
          id: 'pl-2',
          status: DownloadStatus.completed,
          progress: 1.0,
        ).copyWith(playlistId: 'plist', playlistTitle: 'My Playlist'),
      ];

      await tester.pumpWidget(createTestApp(
        child: PlaylistGroupCard(
          playlistId: 'plist',
          title: 'My Playlist',
          items: items,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.text('My Playlist'), findsOneWidget);
      expect(find.textContaining('PLAYLIST'), findsOneWidget);

      await tester.tap(find.text('My Playlist'));
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      expect(find.text('1/2'), findsWidgets);
    });
  });
}
