import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/database/repositories/browser_history_repository.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late BrowserHistoryRepository repository;

  setUp(() {
    SettingsProvider.instance.saveBrowserHistory = true;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = BrowserHistoryRepository(db);
  });

  tearDown(() async {
    repository.dispose();
    await db.close();
    SettingsProvider.instance.saveBrowserHistory = true;
  });

  Map<String, dynamic> entry(
    String url, {
    String? title,
    int? visitedAt,
  }) =>
      {
        'url': url,
        if (title != null) 'title': title,
        if (visitedAt != null) 'visitedAt': visitedAt,
      };

  group('BrowserHistoryRepository writes', () {
    test('immediate add inserts a row directly', () async {
      final id = await repository.addBrowserHistory(
        entry('https://a.example', title: 'A'),
        immediate: true,
      );
      expect(id, greaterThan(0));

      final loaded = await repository.loadBrowserHistory();
      expect(loaded.length, 1);
      expect(loaded.single['url'], 'https://a.example');
      expect(loaded.single['visitCount'], 1);
    });

    test('deferred add queues then flushes', () async {
      await repository.addBrowserHistory(entry('https://b.example'));
      expect(repository.pendingHistoryEntriesCount, 1);
      expect(await repository.loadBrowserHistory(), isEmpty);

      await repository.flushPendingHistory();
      expect(repository.pendingHistoryEntriesCount, 0);
      expect((await repository.loadBrowserHistory()).length, 1);
    });

    test('repeated visits increment the visit count', () async {
      await repository.addBrowserHistory(entry('https://c.example'),
          immediate: true);
      await repository.addBrowserHistory(entry('https://c.example'),
          immediate: true);

      final loaded = await repository.loadBrowserHistory();
      expect(loaded.single['visitCount'], 2);
    });

    test('rejects empty and about:blank urls', () async {
      expect(await repository.addBrowserHistory(entry(''), immediate: true), 0);
      expect(
        await repository.addBrowserHistory(entry('about:blank'),
            immediate: true),
        0,
      );
      expect(await repository.loadBrowserHistory(), isEmpty);
    });

    test('returns 0 when history saving is disabled', () async {
      SettingsProvider.instance.saveBrowserHistory = false;
      expect(
        await repository.addBrowserHistory(entry('https://d.example')),
        0,
      );
    });

    test('auto-flushes once 20 entries are queued', () async {
      for (var i = 0; i < 20; i++) {
        await repository.addBrowserHistory(entry('https://e$i.example'));
      }
      expect(repository.pendingHistoryEntriesCount, 0);
      expect((await repository.loadBrowserHistory()).length, 20);
    });

    test('getVisitCount sums all rows for a url', () async {
      await repository.addBrowserHistory(entry('https://f.example'),
          immediate: true);
      await repository.addBrowserHistory(entry('https://f.example'),
          immediate: true);
      expect(await repository.getVisitCount('https://f.example'), 2);
      expect(await repository.getVisitCount('https://missing.example'), 0);
    });
  });

  group('BrowserHistoryRepository reads and updates', () {
    test('loadBrowserHistory honours max and search filters', () async {
      for (var i = 0; i < 5; i++) {
        await repository.addBrowserHistory(
          entry('https://site$i.example', title: i.isEven ? 'even' : 'odd'),
          immediate: true,
        );
      }

      expect((await repository.loadBrowserHistory(max: 2)).length, 2);
      final even = await repository.loadBrowserHistory(searchQuery: 'even');
      expect(even.length, 3);
      expect(
        (await repository.loadBrowserHistory(searchQuery: '   ')).length,
        5,
      );
    });

    test('updateBrowserHistoryTitle rewrites the title', () async {
      final id = await repository.addBrowserHistory(
        entry('https://g.example', title: 'Old'),
        immediate: true,
      );
      await repository.updateBrowserHistoryTitle(id, 'New');
      final loaded = await repository.loadBrowserHistory();
      expect(loaded.single['title'], 'New');
    });

    test('updateBrowserHistoryTime bumps visit count', () async {
      final id = await repository.addBrowserHistory(
        entry('https://h.example'),
        immediate: true,
      );
      await repository.updateBrowserHistoryTime(id, 999999);
      final loaded = await repository.loadBrowserHistory();
      expect(loaded.single['visitedAt'], 999999);
      expect(loaded.single['visitCount'], 2);
    });

    test('deleteBrowserHistory removes one row', () async {
      final id = await repository.addBrowserHistory(
        entry('https://i.example'),
        immediate: true,
      );
      await repository.addBrowserHistory(entry('https://j.example'),
          immediate: true);

      await repository.deleteBrowserHistory(id);
      final loaded = await repository.loadBrowserHistory();
      expect(loaded.length, 1);
      expect(loaded.single['url'], 'https://j.example');
    });

    test('clearBrowserHistory empties the table', () async {
      await repository.addBrowserHistory(entry('https://k.example'),
          immediate: true);
      await repository.clearBrowserHistory();
      expect(await repository.loadBrowserHistory(), isEmpty);
    });

    test('clearBrowserHistoryBefore with null clears everything', () async {
      await repository.addBrowserHistory(entry('https://l.example'),
          immediate: true);
      await repository.clearBrowserHistoryBefore(null);
      expect(await repository.loadBrowserHistory(), isEmpty);
    });

    test('clearBrowserHistoryBefore removes only older rows', () async {
      await repository.addBrowserHistory(
        entry('https://old.example', visitedAt: 1000),
        immediate: true,
      );
      await repository.addBrowserHistory(
        entry('https://new.example', visitedAt: 5000),
        immediate: true,
      );

      await repository.clearBrowserHistoryBefore(
        DateTime.fromMillisecondsSinceEpoch(3000),
      );

      final loaded = await repository.loadBrowserHistory();
      expect(loaded.length, 1);
      expect(loaded.single['url'], 'https://new.example');
    });

    test('trims history once the insert counter reaches 100', () async {
      for (var i = 0; i < 600; i++) {
        await repository.addBrowserHistory(
          entry('https://trim$i.example', visitedAt: i),
          immediate: true,
        );
      }
      final loaded = await repository.loadBrowserHistory(max: 1000);
      expect(loaded.length, lessThan(600));
      expect(loaded.length, greaterThan(100));
    });
  });
}
