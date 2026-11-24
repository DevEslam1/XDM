import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/database/repositories/browser_tab_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late BrowserTabRepository repository;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = BrowserTabRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  SavedBrowserTab tab(String id, int position) => SavedBrowserTab(
        id: id,
        url: 'https://example.com/$id',
        title: 'Tab $id',
        isActive: false,
        position: position,
        createdAt: 1000 + position,
        lastVisitedAt: 2000 + position,
      );

  group('BrowserTabRepository', () {
    test('saves and loads tabs ordered by position', () async {
      await repository.saveOpenTabs([tab('b', 2), tab('a', 1)]);

      final loaded = await repository.loadOpenTabs();
      expect(loaded.map((t) => t.id).toList(), ['a', 'b']);
    });

    test('saving an empty list clears existing tabs', () async {
      await repository.saveOpenTabs([tab('a', 1)]);
      await repository.saveOpenTabs([]);
      expect(await repository.loadOpenTabs(), isEmpty);
    });

    test('loadAndClearOpenTabs returns then clears', () async {
      await repository.saveOpenTabs([tab('a', 1), tab('b', 2)]);

      final loaded = await repository.loadAndClearOpenTabs();
      expect(loaded.length, 2);
      expect(await repository.loadOpenTabs(), isEmpty);
    });

    test('clearOpenTabs removes all rows', () async {
      await repository.saveOpenTabs([tab('a', 1)]);
      await repository.clearOpenTabs();
      expect(await repository.loadOpenTabs(), isEmpty);
    });
  });
}
