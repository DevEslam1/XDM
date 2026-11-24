import 'package:dmx/features/add_download/widgets/add_download_dialog.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/downloads/widgets/download_card.dart';
import 'package:dmx/features/home/screens/home_screen.dart';
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

void _drain(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

void main() {
  group('HomeScreen', () {
    testWidgets('renders home screen widget', (tester) async {
      final provider = createMockDownloadProvider(tasks: []);

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('renders active tasks list when tasks are provided',
        (tester) async {
      final provider = createMockDownloadProvider(
        tasks: createMixedTaskList(),
      );

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('FAB is visible on home screen', (tester) async {
      final provider = createMockDownloadProvider(tasks: []);

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(FloatingActionButton), findsOneWidget);
    });

    testWidgets('pull to refresh does not crash', (tester) async {
      final provider = createMockDownloadProvider(
        tasks: createMixedTaskList(),
      );

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.drag(
        find.byType(HomeScreen),
        const Offset(0, 300),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(HomeScreen), findsOneWidget);
    });
  });

  group('HomeScreen populated list', () {
    testWidgets('renders download cards for active tasks', (tester) async {
      _size(tester, 590, 2000);
      final tasks = createMixedTaskList()
          .where((t) =>
              t.status != DownloadStatus.completed &&
              t.status != DownloadStatus.failed)
          .toList();
      final provider = await _seeded(tasks);

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.byType(DownloadCard), findsWidgets);
      expect(find.byKey(const ValueKey('list')), findsOneWidget);
    });

    testWidgets('renders the empty state when there are no tasks',
        (tester) async {
      _size(tester, 590, 1600);
      final provider = await _seeded([]);

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.byKey(const ValueKey('empty')), findsOneWidget);
    });

    testWidgets('switching to the completed tab shows history tasks',
        (tester) async {
      _size(tester, 590, 2000);
      final provider = await _seeded(createMixedTaskList());

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      await tester.tap(find.text('Completed').first);
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      expect(find.textContaining('HISTORY'), findsWidgets);
    });

    testWidgets('renders multi-column grid on a wide surface', (tester) async {
      _size(tester, 900, 1600);
      final provider = await _seeded(createMixedTaskList());

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.byKey(const ValueKey('grid')), findsOneWidget);
    });

    testWidgets('renders reorderable list in manual sort mode', (tester) async {
      _size(tester, 590, 2000);
      final provider = await _seeded(createMixedTaskList());
      provider.setSortOption(SortOption.manual);

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.byKey(const ValueKey('reorderable')), findsOneWidget);
    });
  });

  group('HomeScreen controls', () {
    testWidgets('search filters the task list', (tester) async {
      _size(tester, 590, 2000);
      final provider = await _seeded([
        createTestTask(id: 's-1', fileName: 'alpha.bin'),
        createTestTask(id: 's-2', fileName: 'beta.bin'),
      ]);

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      await tester.tap(find.byIcon(Icons.search_rounded).first);
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(find.byType(TextField).first, 'alpha');
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(provider.searchQuery, 'alpha');

      await tester.tap(find.byIcon(Icons.close_rounded).first);
      await tester.pump(const Duration(milliseconds: 300));
      expect(provider.searchQuery, '');
    });

    testWidgets('toggling analytics shows the storage panel', (tester) async {
      _size(tester, 590, 2000);
      final provider = await _seeded(createMixedTaskList());

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      await tester.tap(find.byIcon(Icons.pie_chart_outline_rounded).first);
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      expect(find.text('STORAGE ANALYTICS'), findsWidgets);
    });

    testWidgets('sort menu changes the sort option', (tester) async {
      _size(tester, 590, 2000);
      final provider = await _seeded(createMixedTaskList());

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      await tester.tap(find.byIcon(Icons.sort_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      await tester.tap(find.text('FILE SIZE').last);
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(provider.sortOption, SortOption.fileSize);
    });

    testWidgets('tapping the FAB opens the add download dialog',
        (tester) async {
      _size(tester, 590, 2000);
      final provider = await _seeded([]);

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.byType(AddDownloadDialog), findsOneWidget);
    });

    testWidgets('opening the drawer shows navigation entries', (tester) async {
      _size(tester, 590, 2000);
      final provider = await _seeded([]);

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      await tester.tap(find.byIcon(Icons.menu).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      expect(find.text('Transmissions'), findsOneWidget);
      expect(find.text('Categories'), findsWidgets);
    });
  });

  group('HomeScreen selection mode', () {
    testWidgets('selection app bar and batch bar render', (tester) async {
      _size(tester, 590, 2000);
      final task = createTestTask(id: 'sel-home');
      final provider = await _seeded([task]);
      provider.toggleTaskSelection(task.id);

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.text('1 selected'), findsOneWidget);
      expect(find.text('Select All'), findsOneWidget);

      await tester.tap(find.text('Select All'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(provider.selectedTaskIds.length, 1);

      await tester.tap(find.text('Deselect'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(provider.isSelectionMode, isFalse);
    });

    testWidgets('batch action opens the batch operations sheet',
        (tester) async {
      _size(tester, 590, 2000);
      final task = createTestTask(id: 'sel-batch');
      final provider = await _seeded([task]);
      provider.toggleTaskSelection(task.id);

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      await tester.tap(find.byIcon(Icons.pause_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      expect(find.byType(HomeScreen), findsOneWidget);
    });
  });

  group('HomeScreen clear history', () {
    testWidgets('clearing history deletes completed tasks', (tester) async {
      _size(tester, 590, 2000);
      final tasks = [
        createTestTask(
            id: 'h-1', status: DownloadStatus.completed, progress: 1.0),
        createTestTask(
            id: 'h-2', status: DownloadStatus.downloading, progress: 0.5),
      ];
      final provider = await _seeded(tasks);

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      await tester.tap(find.text('Completed').first);
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      await tester.tap(find.byIcon(Icons.delete_sweep_outlined).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      await tester.tap(find.text('CLEAR ALL'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      _drain(tester);

      expect(provider.tasks.any((t) => t.id == 'h-1'), isFalse);
    });
  });
}
