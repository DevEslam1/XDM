import 'package:logging/logging.dart';

import '../../../core/services/database_service.dart';

/// Records visited pages into the browser history table, deduplicating
/// consecutive visits to the same URL and back-filling titles that arrive
/// after the page-load event (REFACTOR B extraction from
/// `_BrowserScreenState`).
class BrowserHistoryManager {
  static final _log = Logger('BrowserHistoryManager');
  static const Duration _dedupWindow = Duration(seconds: 10);

  BrowserHistoryManager({
    required this.resolveDatabase,
    required this.isIncognito,
    required this.cleanUrl,
    required this.isActive,
  });

  /// Lazily resolves the database service (Provider lookup on the screen).
  final DatabaseService Function() resolveDatabase;

  /// Whether incognito mode is on — history is not recorded then.
  final bool Function() isIncognito;

  /// Normalizes a URL the same way the address bar does.
  final String Function(String url) cleanUrl;

  /// Whether the host screen is still mounted.
  final bool Function() isActive;

  String? _lastHistoryEntryUrl;
  int? _lastHistoryEntryId;
  final Map<String, ({int id, DateTime visitedAt})> _recentVisits = {};

  /// Resets in-memory dedup tracking when incognito mode is toggled ON.
  void reset() {
    _lastHistoryEntryUrl = null;
    _lastHistoryEntryId = null;
    _recentVisits.clear();
  }

  void recordHistory(String url, {String? title}) {
    if (url.isEmpty || url == 'about:blank') return;

    final String clean;
    try {
      clean = cleanUrl(url);
    } catch (e) {
      _log.warning('[HistoryManager] Failed to clean URL: $url, error: $e');
      return;
    }

    if (isIncognito()) {
      // Clear stale dedup state so the first visit after exiting
      // incognito isn't incorrectly skipped.
      reset();
      return;
    }
    final now = DateTime.now();

    // Clean up old entries in _recentVisits to prevent leaks
    _recentVisits.removeWhere(
        (key, value) => now.difference(value.visitedAt) > _dedupWindow);
    if (_recentVisits.length > 500) {
      final keysToRemove =
          _recentVisits.keys.take(_recentVisits.length - 400).toList();
      for (final k in keysToRemove) {
        _recentVisits.remove(k);
      }
    }

    // Check if the URL was visited in the dedup window
    final recent = _recentVisits[clean];
    if (recent != null && now.difference(recent.visitedAt) < _dedupWindow) {
      final id = recent.id;
      _recentVisits[clean] = (id: id, visitedAt: now);

      try {
        final db = resolveDatabase();
        db
            .updateBrowserHistoryTime(id, now.millisecondsSinceEpoch)
            .catchError((e) {
          _log.warning('[HistoryManager] Time update error: $e');
        });
        if (title != null && title.isNotEmpty && title != clean) {
          db.updateBrowserHistoryTitle(id, title).catchError((e) {
            _log.warning('[HistoryManager] Title update error: $e');
          });
        }
      } catch (e) {
        _log.warning('[HistoryManager] Failed to update history: $e');
      }
      return;
    }

    if (clean == _lastHistoryEntryUrl) {
      if (title != null && title.isNotEmpty && title != clean) {
        if (_lastHistoryEntryId != null) {
          try {
            final db = resolveDatabase();
            db
                .updateBrowserHistoryTitle(_lastHistoryEntryId!, title)
                .catchError((e) {
              _log.warning('[HistoryManager] Title update error: $e');
            });
          } catch (e) {
            _log.warning(
                '[DMX Browser] Failed to update browser history title: $e');
          }
        }
      }
      return;
    }

    _lastHistoryEntryUrl = clean;
    _lastHistoryEntryId = null;
    final titleToRecord = (title != null && title.isNotEmpty) ? title : clean;
    try {
      final db = resolveDatabase();
      db.addBrowserHistory({
        'url': clean,
        'title': titleToRecord,
        'visitedAt': now.millisecondsSinceEpoch,
      }).then((id) {
        if (!isActive()) return;
        if (id > 0) {
          _recentVisits[clean] = (id: id, visitedAt: now);
          _lastHistoryEntryId = id;
          _lastHistoryEntryUrl = clean;
        }
      }).catchError((e) {
        _log.warning('[HistoryManager] Failed to record history: $e');
      });
    } catch (e) {
      _log.warning('[DMX Browser] Failed to add browser history: $e');
    }
  }

  void recordVisit({
    required String url,
    String? title,
    bool isIncognito = false,
  }) {
    if (isIncognito) return;
    recordHistory(url, title: title);
  }

  Future<List<Map<String, dynamic>>> getRecentHistory({int limit = 30}) async {
    try {
      final db = resolveDatabase();
      return await db.loadBrowserHistory(max: limit);
    } catch (_) {
      return [];
    }
  }
}
