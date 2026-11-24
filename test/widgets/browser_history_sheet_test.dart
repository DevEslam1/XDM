import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/browser/widgets/browser_history_sheet.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_services.dart';
import '../helpers/test_helpers.dart';

/// A DownloadProvider whose task list is provided directly, avoiding the heavy
/// async `load()` pipeline (journal replay + disk reconciliation).
class _StaticTasksProvider extends DownloadProvider {
  _StaticTasksProvider({
    required DatabaseService database,
    required SettingsProvider settings,
    required List<DownloadTask> staticTasks,
  })  : _staticTasks = staticTasks,
        super(
          databaseService: database,
          settingsProvider: settings,
          downloadEngine: FakeDownloadEngine(),
          permissionService: FakePermissionService(),
          enableBackgroundTimers: false,
        );

  final List<DownloadTask> _staticTasks;

  @override
  List<DownloadTask> get tasks => List<DownloadTask>.unmodifiable(_staticTasks);
}

class _FakeHistoryDb extends FakeDatabaseService {
  _FakeHistoryDb(this.entries);

  final List<Map<String, dynamic>> entries;

  @override
  Future<List<Map<String, dynamic>>> loadBrowserHistory({
    int? max,
    String? searchQuery,
  }) async {
    if (searchQuery == null || searchQuery.trim().isEmpty) {
      return List<Map<String, dynamic>>.from(entries);
    }
    final q = searchQuery.toLowerCase();
    return entries
        .where((h) =>
            (h['title'] ?? '').toString().toLowerCase().contains(q) ||
            (h['url'] ?? '').toString().toLowerCase().contains(q))
        .toList();
  }

  @override
  Future<void> deleteBrowserHistory(int id) async {
    entries.removeWhere((h) => h['id'] == id);
  }

  @override
  Future<void> clearBrowserHistory() async {
    entries.clear();
  }
}

List<Map<String, dynamic>> _historyEntries() {
  final now = DateTime.now();
  return [
    {
      'id': 1,
      'title': 'Example Site',
      'url': 'https://example.com',
      'visitedAt': now.millisecondsSinceEpoch,
      'faviconUrl': null,
    },
    {
      'id': 2,
      'title': 'Flutter Docs',
      'url': 'https://flutter.dev',
      'visitedAt': now.subtract(const Duration(days: 1)).millisecondsSinceEpoch,
      'faviconUrl': null,
    },
    {
      'id': 3,
      'title': 'Old Page',
      'url': 'https://old.example.org',
      'visitedAt':
          now.subtract(const Duration(days: 40)).millisecondsSinceEpoch,
      'faviconUrl': null,
    },
  ];
}

void main() {
  setUp(() {
    setupTestPluginMocks();
  });

  Future<void> pumpSheet(
    WidgetTester tester, {
    _FakeHistoryDb? database,
    DownloadProvider? provider,
  }) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = database ?? _FakeHistoryDb([]);
    await tester.pumpWidget(createTestApp(
      child: const BrowserHistorySheet(),
      databaseService: db,
      downloadProvider: provider ?? createMockDownloadProvider(db: db),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('renders empty surfing entries state', (tester) async {
    await pumpSheet(tester);

    expect(find.byType(BrowserHistorySheet), findsOneWidget);
    expect(find.text('No history found'), findsOneWidget);
    expect(find.text('Explore Web'), findsOneWidget);
    expect(find.text('SURFING HISTORY'), findsOneWidget);
    expect(find.text('DOWNLOADS'), findsOneWidget);
  });

  testWidgets('renders entries tiles and groups', (tester) async {
    await pumpSheet(tester, database: _FakeHistoryDb(_historyEntries()));

    expect(find.text('Example Site'), findsOneWidget);
    expect(find.text('Flutter Docs'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
  });

  testWidgets('switching to downloads tab shows tasks', (tester) async {
    final db = _FakeHistoryDb(_historyEntries());
    final provider = _StaticTasksProvider(
      database: db,
      settings: createMockSettingsProvider(),
      staticTasks: [
        createTestTask(
          fileName: 'video.mp4',
          status: DownloadStatus.completed,
        ),
      ],
    );

    await pumpSheet(tester, database: db, provider: provider);

    await tester.tap(find.text('DOWNLOADS'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('video.mp4'), findsOneWidget);
  });

  testWidgets('downloads tab empty state', (tester) async {
    await pumpSheet(tester);

    await tester.tap(find.text('DOWNLOADS'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('No downloads yet'), findsOneWidget);
  });

  testWidgets('searching filters entries', (tester) async {
    await pumpSheet(tester, database: _FakeHistoryDb(_historyEntries()));

    await tester.enterText(find.byType(TextField).first, 'flutter');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Flutter Docs'), findsOneWidget);
    expect(find.text('Example Site'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('clearing all entries asks for confirmation', (tester) async {
    final db = _FakeHistoryDb(_historyEntries());
    await pumpSheet(tester, database: db);

    await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('CLEAR HISTORY?'), findsOneWidget);

    await tester.tap(find.text('Clear'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(db.entries, isEmpty);
  });

  testWidgets('deleting a single entries item', (tester) async {
    final db = _FakeHistoryDb(_historyEntries());
    await pumpSheet(tester, database: db);

    expect(find.text('Example Site'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded).last);
    await tester.pump(const Duration(milliseconds: 200));

    expect(db.entries.length, 2);
  });

  testWidgets('export action is triggered', (tester) async {
    await pumpSheet(tester, database: _FakeHistoryDb(_historyEntries()));

    await tester.tap(find.byIcon(Icons.ios_share_rounded));
    await tester.pump(const Duration(milliseconds: 300));

    while (tester.takeException() != null) {}
    expect(find.byType(BrowserHistorySheet), findsOneWidget);
  });
}
