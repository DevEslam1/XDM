import 'package:drift/drift.dart' as drift;
import '../../../../features/browser/models/bookmark.dart';
import '../app_database.dart';

class BookmarkRepository {
  final AppDatabase _db;

  BookmarkRepository(this._db);

  BookmarksCompanion _bookmarkToCompanion(Bookmark bm) {
    return BookmarksCompanion.insert(
      id: bm.id,
      title: bm.title,
      url: bm.url,
      folder: drift.Value(bm.folder),
      createdAt: bm.createdAt.millisecondsSinceEpoch,
    );
  }

  Bookmark _rowToBookmark(DbBookmark row) {
    return Bookmark.fromMap({
      'id': row.id,
      'title': row.title,
      'url': row.url,
      'folder': row.folder,
      'createdAt': row.createdAt,
    });
  }

  Future<List<Bookmark>> loadBookmarks({String? searchQuery}) async {
    final query = _db.select(_db.bookmarks);
    if (searchQuery != null && searchQuery.trim().isNotEmpty) {
      final term = '%${searchQuery.trim().toLowerCase()}%';
      query.where((t) =>
          t.title.lower().like(term) |
          t.url.lower().like(term) |
          t.folder.lower().like(term));
    }
    final rows = await (query
          ..orderBy([(t) => drift.OrderingTerm.desc(t.createdAt)]))
        .get();
    return rows.map(_rowToBookmark).toList();
  }

  Future<List<Bookmark>> searchBookmarks(String query, {int limit = 3}) async {
    if (query.trim().isEmpty) return [];
    final term = '%${query.trim().toLowerCase()}%';
    final q = _db.select(_db.bookmarks)
      ..where((t) => t.title.lower().like(term) | t.url.lower().like(term))
      ..limit(limit);
    final rows = await q.get();
    return rows.map(_rowToBookmark).toList();
  }

  Future<void> saveBookmark(Bookmark bookmark) async {
    final existing = await (_db.select(_db.bookmarks)
          ..where((t) => t.url.equals(bookmark.url))
          ..limit(1))
        .getSingleOrNull();
    if (existing != null) {
      await (_db.update(_db.bookmarks)..where((t) => t.id.equals(existing.id)))
          .write(BookmarksCompanion(
        title: drift.Value(bookmark.title),
        url: drift.Value(bookmark.url),
        folder: drift.Value(bookmark.folder),
        createdAt: drift.Value(existing.createdAt),
      ));
      return;
    }
    await _db.into(_db.bookmarks).insert(
          _bookmarkToCompanion(bookmark),
          mode: drift.InsertMode.insertOrReplace,
        );
  }

  Future<void> deleteBookmark(String id) {
    return (_db.delete(_db.bookmarks)..where((t) => t.id.equals(id))).go();
  }

  Future<void> clearBookmarks() {
    return _db.delete(_db.bookmarks).go();
  }
}
