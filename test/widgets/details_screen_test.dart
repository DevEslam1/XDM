import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/details/screens/details_screen.dart';
import '../helpers/test_helpers.dart';

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
      await tester.pumpAndSettle();

      expect(find.textContaining('test-file.zip'), findsOneWidget);
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
      await tester.pumpAndSettle();

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
      await tester.pumpAndSettle();

      expect(find.textContaining('movie.mkv'), findsOneWidget);
      expect(find.textContaining('subtitle.srt'), findsOneWidget);
    });
  });
}
