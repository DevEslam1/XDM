import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/widgets/download_card.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import '../helpers/test_helpers.dart';

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
}
