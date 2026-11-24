import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/browser/services/history_manager.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeHistoryDb extends DatabaseService {
  _FakeHistoryDb() : super.forSubclass();

  final List<Map<String, dynamic>> added = [];
  final List<(int, String)> titleUpdates = [];
  final List<(int, int)> timeUpdates = [];
  List<Map<String, dynamic>> historyRows = [];
  int nextId = 1;
  bool throwOnAdd = false;
  bool throwOnLoad = false;
  bool throwOnTime = false;
  bool throwOnTitle = false;

  @override
  Future<int> addBrowserHistory(
    Map<String, dynamic> entry, {
    bool immediate = false,
  }) async {
    if (throwOnAdd) throw Exception('add failed');
    added.add(entry);
    return nextId++;
  }

  @override
  Future<void> updateBrowserHistoryTitle(int id, String title) async {
    if (throwOnTitle) throw Exception('title failed');
    titleUpdates.add((id, title));
  }

  @override
  Future<void> updateBrowserHistoryTime(int id, int visitedAt) async {
    if (throwOnTime) throw Exception('time failed');
    timeUpdates.add((id, visitedAt));
  }

  @override
  Future<List<Map<String, dynamic>>> loadBrowserHistory({
    int? max,
    String? searchQuery,
  }) async {
    if (throwOnLoad) throw Exception('load failed');
    return historyRows;
  }
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  late _FakeHistoryDb db;
  late bool incognito;
  late bool active;

  BrowserHistoryManager buildManager({bool resolveThrows = false}) {
    return BrowserHistoryManager(
      resolveDatabase: () {
        if (resolveThrows) throw Exception('no db');
        return db;
      },
      isIncognito: () => incognito,
      cleanUrl: (url) => url,
      isActive: () => active,
    );
  }

  setUp(() {
    db = _FakeHistoryDb();
    incognito = false;
    active = true;
  });

  group('BrowserHistoryManager Tests', () {
    test('ignores empty and about:blank urls', () async {
      final manager = buildManager();
      manager.recordHistory('');
      manager.recordHistory('about:blank');
      await _flush();
      expect(db.added, isEmpty);
    });

    test('incognito clears dedup state and never records', () async {
      final manager = buildManager();
      manager.recordHistory('https://a.com');
      await _flush();
      expect(db.added, hasLength(1));

      incognito = true;
      manager.recordHistory('https://b.com');
      await _flush();
      expect(db.added, hasLength(1));
    });

    test('returns when cleanUrl throws', () async {
      final manager = BrowserHistoryManager(
        resolveDatabase: () => db,
        isIncognito: () => false,
        cleanUrl: (_) => throw Exception('clean failed'),
        isActive: () => true,
      );
      manager.recordHistory('https://a.com');
      await _flush();
      expect(db.added, isEmpty);
    });

    test('records a new visit with sanitized title', () async {
      final manager = buildManager();
      manager.recordHistory('https://a.com/page', title: '<b>Hello</b>');
      await _flush();

      expect(db.added, hasLength(1));
      expect(db.added.first['url'], 'https://a.com/page');
      expect(db.added.first['title'], 'Hello');
      expect(db.added.first['visitedAt'], isA<int>());
    });

    test('deduplicates a rapid revisit and updates time and title', () async {
      final manager = buildManager();
      manager.recordHistory('https://a.com/page', title: 'First');
      await _flush();

      manager.recordHistory('https://a.com/page', title: 'Second');
      await _flush();

      expect(db.added, hasLength(1));
      expect(db.timeUpdates, isNotEmpty);
      expect(db.titleUpdates.any((e) => e.$2 == 'Second'), isTrue);
    });

    test('deduplicates trailing-slash variants via normalization', () async {
      final manager = buildManager();
      manager.recordHistory('https://a.com/path/');
      await _flush();
      manager.recordHistory('https://a.com/path');
      await _flush();
      expect(db.added, hasLength(1));
    });

    test('revisit after inactive first record hits last-entry branch',
        () async {
      final manager = buildManager();
      active = false;
      manager.recordHistory('https://a.com/late', title: 'First');
      await _flush();
      expect(db.added, hasLength(1));

      active = true;
      manager.recordHistory('https://a.com/late', title: 'Second');
      await _flush();
      // Still only one add; no recent entry existed to update.
      expect(db.added, hasLength(1));
    });

    test('sanitizes javascript/data titles to the url fallback', () async {
      final manager = buildManager();
      manager.recordHistory('https://a.com/x', title: 'javascript:evil()');
      await _flush();
      expect(db.added.first['title'], 'https://a.com/x');

      db.added.clear();
      manager.recordHistory('https://a.com/y', title: 'data:text/html,x');
      await _flush();
      expect(db.added.first['title'], 'https://a.com/y');
    });

    test('strips numeric entities and truncates very long titles', () async {
      final manager = buildManager();
      manager.recordHistory('https://a.com/z',
          title: '&#106;ava <b>tag</b> ${'x' * 300}');
      await _flush();
      final title = db.added.first['title'] as String;
      expect(title.length, lessThanOrEqualTo(200));
      expect(title, isNot(contains('<')));
      expect(title, isNot(contains('&#')));
    });

    test('empty title falls back to the cleaned url', () async {
      final manager = buildManager();
      manager.recordHistory('https://a.com/empty', title: '');
      await _flush();
      expect(db.added.first['title'], 'https://a.com/empty');
    });

    test('add failure is swallowed', () async {
      db.throwOnAdd = true;
      final manager = buildManager();
      manager.recordHistory('https://a.com/fail');
      await _flush();
      expect(db.added, isEmpty);
    });

    test('resolveDatabase throwing is swallowed', () async {
      final manager = buildManager(resolveThrows: true);
      manager.recordHistory('https://a.com/nodb');
      await _flush();
      expect(db.added, isEmpty);
    });

    test('evicts recent visits when the map grows past 500', () async {
      final manager = buildManager();
      for (var i = 0; i < 510; i++) {
        manager.recordHistory('https://a.com/p$i');
        await _flush();
      }
      expect(db.added.length, 510);
    });

    test('recordVisit respects both incognito flags', () async {
      final manager = buildManager();
      manager.recordVisit(url: 'https://a.com', isIncognito: true);
      await _flush();
      expect(db.added, isEmpty);

      incognito = true;
      manager.recordVisit(url: 'https://b.com');
      await _flush();
      expect(db.added, isEmpty);

      incognito = false;
      manager.recordVisit(url: 'https://c.com', title: 'C');
      await _flush();
      expect(db.added, hasLength(1));
    });

    test('reset clears in-memory dedup state', () async {
      final manager = buildManager();
      manager.recordHistory('https://a.com/reset');
      await _flush();
      manager.reset();
      manager.recordHistory('https://a.com/reset');
      await _flush();
      expect(db.added, hasLength(2));
    });

    test('getRecentHistory returns rows and swallows failures', () async {
      final manager = buildManager();
      db.historyRows = [
        {'url': 'https://a.com', 'title': 'A', 'visitedAt': 1}
      ];
      expect(await manager.getRecentHistory(), hasLength(1));

      db.throwOnLoad = true;
      expect(await manager.getRecentHistory(), isEmpty);
    });

    test('swallows errors from time and title updates on revisit', () async {
      final manager = buildManager();
      manager.recordHistory('https://a.com/err', title: 'First');
      await _flush();

      db.throwOnTime = true;
      db.throwOnTitle = true;
      manager.recordHistory('https://a.com/err', title: 'Second');
      await _flush();
      expect(db.added, hasLength(1));
    });

    test('swallows resolveDatabase errors on revisit', () async {
      var fail = false;
      final manager = BrowserHistoryManager(
        resolveDatabase: () {
          if (fail) throw Exception('no db');
          return db;
        },
        isIncognito: () => false,
        cleanUrl: (url) => url,
        isActive: () => true,
      );
      manager.recordHistory('https://a.com/rev');
      await _flush();
      fail = true;
      manager.recordHistory('https://a.com/rev', title: 'T');
      await _flush();
      expect(db.added, hasLength(1));
    });
  });
}
