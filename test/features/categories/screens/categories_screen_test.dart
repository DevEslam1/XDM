import 'package:dmx/features/categories/screens/categories_screen.dart';
import 'package:dmx/features/categories/screens/category_detail_screen.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/test_helpers.dart';

void _big(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<DownloadProvider> _seeded(List<DownloadTask> tasks) async {
  final provider = createMockDownloadProvider();
  for (final task in tasks) {
    await provider.addTask(task);
  }
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CategoriesScreen', () {
    testWidgets('renders an empty analytics state with zero data',
        (tester) async {
      _big(tester);
      final provider = createMockDownloadProvider(tasks: []);

      await tester.pumpWidget(createTestApp(
        child: const CategoriesScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(CategoriesScreen), findsOneWidget);
      expect(find.text('Storage analytics'), findsOneWidget);
      expect(find.text('TOTAL'), findsOneWidget);
      expect(find.text('0.0 MB'), findsWidgets);
      expect(find.text('VIDEO'), findsOneWidget);
      expect(find.text('AUDIO'), findsOneWidget);
    });

    testWidgets('renders populated category sizes in GB', (tester) async {
      _big(tester);
      final provider = await _seeded([
        createTestTask(
          id: 'cat-video',
          fileName: 'movie.mkv',
          status: DownloadStatus.completed,
          category: 'Video',
          downloadedBytes: 2 * 1024 * 1024 * 1024,
        ),
        createTestTask(
          id: 'cat-audio',
          fileName: 'song.mp3',
          status: DownloadStatus.completed,
          category: 'Audio',
          downloadedBytes: 100 * 1024 * 1024,
        ),
        createTestTask(
          id: 'cat-failed',
          fileName: 'broken.zip',
          status: DownloadStatus.failed,
          category: 'Archive',
          downloadedBytes: 50 * 1024 * 1024,
          errorMessage: 'boom',
        ),
      ]);

      await tester.pumpWidget(createTestApp(
        child: const CategoriesScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('2.00 GB'), findsWidgets);
      expect(find.textContaining('1 ITEMS'), findsWidgets);
    });

    testWidgets('tapping a category card opens its detail screen',
        (tester) async {
      _big(tester);
      final provider = createMockDownloadProvider(tasks: []);

      await tester.pumpWidget(createTestApp(
        child: const CategoriesScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('VIDEO'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.byType(CategoryDetailScreen), findsOneWidget);
    });
  });
}
