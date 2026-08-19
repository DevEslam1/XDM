import 'dart:async';
import 'package:drift/drift.dart' as drift;
import '../../../../features/settings/provider/settings_provider.dart';
import '../app_database.dart';

class BrowserHistoryRepository {
  final AppDatabase _db;
  Timer? _historyFlushTimer;
  final Map<String, Map<String, dynamic>> _pendingHistoryEntries = {};
  int _historyInsertCount = 0;

  BrowserHistoryRepository(this._db);

  Timer? get historyFlushTimer => _historyFlushTimer;

  int get pendingHistoryEntriesCount => _pendingHistoryEntries.length;

  Future<List<Map<String, dynamic>>> loadBrowserHistory({
    int? max,
    String? searchQuery,
  }) async {
    int effectiveMax;
    try {
      await SettingsProvider.instance.ensureLoaded();
      effectiveMax = max ?? SettingsProvider.instance.historyMaxEntries;
    } catch (_) {
      effectiveMax = max ?? 500;
    }
    final query = _db.select(_db.browserHistory)
      ..orderBy([(t) => drift.OrderingTerm.desc(t.visitedAt)])
      ..limit(effectiveMax);

    if (searchQuery != null && searchQuery.trim().isNotEmpty) {
      final term = searchQuery.trim();
      query.where((t) => t.url.contains(term) | t.title.contains(term));
    }

    final rows = await query.get();

    return rows
        .map(
          (r) => {
            'id': r.id,
            'url': r.url,
            'title': r.title,
            'visitedAt': r.visitedAt,
            'visitCount': r.visitCount,
            'faviconUrl': r.faviconUrl,
          },
        )
        .toList();
  }

  Future<void> clearBrowserHistoryBefore(DateTime? before) async {
    if (before == null) {
      await clearBrowserHistory();
      return;
    }
    await (_db.delete(_db.browserHistory)
          ..where((t) =>
              t.visitedAt.isSmallerThanValue(before.millisecondsSinceEpoch)))
        .go();
  }

  Future<int> getVisitCount(String url) async {
    final rows = await (_db.select(_db.browserHistory)
          ..where((t) => t.url.equals(url)))
        .get();
    return rows.fold<int>(0, (sum, r) => sum + r.visitCount);
  }

  Future<int> addBrowserHistory(
    Map<String, dynamic> entry, {
    bool immediate = false,
  }) async {
    final url = entry['url'] as String? ?? '';
    if (url.isEmpty || url == 'about:blank') return 0;

    if (immediate) {
      return _writeBrowserHistoryDirect(entry);
    }

    _pendingHistoryEntries[url] = entry;

    if (_pendingHistoryEntries.length >= 20) {
      await flushPendingHistory();
      return 1;
    }

    _historyFlushTimer ??= Timer(const Duration(seconds: 5), () async {
      _historyFlushTimer = null;
      await flushPendingHistory();
    });

    return 1;
  }

  Future<void> flushPendingHistory() async {
    _historyFlushTimer?.cancel();
    _historyFlushTimer = null;
    if (_pendingHistoryEntries.isEmpty) return;

    final entries =
        List<Map<String, dynamic>>.from(_pendingHistoryEntries.values);
    _pendingHistoryEntries.clear();

    await _db.transaction(() async {
      for (final entry in entries) {
        await _writeEntryInTx(entry);
      }
    });

    _historyInsertCount += entries.length;
    if (_historyInsertCount >= 100) {
      _historyInsertCount = 0;
      await _trimHistoryInternal();
    }

    if (_pendingHistoryEntries.isNotEmpty && _historyFlushTimer == null) {
      _historyFlushTimer = Timer(const Duration(seconds: 5), () async {
        _historyFlushTimer = null;
        await flushPendingHistory();
      });
    }
  }

  Future<int> _writeEntryInTx(Map<String, dynamic> entry) async {
    final url = entry['url'] as String? ?? '';
    if (url.isEmpty || url == 'about:blank') return 0;
    final visitedAt = (entry['visitedAt'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    final title = entry['title'] as String? ?? url;
    final faviconUrl = entry['faviconUrl'] as String?;

    final existing = await (_db.select(_db.browserHistory)
          ..where((t) => t.url.equals(url))
          ..orderBy([(t) => drift.OrderingTerm.desc(t.visitedAt)])
          ..limit(1))
        .getSingleOrNull();

    if (existing != null) {
      await (_db.update(_db.browserHistory)
            ..where((t) => t.id.equals(existing.id)))
          .write(BrowserHistoryCompanion(
        title: drift.Value(title),
        visitedAt: drift.Value(visitedAt),
        visitCount: drift.Value(existing.visitCount + 1),
        faviconUrl: drift.Value(faviconUrl ?? existing.faviconUrl),
      ));
      return existing.id;
    } else {
      return await _db.into(_db.browserHistory).insert(
            BrowserHistoryCompanion.insert(
              url: url,
              title: title,
              visitedAt: visitedAt,
              visitCount: const drift.Value(1),
              faviconUrl: drift.Value(faviconUrl),
            ),
          );
    }
  }

  Future<int> _writeBrowserHistoryDirect(Map<String, dynamic> entry) async {
    final id = await _db.transaction(() async {
      return await _writeEntryInTx(entry);
    });

    _historyInsertCount++;
    if (_historyInsertCount % 100 == 0) {
      await _trimHistoryInternal();
    }

    return id;
  }

  Future<void> _trimHistoryInternal([int? maxEntries]) async {
    int maxHistory;
    if (maxEntries != null) {
      maxHistory = maxEntries;
    } else {
      try {
        await SettingsProvider.instance.ensureLoaded();
        maxHistory = SettingsProvider.instance.historyMaxEntries;
      } catch (_) {
        maxHistory = 500;
      }
    }
    final thresholdRow = await _db.customSelect(
      'SELECT visited_at FROM browser_history ORDER BY visited_at DESC LIMIT 1 OFFSET ?',
      variables: [drift.Variable.withInt(maxHistory)],
    ).getSingleOrNull();

    if (thresholdRow != null) {
      final cutoff = thresholdRow.read<int>('visited_at');
      await _db.customStatement(
        'DELETE FROM browser_history WHERE visited_at < ?',
        [cutoff],
      );
    }
  }

  Future<void> updateBrowserHistoryTitle(int id, String title) async {
    await (_db.update(_db.browserHistory)..where((t) => t.id.equals(id))).write(
      BrowserHistoryCompanion(title: drift.Value(title)),
    );
  }

  Future<void> updateBrowserHistoryTime(int id, int visitedAt) async {
    await _db.customStatement(
      'UPDATE browser_history SET visited_at = ?, visit_count = visit_count + 1 WHERE id = ?',
      [visitedAt, id],
    );
  }

  Future<void> deleteBrowserHistory(int id) {
    return (_db.delete(_db.browserHistory)..where((t) => t.id.equals(id))).go();
  }

  Future<void> clearBrowserHistory() {
    return _db.delete(_db.browserHistory).go();
  }

  void dispose() {
    _historyFlushTimer?.cancel();
    _historyFlushTimer = null;
  }
}
