import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/database/repositories/bookmark_repository.dart';
import 'package:dmx/features/browser/models/bookmark.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late BookmarkRepository repository;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = BookmarkRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Bookmark bookmark(
    String id, {
    String title = 'Title',
    String url = 'https://example.com',
    String? folder,
  }) =>
      Bookmark(
        id: id,
        title: title,
        url: url,
        folder: folder,
        createdAt: DateTime(2025, 1, 1),
      );

  group('BookmarkRepository', () {
    test('saves and loads bookmarks newest first', () async {
      await repository.saveBookmark(bookmark('a', url: 'https://a.example'));
      await repository.saveBookmark(bookmark('b', url: 'https://b.example'));

      final loaded = await repository.loadBookmarks();
      expect(loaded.length, 2);
    });

    test('loadBookmarks filters by a search term', () async {
      await repository.saveBookmark(
        bookmark('a', title: 'Flutter docs', url: 'https://flutter.dev'),
      );
      await repository.saveBookmark(
        bookmark('b', title: 'Dart docs', url: 'https://dart.dev'),
      );

      final results = await repository.loadBookmarks(searchQuery: 'flutter');
      expect(results.length, 1);
      expect(results.single.id, 'a');

      // Blank search query returns everything.
      expect((await repository.loadBookmarks(searchQuery: '   ')).length, 2);
    });

    test('updates an existing bookmark matched by URL', () async {
      await repository.saveBookmark(bookmark('a', title: 'Old'));
      await repository.saveBookmark(
        bookmark('different-id', title: 'New', url: 'https://example.com'),
      );

      final loaded = await repository.loadBookmarks();
      expect(loaded.length, 1);
      expect(loaded.single.title, 'New');
    });

    test('reassigns a unique id on an id collision', () async {
      await repository.saveBookmark(
        bookmark('a', title: 'First', url: 'https://one.example'),
      );
      await repository.saveBookmark(
        bookmark('a', title: 'Second', url: 'https://two.example'),
      );

      final loaded = await repository.loadBookmarks();
      expect(loaded.length, 2);
      expect(loaded.any((b) => b.id == 'a'), isTrue);
      expect(loaded.any((b) => b.id != 'a'), isTrue);
    });

    test('searchBookmarks returns empty for a blank query', () async {
      await repository.saveBookmark(bookmark('a', title: 'Flutter'));
      expect(await repository.searchBookmarks('   '), isEmpty);
    });

    test('searchBookmarks honours the limit', () async {
      await repository.saveBookmark(
        bookmark('a', title: 'match one', url: 'https://a.example/match'),
      );
      await repository.saveBookmark(
        bookmark('b', title: 'match two', url: 'https://b.example/match'),
      );

      final results = await repository.searchBookmarks('match', limit: 1);
      expect(results.length, 1);
    });

    test('deleteBookmark removes a single row', () async {
      await repository.saveBookmark(bookmark('a'));
      await repository.saveBookmark(bookmark('b', url: 'https://b.example'));

      await repository.deleteBookmark('a');
      final loaded = await repository.loadBookmarks();
      expect(loaded.length, 1);
      expect(loaded.single.id, 'b');
    });

    test('clearBookmarks removes all rows', () async {
      await repository.saveBookmark(bookmark('a'));
      await repository.clearBookmarks();
      expect(await repository.loadBookmarks(), isEmpty);
    });
  });
}
