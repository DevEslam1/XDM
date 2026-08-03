import 'package:flutter/foundation.dart';

import '../../../core/services/database_service.dart';

/// Records visited pages into the browser history table, deduplicating
/// consecutive visits to the same URL and back-filling titles that arrive
/// after the page-load event (REFACTOR B extraction from
/// `_BrowserScreenState`).
class BrowserHistoryManager {
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

  void recordHistory(String url, {String? title}) {
    if (url.isEmpty || url == 'about:blank') return;
    final clean = cleanUrl(url);
    if (isIncognito()) return;
    final now = DateTime.now();
    if (clean == _lastHistoryEntryUrl) {
      if (title != null && title.isNotEmpty && title != clean) {
        if (_lastHistoryEntryId != null) {
          try {
            final db = resolveDatabase();
            db
                .updateBrowserHistoryTitle(_lastHistoryEntryId!, title)
                .catchError((e) {
              debugPrint('[HistoryManager] Title update error: $e');
            });
          } catch (e) {
            debugPrint(
              '[DMX Browser] Failed to update browser history title: $e',
            );
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
        if (clean == _lastHistoryEntryUrl && id > 0) {
          _lastHistoryEntryId = id;
        }
      }).catchError((e) {
        debugPrint('[HistoryManager] Failed to record history: $e');
      });
    } catch (e) {
      debugPrint('[DMX Browser] Failed to add browser history: $e');
    }
  }
}
