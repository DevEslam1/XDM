import 'package:drift/drift.dart' as drift;
import '../app_database.dart';

class BrowserTabRepository {
  final AppDatabase _db;

  BrowserTabRepository(this._db);

  Future<void> saveOpenTabs(List<SavedBrowserTab> tabs) async {
    await _db.transaction(() async {
      await _db.delete(_db.browserTabs).go();
      if (tabs.isEmpty) return;
      await _db.batch((batch) {
        batch.insertAll(_db.browserTabs, tabs);
      });
    });
  }

  Future<List<SavedBrowserTab>> loadAndClearOpenTabs() async {
    final tabs = await loadOpenTabs();
    await clearOpenTabs();
    return tabs;
  }

  Future<List<SavedBrowserTab>> loadOpenTabs() {
    return (_db.select(_db.browserTabs)
          ..orderBy([(t) => drift.OrderingTerm.asc(t.position)]))
        .get();
  }

  Future<void> clearOpenTabs() {
    return _db.delete(_db.browserTabs).go();
  }
}
