import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/downloads/widgets/download_card.dart';
import 'package:dmx/features/history/screens/history_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../helpers/test_helpers.dart';

void _size(WidgetTester tester, {double width = 700, double height = 2400}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void _drain(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

Future<DownloadProvider> _seedHistory() async {
  final provider = createMockDownloadProvider();
  await provider.addTask(createTestTask(
    id: 'hist-1',
    fileName: 'ubuntu.iso',
    status: DownloadStatus.completed,
    progress: 1.0,
  ));
  await provider.addTask(createTestTask(
    id: 'hist-2',
    fileName: 'broken.zip',
    status: DownloadStatus.failed,
    errorMessage: 'Timeout',
  ));
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HistoryScreen', () {
    testWidgets('renders the empty state when there are no records',
        (tester) async {
      _size(tester);
      await tester.pumpWidget(createTestApp(
        child: const HistoryScreen(),
        downloadProvider: createMockDownloadProvider(tasks: []),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(HistoryScreen), findsOneWidget);
      expect(find.text('XDM'), findsOneWidget);
      expect(find.text('NO COMPLETED SIGNALS FOUND'), findsOneWidget);
      expect(find.text('0 RECORDS'), findsOneWidget);
    });

    testWidgets('renders completed and failed records in a list',
        (tester) async {
      _size(tester);
      final provider = await _seedHistory();

      await tester.pumpWidget(createTestApp(
        child: const HistoryScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(DownloadCard), findsNWidgets(2));
      expect(find.text('2 RECORDS'), findsOneWidget);
      expect(find.byIcon(Icons.delete_sweep_outlined), findsOneWidget);
    });

    testWidgets('uses a grid layout on wide viewports', (tester) async {
      _size(tester, width: 1100, height: 2200);
      final provider = await _seedHistory();

      await tester.pumpWidget(createTestApp(
        child: const HistoryScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(GridView), findsOneWidget);
      _drain(tester);
    });

    testWidgets('filters records with the search field', (tester) async {
      _size(tester);
      final provider = await _seedHistory();

      await tester.pumpWidget(createTestApp(
        child: const HistoryScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      final search = find.byType(TextField);
      await tester.enterText(search, 'ubuntu');
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(DownloadCard), findsOneWidget);

      await tester.enterText(search, 'zzz-nothing');
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('NO MATCHING RECORDS'), findsOneWidget);

      await tester.tap(find.text('Clear Search'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(DownloadCard), findsNWidgets(2));
      _drain(tester);
    });

    testWidgets('clear-history dialog can be cancelled', (tester) async {
      _size(tester);
      final provider = await _seedHistory();

      await tester.pumpWidget(createTestApp(
        child: const HistoryScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Clear Download History (2 items)'), findsOneWidget);
      expect(find.text('Clear All'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Clear Download History (2 items)'), findsNothing);
      expect(provider.tasks.length, 2);
    });

    testWidgets('clearing all history removes the records', (tester) async {
      _size(tester);
      final provider = await _seedHistory();

      await tester.pumpWidget(createTestApp(
        child: const HistoryScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('Clear All'));
      await tester.pump(const Duration(milliseconds: 500));

      expect(provider.tasks, isEmpty);
      expect(find.text('NO COMPLETED SIGNALS FOUND'), findsOneWidget);
      _drain(tester);
    });
  });
}
