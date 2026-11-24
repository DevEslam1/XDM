import 'package:dmx/features/browser/models/bookmark.dart';
import 'package:dmx/features/browser/widgets/bookmark_manager_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/fake_services.dart';
import '../helpers/test_helpers.dart';

class _SearchableBookmarkDb extends FakeDatabaseService {
  @override
  Future<List<Bookmark>> loadBookmarks({String? searchQuery}) async {
    final all = await super.loadBookmarks();
    final q = searchQuery?.trim().toLowerCase() ?? '';
    if (q.isEmpty) return all;
    return all
        .where((b) =>
            b.title.toLowerCase().contains(q) ||
            b.url.toLowerCase().contains(q) ||
            (b.folder?.toLowerCase().contains(q) ?? false))
        .toList();
  }
}

Bookmark _bm({
  required String id,
  required String title,
  required String url,
  String? folder,
}) {
  return Bookmark(
    id: id,
    title: title,
    url: url,
    folder: folder,
    createdAt: DateTime.now(),
  );
}

void main() {
  setUp(() {
    setupTestPluginMocks();
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    _SearchableBookmarkDb? database,
  }) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = database ?? _SearchableBookmarkDb();
    await tester.pumpWidget(createTestApp(
      child: const BookmarkManagerScreen(),
      databaseService: db,
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('shows empty state', (tester) async {
    await pumpScreen(tester);

    expect(find.byType(BookmarkManagerScreen), findsOneWidget);
    expect(find.text('No bookmarks yet'), findsOneWidget);
    expect(find.text('Add Bookmark'), findsOneWidget);
  });

  testWidgets('renders bookmarks and folders', (tester) async {
    final db = _SearchableBookmarkDb();
    await db.saveBookmark(_bm(
      id: '1',
      title: 'Example',
      url: 'https://example.com',
      folder: 'Work',
    ));
    await db.saveBookmark(
      _bm(id: '2', title: 'Flutter', url: 'https://flutter.dev'),
    );

    await pumpScreen(tester, database: db);

    expect(find.text('Example'), findsOneWidget);
    expect(find.text('Flutter'), findsOneWidget);
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Unsorted'), findsOneWidget);
  });

  testWidgets('collapsing a folder hides its bookmarks', (tester) async {
    final db = _SearchableBookmarkDb();
    await db.saveBookmark(_bm(
      id: '1',
      title: 'Example',
      url: 'https://example.com',
      folder: 'Work',
    ));

    await pumpScreen(tester, database: db);
    expect(find.text('Example'), findsOneWidget);

    await tester.tap(find.text('Work'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Example'), findsNothing);
  });

  testWidgets('search filters bookmarks and can be cleared', (tester) async {
    final db = _SearchableBookmarkDb();
    await db.saveBookmark(
      _bm(id: '1', title: 'Example', url: 'https://example.com'),
    );
    await db.saveBookmark(
      _bm(id: '2', title: 'Flutter', url: 'https://flutter.dev'),
    );

    await pumpScreen(tester, database: db);

    await tester.enterText(find.byType(TextField).first, 'flutter');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Flutter'), findsOneWidget);
    expect(find.text('Example'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'no-match-xyz');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('No bookmarks match your search'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('adds a bookmark via the dialog', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Add Bookmark'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Add bookmark'), findsOneWidget);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'New Site');
    await tester.enterText(fields.at(1), 'https://new.example.com');
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('SAVE'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('New Site'), findsOneWidget);
  });

  testWidgets('deleting a bookmark shows undo snackbar', (tester) async {
    final db = _SearchableBookmarkDb();
    await db.saveBookmark(
      _bm(id: '1', title: 'Gone', url: 'https://gone.example.com'),
    );

    await pumpScreen(tester, database: db);
    expect(find.text('Gone'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Bookmark deleted'), findsOneWidget);
    expect(find.text('UNDO'), findsOneWidget);

    await tester.tap(find.text('UNDO'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Gone'), findsOneWidget);
  });

  testWidgets('editing a bookmark updates it', (tester) async {
    final db = _SearchableBookmarkDb();
    await db.saveBookmark(
      _bm(id: '1', title: 'Old Title', url: 'https://example.com'),
    );

    await pumpScreen(tester, database: db);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Edit bookmark'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'New Title');
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('SAVE'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('New Title'), findsOneWidget);
  });

  testWidgets('copy url action is tappable', (tester) async {
    final db = _SearchableBookmarkDb();
    await db.saveBookmark(
      _bm(id: '1', title: 'Copy Me', url: 'https://copy.example.com'),
    );

    await pumpScreen(tester, database: db);

    await tester.tap(find.byIcon(Icons.copy));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Copy Me'), findsOneWidget);
  });
}
