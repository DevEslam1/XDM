import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/widgets/download_card.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import '../helpers/test_helpers.dart';
import '../helpers/golden_helpers.dart';

void main() {
  group('Golden Tests', () {
    // FIX(16): all tests now use centralized platform-detection logic in expectGolden
    
    testWidgets('DownloadCard downloading state', (tester) async {
      final task = createTestTask(
        status: DownloadStatus.downloading,
        progress: 0.65,
      );

      await tester.pumpWidget(createTestApp(
        child: SizedBox(
          width: 400,
          child: DownloadCard(task: task),
        ),
      ));
      await tester.pumpAndSettle();

      await expectGolden(tester, 'download_card_downloading');
    });

    testWidgets('DownloadCard completed state', (tester) async {
      final task = createTestTask(status: DownloadStatus.completed);

      await tester.pumpWidget(createTestApp(
        child: SizedBox(
          width: 400,
          child: DownloadCard(task: task),
        ),
      ));
      await tester.pumpAndSettle();

      await expectGolden(tester, 'download_card_completed');
    });

    testWidgets('DownloadCard torrent state', (tester) async {
      final task = createTestTask(
        isTorrent: true,
        status: DownloadStatus.downloading,
        torrentFiles: [
          {'name': 'file1.mkv', 'length': 1000, 'progress': 0.5},
        ],
      );

      await tester.pumpWidget(createTestApp(
        child: SizedBox(
          width: 400,
          child: DownloadCard(task: task),
        ),
      ));
      await tester.pumpAndSettle();

      await expectGolden(tester, 'download_card_torrent');
    });

    // FIX(16): Added new golden tests for missed states
    
    testWidgets('DownloadCard paused state', (tester) async {
      final task = createTestTask(status: DownloadStatus.paused);
      await tester.pumpWidget(createTestApp(
        child: SizedBox(width: 400, child: DownloadCard(task: task)),
      ));
      await tester.pumpAndSettle();
      await expectGolden(tester, 'download_card_paused');
    });

    testWidgets('DownloadCard error state', (tester) async {
      final task = createTestTask(
        status: DownloadStatus.failed,
        errorMessage: 'Connection timeout',
      );
      await tester.pumpWidget(createTestApp(
        child: SizedBox(width: 400, child: DownloadCard(task: task)),
      ));
      await tester.pumpAndSettle();
      await expectGolden(tester, 'download_card_error');
    });
  });
}
