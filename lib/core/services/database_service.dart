import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/downloads/models/download_task.dart';
import '../../features/browser/models/bookmark.dart';

class DatabaseService {
  static const String downloadsBoxName = 'downloads';
  static const String bookmarksBoxName = 'browser_bookmarks';
  static const String browserHistoryBoxName = 'browser_history';

  late final Box<dynamic> _downloadsBox;
  late final Box<dynamic> _bookmarksBox;
  late final Box<dynamic> _browserHistoryBox;

  Future<void> init() async {
    _downloadsBox = await Hive.openBox<dynamic>(downloadsBoxName);
    _bookmarksBox = await Hive.openBox<dynamic>(bookmarksBoxName);
    _browserHistoryBox = await Hive.openBox<dynamic>(browserHistoryBoxName);
  }

  List<DownloadTask> loadTasks() {
    final tasks = <DownloadTask>[];
    for (final value in _downloadsBox.values) {
      if (value is Map) {
        try {
          tasks.add(DownloadTask.fromMap(Map<String, dynamic>.from(value)));
        } catch (e) {
          // Log parsing error without crashing load
          debugPrint('Error parsing DownloadTask from database: $e');
        }
      }
    }
    return tasks..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<void> saveTask(DownloadTask task) {
    return _downloadsBox.put(task.id, task.toMap());
  }

  Future<void> saveTasks(Iterable<DownloadTask> tasks) async {
    final entries = <String, Map<String, dynamic>>{
      for (final task in tasks) task.id: task.toMap(),
    };
    if (entries.isEmpty) return;
    await _downloadsBox.putAll(entries);
  }

  Future<void> deleteTask(String id) {
    return _downloadsBox.delete(id);
  }

  Future<void> clearAllTasks() {
    return _downloadsBox.clear();
  }

  List<Bookmark> loadBookmarks() {
    final bookmarks = <Bookmark>[];
    for (final value in _bookmarksBox.values) {
      if (value is Map) {
        try {
          bookmarks.add(Bookmark.fromMap(Map<String, dynamic>.from(value)));
        } catch (e) {
          debugPrint('Error parsing Bookmark from database: $e');
        }
      }
    }
    return bookmarks..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<void> saveBookmark(Bookmark bookmark) {
    return _bookmarksBox.put(bookmark.id, bookmark.toMap());
  }

  Future<void> deleteBookmark(String id) {
    return _bookmarksBox.delete(id);
  }

  Future<void> clearBookmarks() {
    return _bookmarksBox.clear();
  }

  List<Map<String, dynamic>> loadBrowserHistory({int max = 200}) {
    final list = <Map<String, dynamic>>[];
    for (final key in _browserHistoryBox.keys) {
      try {
        final val = _browserHistoryBox.get(key);
        if (val is Map) {
          final map = Map<String, dynamic>.from(val);
          map['id'] = key.toString();
          list.add(map);
        }
      } catch (e) {
        debugPrint('Error loading browser history entry for key $key: $e');
      }
    }
    list.sort((a, b) {
      final ta = DateTime.tryParse(a['visitedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final tb = DateTime.tryParse(b['visitedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return tb.compareTo(ta);
    });
    if (list.length > max) {
      return list.sublist(0, max);
    }
    return list;
  }

  int _historySequenceCounter = 0;

  Future<String> addBrowserHistory(Map<String, dynamic> entry) async {
    final url = entry['url'] as String? ?? '';
    if (url.isEmpty || url == 'about:blank') return '';
    final ts = DateTime.now().millisecondsSinceEpoch;
    final seq = _historySequenceCounter++;
    final id = '${ts}_${seq}_$url';
    await _browserHistoryBox.put(id, {
      'url': url,
      'title': entry['title'] as String? ?? url,
      'visitedAt': entry['visitedAt'] as String? ?? DateTime.now().toIso8601String(),
    });
    return id;
  }

  Future<void> updateBrowserHistoryTitle(String id, String title) async {
    final val = _browserHistoryBox.get(id);
    if (val is Map) {
      final map = Map<String, dynamic>.from(val);
      map['title'] = title;
      await _browserHistoryBox.put(id, map);
    }
  }

  Future<void> deleteBrowserHistory(String id) {
    return _browserHistoryBox.delete(id);
  }

  Future<void> clearBrowserHistory() {
    return _browserHistoryBox.clear();
  }
}
